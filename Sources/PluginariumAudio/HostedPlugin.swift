import AudioToolbox
import Foundation
import PluginariumCore

public enum HostedPluginError: Error {
    case notFound(PluginID)
    case osStatus(OSStatus, String)
    case invalidState
    case unknownPreset(String)
}

extension HostedPluginError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            "The plugin \(id.type)/\(id.subtype)/\(id.manufacturer) is not installed on this Mac."
        case .osStatus(let status, let operation):
            "\(operation) failed with error \(status)."
        case .invalidState:
            "The saved plugin state cannot be read."
        case .unknownPreset(let name):
            "The plugin has no preset named \(name)."
        }
    }
}

/// How long the interface gets to draw before a plugin holds up the main thread: a little over a frame.
private let drawPause = Duration.milliseconds(20)

/// An instantiated Audio Unit. Holds the raw `AudioUnit` because the C render core
/// calls `AudioUnitRender` on it directly.
///
/// Audio Units expect to be created, set up and destroyed on the main thread. JUCE plugins run timers
/// there, and one that fires during a destructor on another thread lands in a half destroyed object.
/// So everything of that kind is `@MainActor`, and `deinit` passes the unit to the main thread when the
/// last reference drops somewhere else.
public final class HostedPlugin: @unchecked Sendable {

    public let id: PluginID
    public let audioUnit: AudioUnit
    /// Channels per bus: 2, or 1 when `configure` found the unit refuses stereo.
    public private(set) var channelCount: UInt32 = 2
    private var isInitialized = false
    /// Keeps the owner of the plugin's view (view controller or Cocoa factory) alive, since a view does
    /// not own it. `releaseView` lets go of it.
    var viewOwner: AnyObject?

    private init(id: PluginID, audioUnit: AudioUnit) {
        self.id = id
        self.audioUnit = audioUnit
    }

    /// The last reference can drop on any thread. No render reaches the unit by then, because the
    /// runner only lets go of a unit that has left every graph. This never waits for the main thread,
    /// which may itself be waiting for the thread this runs on.
    deinit {
        let teardown = Teardown(audioUnit: audioUnit, isInitialized: isInitialized, viewOwner: viewOwner)
        viewOwner = nil
        if Thread.isMainThread {
            teardown.run()
        } else {
            DispatchQueue.main.async { teardown.run() }
        }
    }

