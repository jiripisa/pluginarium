import CoreAudio
import Foundation
import PluginariumCore

/// An audio device as the system reports it. `id` is the device UID, which survives reconnecting.
public struct AudioDevice: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var inputChannels: [String]
    public var outputChannels: [String]

    public init(id: String, name: String, inputChannels: [String], outputChannels: [String]) {
        self.id = id
        self.name = name
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
    }
}

public struct DeviceSettings: Equatable, Sendable {
    public var sampleRate: Double
    public var bufferFrames: UInt32

    public init(sampleRate: Double, bufferFrames: UInt32) {
        self.sampleRate = sampleRate
        self.bufferFrames = bufferFrames
    }
}

/// What has to be written to a device. A nil field stays as it is.
struct DeviceSettingsChange: Equatable {
    var sampleRate: Double?
    var bufferFrames: UInt32?
}

/// What `settings` asks of its device. Only a device the owner picked is given settings. With no
/// device picked the engine follows the default output, which can become any device at any plug
/// event, so nil here means that device keeps what it runs at.
func chosenSettings(in settings: AppSettings) -> DeviceSettings? {
    guard settings.audioDeviceUID != nil else { return nil }
    return DeviceSettings(sampleRate: settings.sampleRate, bufferFrames: UInt32(settings.bufferFrames))
}

/// `requested` is nil for a device that keeps what it runs at, so nothing is written to it.
func settingsToWrite(current: DeviceSettings, requested: DeviceSettings?) -> DeviceSettingsChange {
    guard let requested else { return DeviceSettingsChange() }
    return DeviceSettingsChange(
        sampleRate: requested.sampleRate != current.sampleRate ? requested.sampleRate : nil,
        bufferFrames: requested.bufferFrames != current.bufferFrames ? requested.bufferFrames : nil
    )
}

/// `index` counts from zero.
func channelName(reported: String?, index: Int) -> String {
    if let reported, !reported.isEmpty { return reported }
    return "Channel \(index + 1)"
}

public enum DeviceCatalog {

    public static func all() -> [AudioDevice] {
        deviceObjects().compactMap(describe)
    }

    public static func defaultOutput() -> AudioDevice? {
        let object = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID(kAudioObjectUnknown))
        guard let object, object != kAudioObjectUnknown else { return nil }
        return describe(object)
    }

    /// What the device runs at now. Nil when the system does not know the device.
    public static func currentSettings(of device: AudioDevice) -> DeviceSettings? {
        object(uid: device.id).flatMap(currentSettings)
    }

    static func currentSettings(of object: AudioObjectID) -> DeviceSettings? {
        guard let sampleRate = read(object, kAudioDevicePropertyNominalSampleRate, as: Float64(0)),
            let bufferFrames = read(object, kAudioDevicePropertyBufferFrameSize, as: UInt32(0))
        else { return nil }
        return DeviceSettings(sampleRate: sampleRate, bufferFrames: bufferFrames)
    }

    static func object(uid: String) -> AudioObjectID? {
        deviceObjects().first { string(of: $0, kAudioDevicePropertyDeviceUID) == uid }
    }

    // MARK: - Reading properties

    private static func deviceObjects() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func describe(_ object: AudioObjectID) -> AudioDevice? {
        guard let uid = string(of: object, kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioDevice(
            id: uid,
            name: string(of: object, kAudioObjectPropertyName) ?? uid,
            inputChannels: channels(of: object, scope: kAudioObjectPropertyScopeInput),
            outputChannels: channels(of: object, scope: kAudioObjectPropertyScopeOutput)
        )
    }

    private static func channels(of object: AudioObjectID, scope: AudioObjectPropertyScope) -> [String] {
        (0..<channelCount(of: object, scope: scope)).map { index in
            // Element 0 is the whole device, so channels count from 1.
            let element = AudioObjectPropertyElement(index + 1)
            return channelName(reported: string(of: object, kAudioObjectPropertyElementName, scope: scope, element: element), index: index)
        }
    }

    private static func channelCount(of object: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, storage) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(
        of object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> String? {
        var address = propertyAddress(selector, scope: scope, element: element)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func read<Value: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as initial: Value) -> Value? {
        var address = propertyAddress(selector)
        var value = initial
        var size = UInt32(MemoryLayout<Value>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
}

func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}
