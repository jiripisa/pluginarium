import AppKit
import AudioToolbox
import CoreAudioKit
import ObjectiveC

extension HostedPlugin {

    /// The plugin's own editor view, or nil when it has none. Call `configure` first so the unit is
    /// initialized. Tries the Cocoa view factory first, then the view controller request.
    @MainActor
    public func makeView() async -> NSView? {
        if let view = cocoaFactoryView() { return view }
        return await requestedControllerView(timeout: .seconds(5))
    }

    // MARK: - Private

    @MainActor
    private func cocoaFactoryView() -> NSView? {
        var size: UInt32 = 0
        var writable: DarwinBoolean = false
        guard AudioUnitGetPropertyInfo(audioUnit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &size, &writable) == noErr,
            size >= UInt32(MemoryLayout<AudioUnitCocoaViewInfo>.size)
        else { return nil }

        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioUnitCocoaViewInfo>.alignment)
        defer { storage.deallocate() }
        guard AudioUnitGetProperty(audioUnit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, storage, &size) == noErr
        else { return nil }

        let info = storage.assumingMemoryBound(to: AudioUnitCocoaViewInfo.self).pointee
        let bundleURL = info.mCocoaAUViewBundleLocation.takeRetainedValue() as URL
        let className = info.mCocoaAUViewClass.takeRetainedValue() as String

        // `AUCocoaUIBase` is not imported into Swift, so call `uiViewForAudioUnit:withSize:` directly.
        let selector = NSSelectorFromString("uiViewForAudioUnit:withSize:")
        guard let bundle = Bundle(url: bundleURL), bundle.load(),
            let factoryClass = bundle.classNamed(className) as? NSObject.Type,
            let method = class_getInstanceMethod(factoryClass, selector)
        else { return nil }
        typealias Factory = @convention(c) (AnyObject, Selector, AudioUnit, NSSize) -> Unmanaged<NSView>?
        let makeView = unsafeBitCast(method_getImplementation(method), to: Factory.self)
        let factory = factoryClass.init()
        let view = makeView(factory, selector, audioUnit, NSSize(width: 800, height: 600))?.takeUnretainedValue()
        // The view does not own its factory; keep it for as long as the plugin lives.
        if view != nil { viewOwner = factory }
        return view
    }

    /// Version 3 units hand out an `AUViewController` through the `RequestViewController` property.
    /// Gives up after `timeout`, since a unit may accept the request and never answer.
    @MainActor
    func requestedControllerView(timeout: Duration) async -> NSView? {
        let unit = audioUnit
        let request = ViewRequest()
        let controller: NSViewController? = await withCheckedContinuation { continuation in
            request.install(continuation)
            // `@Sendable` keeps the block nonisolated: the unit may call it on any thread.
            let completion: @convention(block) @Sendable (AnyObject?) -> Void = { controller in
                request.finish(controller as? NSViewController)
            }
            var block = completion as AnyObject
            let status = withUnsafeMutablePointer(to: &block) {
                AudioUnitSetProperty(
                    unit, kAudioUnitProperty_RequestViewController, kAudioUnitScope_Global, 0,
                    $0, UInt32(MemoryLayout<AnyObject>.size)
                )
            }
            if status != noErr {
                request.finish(nil)
            } else {
                Task {
                    try? await Task.sleep(for: timeout)
                    request.finish(nil)
                }
            }
        }
        guard let controller else { return nil }
        // The view does not own its controller; keep it for as long as the plugin lives.
        viewOwner = controller
        return controller.view
    }
}

/// Resumes its continuation exactly once, from whichever of the completion block, the failure
/// path or the timeout comes first.
private final class ViewRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NSViewController?, Never>?

    func install(_ continuation: CheckedContinuation<NSViewController?, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func finish(_ controller: NSViewController?) {
        let pending = lock.withLock { () -> CheckedContinuation<NSViewController?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: controller)
    }
}
