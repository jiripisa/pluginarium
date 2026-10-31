import AudioToolbox
import Foundation
import PluginariumCore

public enum HostedPluginError: Error {
    case notFound(PluginID)
    case osStatus(OSStatus, String)
    case invalidState
    case unknownPreset(String)
}

/// An instantiated Audio Unit. Holds the raw `AudioUnit` because the C render core
/// calls `AudioUnitRender` on it directly.
public final class HostedPlugin: @unchecked Sendable {

    public let id: PluginID
    public let audioUnit: AudioUnit
    private var isInitialized = false

    private init(id: PluginID, audioUnit: AudioUnit) {
        self.id = id
        self.audioUnit = audioUnit
    }

    deinit {
        if isInitialized { AudioUnitUninitialize(audioUnit) }
        AudioComponentInstanceDispose(audioUnit)
    }

    /// Instantiates in process (version 3 units included), since the render thread calls into the unit.
    public static func load(_ id: PluginID) async throws -> HostedPlugin {
        var description = id.componentDescription
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw HostedPluginError.notFound(id)
        }
        let unit = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UnitBox, Error>) in
            AudioComponentInstantiate(component, .loadInProcess) { instance, status in
                if status == noErr, let instance {
                    continuation.resume(returning: UnitBox(unit: instance))
                } else {
                    continuation.resume(throwing: HostedPluginError.osStatus(status, "AudioComponentInstantiate"))
                }
            }
        }
        return HostedPlugin(id: id, audioUnit: unit.unit)
    }

    /// Names of the input buses; "Input" or "Bus n" when the unit does not name one.
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
        if (try? applyFormat(channels: 2, sampleRate: sampleRate)) == nil {
            try applyFormat(channels: 1, sampleRate: sampleRate)
        }
        try check(AudioUnitInitialize(audioUnit), "AudioUnitInitialize")
        isInitialized = true
    }

    /// The unit's class info, serialized as a binary property list.
    public func fullState() throws -> Data {
        var info: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        try check(AudioUnitGetProperty(audioUnit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &info, &size), "ClassInfo")
        guard let info else { throw HostedPluginError.invalidState }
        return try PropertyListSerialization.data(fromPropertyList: info.takeRetainedValue(), format: .binary, options: 0)
    }

    public func restore(_ state: Data) throws {
        guard let plist = try PropertyListSerialization.propertyList(from: state, options: [], format: nil) as? NSDictionary
        else { throw HostedPluginError.invalidState }
        var info = Unmanaged.passUnretained(plist as CFDictionary)
        try check(
            AudioUnitSetProperty(audioUnit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &info, UInt32(MemoryLayout<Unmanaged<CFDictionary>>.size)),
            "ClassInfo"
        )
    }

    public func factoryPresets() -> [String] {
        presets().map(\.name)
    }

    public func selectFactoryPreset(_ name: String) throws {
        guard let preset = presets().first(where: { $0.name == name }) else {
            throw HostedPluginError.unknownPreset(name)
        }
        var value = AUPreset(presetNumber: preset.number, presetName: Unmanaged.passUnretained(name as CFString))
        try check(
            AudioUnitSetProperty(audioUnit, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0, &value, UInt32(MemoryLayout<AUPreset>.size)),
            "PresentPreset"
        )
    }

    // MARK: - Private

    private struct UnitBox: @unchecked Sendable {
        let unit: AudioUnit
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
