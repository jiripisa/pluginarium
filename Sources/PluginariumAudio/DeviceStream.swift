import AudioToolbox
import CRenderCore
import CoreAudio
import Foundation

private let outputElement: AudioUnitElement = 0
private let inputElement: AudioUnitElement = 1
private let stopBound = Duration.seconds(2)
private let settingBound = Duration.seconds(2)

struct StreamRequest: Equatable {
    var device: AudioDevice
    /// What to write where the device differs. Nil leaves the device at what it runs at.
    var settings: DeviceSettings?
    /// False leaves the input element off, so the graph's input channels read as silence.
    var usesInput: Bool
}

/// A device on its way to running the render core, or running it.
protocol DeviceStream: AnyObject, Sendable {
    /// What the device runs at, as it reports it, which is what the render core has to run at.
    var settings: DeviceSettings { get }
    func start() throws
    /// True once no render callback can reach the engine again. Bounded, and false when the bound
    /// is hit; calling it again takes up the wait.
    func stop() -> Bool
}

/// Polls `condition` until it holds or `timeout` has passed, and returns whether it held.
func waitUntil(timeout: Duration, _ condition: () -> Bool) -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        Thread.sleep(forTimeInterval: 0.001)
    }
    return true
}

/// One AUHAL unit running the render core on one device.
///
/// `start` and `stop` come from one thread at a time, which `AudioEngine` guarantees.
final class HALStream: DeviceStream, @unchecked Sendable {

    private struct UnitBox: @unchecked Sendable {
        let unit: AudioUnit
    }

    let settings: DeviceSettings
    private let unit: AudioUnit
    private let link: OpaquePointer
    private let stopCall = DispatchGroup()
    private var stopRequested = false
    private var isReleased = false

    private init(settings: DeviceSettings, unit: AudioUnit, link: OpaquePointer) {
        self.settings = settings
        self.unit = unit
        self.link = link
    }

    /// The client formats take the rate the device reports after the write, and not the requested
    /// one: AUHAL has no rate conversion on input, so that format has to match the device.
    static func open(_ request: StreamRequest, engine: OpaquePointer) throws -> HALStream {
        guard let device = DeviceCatalog.object(uid: request.device.id),
            let current = DeviceCatalog.currentSettings(of: device)
        else { throw AudioEngineError.deviceUnavailable(request.device.name) }

        let inputs = request.usesInput ? UInt32(request.device.inputChannels.count) : 0
        let outputs = UInt32(request.device.outputChannels.count)

        let unit = try makeUnit()
        var link: OpaquePointer?
        do {
            try attach(unit, to: device, inputs: inputs)
            try write(settingsToWrite(current: current, requested: request.settings), to: device)
            guard let actual = DeviceCatalog.currentSettings(of: device) else {
                throw AudioEngineError.deviceUnavailable(request.device.name)
            }
            try setFormats(unit, inputs: inputs, outputs: outputs, sampleRate: actual.sampleRate)
            guard let created = pr_device_link_create(engine, unit, AudioEngine.maxFrames, inputs, outputs) else {
                throw AudioEngineError.osStatus(kAudio_MemFullError, "Device buffers")
            }
            link = created
            var callback = pr_device_link_render_callback(created)
            try check(
                AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, outputElement, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                "SetRenderCallback"
            )
            try check(AudioUnitInitialize(unit), "AudioUnitInitialize")
            return HALStream(settings: actual, unit: unit, link: created)
        } catch {
            AudioComponentInstanceDispose(unit)
            if let link { pr_device_link_destroy(link) }
            throw error
        }
    }

    func start() throws {
        try Self.check(AudioOutputUnitStart(unit), "AudioOutputUnitStart")
    }