    /// Instantiates in process (version 3 units included), since the render thread calls into the unit.
    /// This holds up the main thread for as long as the unit takes to create, so call `letInterfaceDraw` first.
    @MainActor
    public static func load(_ id: PluginID) async throws -> HostedPlugin {
        var description = id.componentDescription
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw HostedPluginError.notFound(id)
        }
        let unit = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UnitBox, Error>) in
            // `@Sendable` keeps the block nonisolated: the system may call it on any thread.
            let completion: @Sendable (AudioComponentInstance?, OSStatus) -> Void = { instance, status in
                if status == noErr, let instance {
                    continuation.resume(returning: UnitBox(unit: instance))
                } else {
                    continuation.resume(throwing: HostedPluginError.osStatus(status, "AudioComponentInstantiate"))
                }
            }
            AudioComponentInstantiate(component, .loadInProcess, completion)
        }
        return HostedPlugin(id: id, audioUnit: unit.unit)
    }

    /// Frees the main thread long enough to draw, so a "Loading" state shows before a plugin holds it up.
    @MainActor
    static func letInterfaceDraw() async {
        try? await Task.sleep(for: drawPause)
    }

    /// Names of the input buses; "Input" or "Bus n" when the unit does not name one.
    @MainActor
    public var inputBusNames: [String] {
        var count: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioUnitGetProperty(audioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &count, &size) == noErr
        else { return [] }
        return (0..<count).map { element in
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = AudioUnitGetProperty(audioUnit, kAudioUnitProperty_ElementName, kAudioUnitScope_Input, element, &name, &nameSize)
            if status == noErr, let name { return name.takeRetainedValue() as String }
            return element == 0 ? "Input" : "Bus \(element)"
        }
    }

    /// Sets maximum frames and a deinterleaved Float32 format on every bus (stereo, mono when
    /// the unit refuses), then initializes the unit.
    @MainActor
    public func configure(sampleRate: Double, maxFrames: UInt32) throws {
        if isInitialized {
            AudioUnitUninitialize(audioUnit)
            isInitialized = false
        }
        var frames = maxFrames
        try check(
            AudioUnitSetProperty(audioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, UInt32(MemoryLayout<UInt32>.size)),
            "MaximumFramesPerSlice"
        )
        if (try? applyFormat(channels: 2, sampleRate: sampleRate)) != nil {
            channelCount = 2
        } else {
            try applyFormat(channels: 1, sampleRate: sampleRate)
            channelCount = 1
        }
        try check(AudioUnitInitialize(audioUnit), "AudioUnitInitialize")
        isInitialized = true
    }

    /// The unit's class info, serialized as a binary property list.
    @MainActor
    public func fullState() throws -> Data {
        var info: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        try check(AudioUnitGetProperty(audioUnit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &info, &size), "ClassInfo")
        guard let info else { throw HostedPluginError.invalidState }
        return try PropertyListSerialization.data(fromPropertyList: info.takeRetainedValue(), format: .binary, options: 0)
    }

    @MainActor
    public func restore(_ state: Data) throws {
        guard let plist = try PropertyListSerialization.propertyList(from: state, options: [], format: nil) as? NSDictionary
        else { throw HostedPluginError.invalidState }
        let dictionary = plist as CFDictionary
        var info = Unmanaged.passUnretained(dictionary)
        try withExtendedLifetime(dictionary) {
            try check(
                AudioUnitSetProperty(audioUnit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &info, UInt32(MemoryLayout<Unmanaged<CFDictionary>>.size)),
                "ClassInfo"
            )
        }
    }

    @MainActor
    public func factoryPresets() -> [String] {
        presets().map(\.name)
    }

    @MainActor
    public func selectFactoryPreset(_ name: String) throws {
        guard let preset = presets().first(where: { $0.name == name }) else {
            throw HostedPluginError.unknownPreset(name)
        }
        let cfName = name as CFString
        var value = AUPreset(presetNumber: preset.number, presetName: Unmanaged.passUnretained(cfName))
        try withExtendedLifetime(cfName) {
            try check(
                AudioUnitSetProperty(audioUnit, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0, &value, UInt32(MemoryLayout<AUPreset>.size)),
                "PresentPreset"
            )
        }
    }

    // MARK: - Private

    private struct UnitBox: @unchecked Sendable {
        let unit: AudioUnit
    }

    /// What `deinit` hands to the main thread. The owner of the plugin's view comes along, since a view
    /// controller has to go there too, and goes first, because what it shows uses the unit. `run` lets
    /// go of it rather than leaving that to this object, whose last reference can drop on either thread.
    private final class Teardown: @unchecked Sendable {
        private let audioUnit: AudioUnit
        private let isInitialized: Bool
        private var viewOwner: AnyObject?

        init(audioUnit: AudioUnit, isInitialized: Bool, viewOwner: AnyObject?) {
            self.audioUnit = audioUnit
            self.isInitialized = isInitialized
            self.viewOwner = viewOwner
        }

        func run() {
            viewOwner = nil
            if isInitialized { AudioUnitUninitialize(audioUnit) }
            AudioComponentInstanceDispose(audioUnit)
        }
    }

    private func presets() -> [(number: Int32, name: String)] {
        var array: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        guard AudioUnitGetProperty(audioUnit, kAudioUnitProperty_FactoryPresets, kAudioUnitScope_Global, 0, &array, &size) == noErr,
            let array
        else { return [] }
        let cfArray = array.takeRetainedValue()
        return (0..<CFArrayGetCount(cfArray)).compactMap { index in
            guard let pointer = CFArrayGetValueAtIndex(cfArray, index) else { return nil }
            let preset = pointer.assumingMemoryBound(to: AUPreset.self).pointee
            return (preset.presetNumber, (preset.presetName?.takeUnretainedValue() as String?) ?? "")
        }
    }

    private func applyFormat(channels: UInt32, sampleRate: Double) throws {
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0
        )
        for scope in [kAudioUnitScope_Input, kAudioUnitScope_Output] {
            var count: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioUnitGetProperty(audioUnit, kAudioUnitProperty_ElementCount, scope, 0, &count, &size) == noErr else { continue }
            for element in 0..<count {
                try check(
                    AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, scope, element, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                    "StreamFormat"
                )
            }
        }
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw HostedPluginError.osStatus(status, what) }
    }
}
