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
        return await requestedControllerView()
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
        return makeView(factory, selector, audioUnit, NSSize(width: 800, height: 600))?.takeUnretainedValue()
    }

    /// Version 3 units hand out an `AUViewController` through the `RequestViewController` property.
    @MainActor
    private func requestedControllerView() async -> NSView? {
        let unit = audioUnit
        let controller: NSViewController? = await withCheckedContinuation { continuation in
            let completion: @convention(block) (AnyObject?) -> Void = { controller in
                continuation.resume(returning: controller as? NSViewController)
            }
            var block = completion as AnyObject
            let status = withUnsafeMutablePointer(to: &block) {
                AudioUnitSetProperty(
                    unit, kAudioUnitProperty_RequestViewController, kAudioUnitScope_Global, 0,
                    $0, UInt32(MemoryLayout<AnyObject>.size)
                )
            }
            if status != noErr { continuation.resume(returning: nil) }
        }
        return controller?.view
    }
}