    /// The stop call runs on its own thread: it may wait for a callback stuck in a plugin, and the
    /// bound has to hold through that wait as well. `isRunning` is only read once that call has
    /// returned, since reading it could wait in the same way.
    func stop() -> Bool {
        guard !isReleased else { return true }
        if !stopRequested {
            stopRequested = true
            pr_device_link_close(link)
            let box = UnitBox(unit: unit)
            DispatchQueue.global(qos: .userInitiated).async(group: stopCall) { AudioOutputUnitStop(box.unit) }
        }
        let stopped = waitUntil(timeout: stopBound) {
            stopCall.wait(timeout: .now()) == .success && !isRunning && pr_device_link_is_idle(link)
        }
        guard stopped else { return false }

        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        pr_device_link_destroy(link)
        isReleased = true
        return true
    }

    private var isRunning: Bool {
        var running: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, outputElement, &running, &size)
        return status != noErr || running != 0
    }

    // MARK: - Setup

    private static func makeUnit() throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioEngineError.osStatus(kAudioUnitErr_FailedInitialization, "AudioComponentFindNext")
        }
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &unit), "AudioComponentInstanceNew")
        guard let unit else { throw AudioEngineError.osStatus(kAudioUnitErr_FailedInitialization, "AudioComponentInstanceNew") }
        return unit
    }

    private static func attach(_ unit: AudioUnit, to device: AudioObjectID, inputs: UInt32) throws {
        // These two have to come before the device is set.
        try setProperty(unit, kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output, element: outputElement, UInt32(1))
        try setProperty(unit, kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Input, element: inputElement, UInt32(inputs > 0 ? 1 : 0))
        try setProperty(unit, kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global, element: outputElement, device)
    }

    private static func setFormats(_ unit: AudioUnit, inputs: UInt32, outputs: UInt32, sampleRate: Double) throws {
        try setProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, scope: kAudioUnitScope_Global, element: outputElement, AudioEngine.maxFrames)
        try setProperty(unit, kAudioUnitProperty_StreamFormat, scope: kAudioUnitScope_Input, element: outputElement, clientFormat(channels: outputs, sampleRate: sampleRate))
        if inputs > 0 {
            try setProperty(unit, kAudioUnitProperty_StreamFormat, scope: kAudioUnitScope_Output, element: inputElement, clientFormat(channels: inputs, sampleRate: sampleRate))
        }
    }

    private static func clientFormat(channels: UInt32, sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0
        )
    }

    private static func setProperty<Value: BitwiseCopyable>(_ unit: AudioUnit, _ property: AudioUnitPropertyID, scope: AudioUnitScope, element: AudioUnitElement, _ value: Value) throws {
        var value = value
        try check(AudioUnitSetProperty(unit, property, scope, element, &value, UInt32(MemoryLayout<Value>.size)), "Property \(property)")
    }

    /// The only place that writes to a device. A device takes a new sample rate some time after
    /// the call returns, so this waits for it.
    private static func write(_ change: DeviceSettingsChange, to device: AudioObjectID) throws {
        if var sampleRate = change.sampleRate {
            var address = propertyAddress(kAudioDevicePropertyNominalSampleRate)
            try check(AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &sampleRate), "Set sample rate")
            let requested = sampleRate
            guard waitUntil(timeout: settingBound, { DeviceCatalog.currentSettings(of: device)?.sampleRate == requested }) else {
                throw AudioEngineError.osStatus(kAudioHardwareUnspecifiedError, "Set sample rate")
            }
        }
        if var bufferFrames = change.bufferFrames {
            var address = propertyAddress(kAudioDevicePropertyBufferFrameSize)
            try check(AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &bufferFrames), "Set buffer size")
        }
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw AudioEngineError.osStatus(status, what) }
    }
}

/// Reports `kAudioHardwarePropertyDevices` on the main queue until it is removed.
final class DeviceListListener: @unchecked Sendable {
    private var block: AudioObjectPropertyListenerBlock?

    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in onChange() }
        }
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
            self.block = block
        }
    }

    func remove() {
        guard let block else { return }
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        self.block = nil
    }
}
