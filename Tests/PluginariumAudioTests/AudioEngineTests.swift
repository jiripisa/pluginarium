import AVFoundation
import AudioToolbox
import CRenderCore
import Foundation
import PluginariumCore
import Testing
@testable import PluginariumAudio

// Hardware safety: a test never writes a device setting and never makes a sound. Only
// `deviceLossAndReturn` starts a real device. It names no device, so the engine follows the default
// output and requests nothing, refuses to open a stream that does request something, needs a device
// without inputs, and keeps the graph empty. A test must never start a real device by name: that path
// writes to it when its settings have moved. Every other test that opens a stream uses `FakeStream`,
// and a device with inputs appears only with the microphone seams replaced.

private let stereoOut = ["Left", "Right"]
private let renderCoreLimit = 4096

private func device(_ id: String, inputs: [String] = [], outputs: [String] = stereoOut) -> AudioDevice {
    AudioDevice(id: id, name: "Device \(id)", inputChannels: inputs, outputChannels: outputs)
}

private func settings(for device: AudioDevice?, sampleRate: Double = 48_000, bufferFrames: Int = 128) -> AppSettings {
    var settings = AppSettings.defaults
    settings.audioDeviceUID = device?.id
    settings.sampleRate = sampleRate
    settings.bufferFrames = bufferFrames
    return settings
}

private struct StartFailed: Error {}

/// Stands in for the AUHAL unit, so the engine's obligations can be checked without a device.
private final class FakeStream: DeviceStream, @unchecked Sendable {
    let request: StreamRequest
    var settings: DeviceSettings
    var startError: (any Error)?
    var stopsInTime = true
    var onStart: () -> Void = {}
    var onStop: () -> Void = {}
    private(set) var startCalls = 0
    private(set) var stopCalls = 0

    init(request: StreamRequest, settings: DeviceSettings) {
        self.request = request
        self.settings = settings
    }

    func start() throws {
        startCalls += 1
        onStart()
        if let startError { throw startError }
    }

    func stop() -> Bool {
        stopCalls += 1
        onStop()
        return stopsInTime
    }
}

/// An engine that opens fake streams, over a device list a test can change.
@MainActor
private final class Bench {
    var devices: [AudioDevice]
    var opened: [FakeStream] = []
    var prepare: (FakeStream) -> Void = { _ in }
    var defaultOutput: AudioDevice?
    /// What a device runs at when nothing is asked of it.
    var deviceSettings = DeviceSettings(sampleRate: 96_000, bufferFrames: 512)
    var microphone = AVAuthorizationStatus.authorized
    var microphoneRequests = 0
    var answerMicrophone: (@Sendable (Bool) -> Void)?
    private(set) var engine: AudioEngine!

    init(devices: [AudioDevice] = [device("a")]) {
        self.devices = devices
        engine = AudioEngine(devices: { [unowned self] in self.devices })
        engine.seams.defaultOutput = { [unowned self] in self.defaultOutput }
        engine.seams.open = { [unowned self] request, _ in
            let stream = FakeStream(request: request, settings: request.settings ?? self.deviceSettings)
            self.prepare(stream)
            self.opened.append(stream)
            return stream
        }
        engine.seams.microphoneStatus = { [unowned self] in self.microphone }
        engine.seams.requestMicrophone = { [unowned self] answer in
            self.microphoneRequests += 1
            self.answerMicrophone = answer
        }
    }

    /// True when the render core has been told audio runs. A new generation is taken at once
    /// unless it has, since nothing renders here.
    var markedRunning: Bool {
        !pr_engine_is_generation_taken(engine.renderEngine, pr_engine_install_graph(engine.renderEngine, nil, 0))
    }

    /// Lets the `Task` that carries a microphone answer run.
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

// MARK: - Calling the render callback the way AUHAL does

/// One device output block. Starts full of noise, so a callback that writes nothing shows.
@discardableResult
private func renderDeviceBlock(_ link: OpaquePointer, frames: UInt32, channels: Int = 2, sampleTime: Double = 0) -> (output: [[Float]], flags: AudioUnitRenderActionFlags) {
    var output = [[Float]](repeating: [Float](repeating: 1, count: Int(frames)), count: channels)
    var flags = AudioUnitRenderActionFlags()
    withMutablePointers(&output) { pointers in
        let list = AudioBufferList.allocate(maximumBuffers: channels)
        defer { list.unsafeMutablePointer.deallocate() }
        for channel in 0..<channels {
            list[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: pointers[channel])
        }
        var timeStamp = AudioTimeStamp()
        timeStamp.mSampleTime = sampleTime
        timeStamp.mFlags = .sampleTimeValid
        let callback = pr_device_link_render_callback(link)
        let status = callback.inputProc?(callback.inputProcRefCon!, &flags, &timeStamp, 0, frames, list.unsafeMutablePointer)
        #expect(status == noErr)
    }
    return (output, flags)
}

/// What a splitter's input reads. Its second output stands in for the AUHAL input element, so a
/// pull on bus 1 really runs. `onPull` runs inside the device callback.
private final class InputFeed: @unchecked Sendable {
    let level: Float = 0.5
    var pullStatus: OSStatus = noErr
    var onPull: () -> Void = {}

    func attach(to unit: AudioUnit) -> OSStatus {
        var callback = AURenderCallbackStruct(
            inputProc: { refCon, _, _, _, frames, data in
                let feed = Unmanaged<InputFeed>.fromOpaque(refCon).takeUnretainedValue()
                feed.onPull()
                guard feed.pullStatus == noErr else { return feed.pullStatus }
                for buffer in UnsafeMutableAudioBufferListPointer(data!) {
                    let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
                    samples.update(repeating: feed.level, count: Int(frames))
                }
                return noErr
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        return AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    }
}

/// Sync, because a semaphore must not be waited on directly from an async test.
private func blockUntilSignalled(_ semaphore: DispatchSemaphore) {
    semaphore.wait()
}

private func splitter() async throws -> HostedPlugin {
    try await loadPlugin(type: "aufc", subtype: "splt", manufacturer: "appl")
}

/// A gain strip reading device inputs 0 and 1, so what the callback pulled shows on outputs 0 and 1.
private func inputRig() async throws -> Rig {
    let rig = Rig()
    rig.install([StripSpec(source: try await gain(), audioIn: PRChannels(left: 0, right: 1))])
    return rig
}

/// What an input level of 0.5 gives through `inputRig`, so these tests do not repeat the unit's gain.
private func gainLevel(from rig: Rig) -> Float {
    let level = rig.render(frames: 64, input: constantInput([0: 0.5, 1: 0.5], frames: 64))[0][0]
    #expect(level > 0)
    return level
}

@Suite("Audio engine")
@MainActor
struct AudioEngineTests {

    // MARK: - Catalog

    @Test func catalogListsDefaultOutput() {
        #expect(DeviceCatalog.defaultOutput() != nil)
    }

    @Test("The default output is one of the listed devices")
    func defaultOutputIsListed() throws {
        let output = try #require(DeviceCatalog.defaultOutput())
        #expect(DeviceCatalog.all().contains(output))
    }

    @Test("Every listed channel has a name")
    func everyChannelHasAName() {
        for device in DeviceCatalog.all() {
            #expect(!(device.inputChannels + device.outputChannels).contains(""), "\(device.name)")
        }
    }

    @Test("A channel without a system name is called Channel N, counted from one")
    func channelNameFallback() {
        #expect(channelName(reported: "Mic 1", index: 0) == "Mic 1")
        #expect(channelName(reported: nil, index: 0) == "Channel 1")
        #expect(channelName(reported: "", index: 2) == "Channel 3")
    }

    @Test("The current settings of the default output can be read")
    func currentSettingsOfDefaultOutput() throws {
        let output = try #require(DeviceCatalog.defaultOutput())
        let current = try #require(DeviceCatalog.currentSettings(of: output))
        #expect(current.sampleRate > 0)
        #expect(current.bufferFrames > 0)
    }

    @Test("A device the system does not know has no settings")
    func unknownDeviceHasNoSettings() {
        #expect(DeviceCatalog.currentSettings(of: device("no such device")) == nil)
    }

    // MARK: - What start writes to a device

    @Test("Nothing is written when the device already runs at the requested settings")
    func equalSettingsWriteNothing() {
        let current = DeviceSettings(sampleRate: 48_000, bufferFrames: 128)
        #expect(settingsToWrite(current: current, requested: current) == DeviceSettingsChange())
    }

    @Test("Only the setting that differs is written")
    func onlyDifferencesAreWritten() {
        let current = DeviceSettings(sampleRate: 48_000, bufferFrames: 128)
        #expect(
            settingsToWrite(current: current, requested: DeviceSettings(sampleRate: 44_100, bufferFrames: 128))
                == DeviceSettingsChange(sampleRate: 44_100)
        )
        #expect(
            settingsToWrite(current: current, requested: DeviceSettings(sampleRate: 48_000, bufferFrames: 256))
                == DeviceSettingsChange(bufferFrames: 256)
        )
        #expect(
            settingsToWrite(current: current, requested: DeviceSettings(sampleRate: 96_000, bufferFrames: 64))
                == DeviceSettingsChange(sampleRate: 96_000, bufferFrames: 64)
        )
    }

    @Test("Nothing is written when no settings were requested, whatever the device runs at")
    func noRequestWritesNothing() {
        let current = DeviceSettings(sampleRate: 96_000, bufferFrames: 512)
        #expect(settingsToWrite(current: current, requested: nil) == DeviceSettingsChange())
    }

    @Test("Only a device the owner picked is given settings")
    func onlyAPickedDeviceIsGivenSettings() {
        #expect(chosenSettings(in: .defaults) == nil)
        #expect(chosenSettings(in: settings(for: nil, sampleRate: 44_100, bufferFrames: 256)) == nil)
        #expect(
            chosenSettings(in: settings(for: device("a"), sampleRate: 44_100, bufferFrames: 256))
                == DeviceSettings(sampleRate: 44_100, bufferFrames: 256)
        )
    }

    // MARK: - Starting

    @Test func missingDeviceReportsStateWithoutThrowing() throws {
        let engine = AudioEngine(devices: { [] })
        var settings = AppSettings.defaults
        settings.audioDeviceUID = "gone"
        try engine.start(settings: settings)
        #expect(engine.state == .deviceMissing("gone"))
    }

    @Test("A nil device means the default output")
    func nilDeviceMeansDefaultOutput() throws {
        let bench = Bench(devices: [device("other"), device("system")])
        bench.defaultOutput = device("system")
        try bench.engine.start(settings: settings(for: nil))
        #expect(bench.engine.state == .running(device("system")))
    }

    @Test("A nil device with no default output is missing, not an error")
    func noDefaultOutput() throws {
        let bench = Bench()
        try bench.engine.start(settings: settings(for: nil))
        #expect(bench.engine.state == .deviceMissing(""))
    }

    @Test("A stream opens with the device and the requested settings")
    func streamOpensWithTheRequest() throws {
        let bench = Bench()
        try bench.engine.start(settings: settings(for: bench.devices[0], sampleRate: 44_100, bufferFrames: 256))
        let stream = try #require(bench.opened.first)
        #expect(stream.request.device == bench.devices[0])
        #expect(stream.request.settings == DeviceSettings(sampleRate: 44_100, bufferFrames: 256))
        #expect(stream.startCalls == 1)
    }

    @Test("Beats follow the sample rate the engine started at")
    func startSetsTheRenderSampleRate() throws {
        let bench = Bench()
        try bench.engine.start(settings: settings(for: bench.devices[0], sampleRate: 96_000))
        #expect(abs(renderedBeat(bench.engine.renderEngine, frames: 960) - beats(frames: 960, at: 96_000)) < 1e-9)
    }

    @Test("The largest buffer is accepted and a larger one is refused")
    func bufferLimit() throws {
        let bench = Bench()
        try bench.engine.start(settings: settings(for: bench.devices[0], bufferFrames: renderCoreLimit))
        #expect(bench.opened.count == 1)
        #expect(throws: AudioEngineError.self) {
            try bench.engine.start(settings: settings(for: bench.devices[0], bufferFrames: renderCoreLimit + 1))
        }
        #expect(bench.opened.count == 1)
        #expect(bench.opened[0].stopCalls == 0)
        #expect(bench.engine.state == .running(bench.devices[0]))
    }

    @Test("Settings no device can run are refused")
    func invalidSettings() {
        let bench = Bench()
        for bad in [settings(for: bench.devices[0], bufferFrames: 0), settings(for: bench.devices[0], sampleRate: 0)] {
            #expect(throws: AudioEngineError.self) { try bench.engine.start(settings: bad) }
        }
        #expect(bench.opened.isEmpty)
    }

    @Test("A device without outputs is refused")
    func deviceWithoutOutputs() {
        let mic = device("mic", inputs: ["Mic"], outputs: [])
        let bench = Bench(devices: [mic])
        #expect(throws: AudioEngineError.self) { try bench.engine.start(settings: settings(for: mic)) }
        #expect(bench.opened.isEmpty)
        #expect(bench.engine.state == .stopped)
    }

    @Test("Starting again stops the running stream first")
    func startingAgainReplacesTheStream() throws {
        let bench = Bench(devices: [device("a"), device("b")])
        try bench.engine.start(settings: settings(for: bench.devices[0]))
        try bench.engine.start(settings: settings(for: bench.devices[1]))
        #expect(bench.opened.count == 2)
        #expect(bench.opened[0].stopCalls == 1)
        #expect(bench.opened[1].stopCalls == 0)
        #expect(bench.engine.state == .running(bench.devices[1]))
    }

    @Test("A device the system does not know makes start throw")
    func unknownDeviceThrowsOnTheRealPath() throws {
        let ghost = device("no such device")
        let engine = AudioEngine(devices: { [ghost] })
        #expect(throws: AudioEngineError.self) { try engine.start(settings: settings(for: ghost)) }
        #expect(engine.state == .stopped)
    }

    // MARK: - Render core obligations

    @Test("The render core is marked running before the first render can come")
    func markedRunningBeforeStart() throws {
        let bench = Bench()
        var markedAtStart: Bool?
        bench.prepare = { stream in stream.onStart = { markedAtStart = bench.markedRunning } }
        #expect(!bench.markedRunning)
        try bench.engine.start(settings: settings(for: bench.devices[0]))
        #expect(markedAtStart == true)
        #expect(bench.markedRunning)
    }

    @Test("A failed start is marked stopped again and throws")
    func failedStart() {
        let bench = Bench()
        bench.prepare = { $0.startError = StartFailed() }
        #expect(throws: StartFailed.self) { try bench.engine.start(settings: settings(for: bench.devices[0])) }
        #expect(!bench.markedRunning)
        #expect(bench.opened[0].stopCalls == 1)
        #expect(bench.engine.state == .stopped)
    }

    @Test("A failed start that will not stop stays marked running")
    func failedStartThatWillNotStop() throws {
        let bench = Bench()
        bench.prepare = { stream in
            stream.startError = StartFailed()
            stream.stopsInTime = false
        }
        try bench.engine.start(settings: settings(for: bench.devices[0]))
        #expect(bench.markedRunning)
        #expect(bench.engine.state == .deviceMissing("a"))
    }

    @Test("The render core stays marked running until the stream has stopped")
    func markedStoppedOnlyAfterTheStreamStopped() throws {
        let bench = Bench()
        var markedDuringStop: Bool?
        bench.prepare = { stream in stream.onStop = { markedDuringStop = bench.markedRunning } }
        try bench.engine.start(settings: settings(for: bench.devices[0]))
        bench.engine.stop()
        #expect(markedDuringStop == true)
        #expect(!bench.markedRunning)
        #expect(bench.engine.state == .stopped)
    }

    @Test("A stream that will not stop leaves the core marked running and reports the device missing")
    func stopTimeout() throws {
        let bench = Bench()
        bench.prepare = { $0.stopsInTime = false }
        try bench.engine.start(settings: settings(for: bench.devices[0]))
        bench.engine.stop()
        #expect(bench.markedRunning)
        #expect(bench.engine.state == .deviceMissing("a"))
    }

    @Test("Nothing starts while an old stream can still render, and it can once that stream stops")
    func stuckStreamBlocksTheNextStart() throws {
        let bench = Bench()
        bench.prepare = { $0.stopsInTime = false }
        let settings = settings(for: bench.devices[0])
        try bench.engine.start(settings: settings)
        bench.engine.stop()

        try bench.engine.start(settings: settings)
        #expect(bench.opened.count == 1)
        #expect(bench.engine.state == .deviceMissing("a"))
        #expect(bench.markedRunning)

        bench.prepare = { _ in }
        bench.opened[0].stopsInTime = true
        try bench.engine.start(settings: settings)
        #expect(bench.opened.count == 2)
        #expect(bench.engine.state == .running(bench.devices[0]))
    }

    @Test("A stop that timed out still forgets the device")
    func timedOutStopForgetsTheDevice() throws {
        let bench = Bench()
        bench.prepare = { $0.stopsInTime = false }
        try bench.engine.start(settings: settings(for: bench.devices[0]))
        bench.engine.stop()

        bench.opened[0].stopsInTime = true
        bench.engine.handleDeviceChange()

        #expect(bench.opened.count == 1)
        #expect(bench.engine.state == .deviceMissing("a"))
    }

    @Test("Deinit stops the stream")
    func deinitStopsTheStream() throws {
        var bench: Bench? = Bench()
        try bench!.engine.start(settings: settings(for: bench!.devices[0]))
        let stream = bench!.opened[0]
        bench = nil
        #expect(stream.stopCalls == 1)
    }

    @Test("Deinit leaves the render engine alive when the stream will not stop")
    func deinitLeaksTheEngineWhenStuck() throws {
        var bench: Bench? = Bench()
        bench!.prepare = { $0.stopsInTime = false }
        try bench!.engine.start(settings: settings(for: bench!.devices[0]))
        let renderEngine = bench!.engine.renderEngine
        bench = nil
        // Run under the address sanitizer, this read is what fails if the engine was destroyed.
        #expect(pr_engine_load(renderEngine) == 0)
    }

    @Test("A stream that runs, or would not stop, can still render")
    func canRenderFollowsTheStream() throws {
        let bench = Bench()
        #expect(!bench.engine.canRender)
        try bench.engine.start(settings: settings(for: bench.devices[0]))
        #expect(bench.engine.canRender)

        bench.opened[0].stopsInTime = false
        bench.engine.stop()
        #expect(bench.engine.canRender)

        bench.opened[0].stopsInTime = true
        bench.engine.stop()
        #expect(!bench.engine.canRender)
    }

    // MARK: - Device changes

    @Test("Losing the running device stops it and reports it missing")
    func losingTheRunningDevice() throws {
        let bench = Bench()
        try bench.engine.start(settings: settings(for: bench.devices[0]))
        bench.devices = []
        bench.engine.handleDeviceChange()
        #expect(bench.opened[0].stopCalls == 1)
        #expect(!bench.markedRunning)
        #expect(bench.engine.state == .deviceMissing("a"))
    }

    @Test("The wanted device coming back restarts with the last settings")
    func wantedDeviceReturns() throws {
        let bench = Bench()
        let wanted = bench.devices[0]
        bench.devices = []
        try bench.engine.start(settings: settings(for: wanted, sampleRate: 44_100, bufferFrames: 256))
        #expect(bench.opened.isEmpty)
        bench.devices = [wanted]
        bench.engine.handleDeviceChange()
        #expect(bench.engine.state == .running(wanted))
        #expect(bench.opened[0].request.settings == DeviceSettings(sampleRate: 44_100, bufferFrames: 256))
    }

    @Test("A change that leaves the running device alone does nothing")
    func unrelatedChange() throws {
        let bench = Bench()
        try bench.engine.start(settings: settings(for: bench.devices[0]))
        bench.devices.append(device("b"))
        bench.engine.handleDeviceChange()
        #expect(bench.opened.count == 1)
        #expect(bench.opened[0].stopCalls == 0)
    }

    @Test("A running device whose channels changed restarts with them")
    func channelsChanged() throws {
        let bench = Bench()
        try bench.engine.start(settings: settings(for: bench.devices[0]))
        let wider = device("a", outputs: ["1", "2", "3", "4"])
        bench.devices = [wider]
        bench.engine.handleDeviceChange()
        #expect(bench.opened.count == 2)
        #expect(bench.opened[0].stopCalls == 1)
        #expect(bench.engine.state == .running(wider))
    }

    @Test("Stopping forgets the device, so its return starts nothing")
    func stoppedEngineIgnoresChanges() throws {
        let bench = Bench()
        try bench.engine.start(settings: settings(for: bench.devices[0]))
        bench.engine.stop()
        bench.engine.handleDeviceChange()
        #expect(bench.opened.count == 1)
        #expect(bench.engine.state == .stopped)
    }

    @Test("Stopping while the device is missing ends the wait for it")
    func stopWhileMissing() throws {
        let bench = Bench()
        let wanted = bench.devices[0]
        bench.devices = []
        try bench.engine.start(settings: settings(for: wanted))
        bench.engine.stop()
        bench.devices = [wanted]
        bench.engine.handleDeviceChange()
        #expect(bench.engine.state == .stopped)
        #expect(bench.opened.isEmpty)
    }

    @Test("A stream that will not stop is not started again when its device changes")
    func stuckStreamIgnoresDeviceReturn() throws {
        let bench = Bench()
        bench.prepare = { $0.stopsInTime = false }
        let wanted = bench.devices[0]
        try bench.engine.start(settings: settings(for: wanted))
        bench.devices = []
        bench.engine.handleDeviceChange()
        #expect(bench.engine.state == .deviceMissing("a"))
        bench.devices = [wanted]
        bench.engine.handleDeviceChange()
        #expect(bench.engine.state == .deviceMissing("a"))
        #expect(bench.opened.count == 1)
        #expect(bench.markedRunning)
    }

    @Test("A restart that fails on the returned device keeps waiting")
    func failedRestart() throws {
        let bench = Bench()
        let wanted = bench.devices[0]
        try bench.engine.start(settings: settings(for: wanted))
        bench.devices = []
        bench.engine.handleDeviceChange()
        bench.prepare = { $0.startError = StartFailed() }
        bench.devices = [wanted]
        bench.engine.handleDeviceChange()
        #expect(bench.engine.state == .deviceMissing("a"))
        #expect(!bench.markedRunning)

        bench.prepare = { _ in }
        bench.engine.handleDeviceChange()
        #expect(bench.engine.state == .running(wanted))
    }

    @Test("A wanted default output moves to the new default when the running one leaves")
    func defaultOutputFollowsTheSystem() throws {
        let bench = Bench(devices: [device("a"), device("b")])
        bench.defaultOutput = device("a")
        try bench.engine.start(settings: settings(for: nil))

        bench.devices = [device("b")]
        bench.defaultOutput = device("b")
        bench.engine.handleDeviceChange()

        #expect(bench.opened[0].stopCalls == 1)
        #expect(bench.engine.state == .running(device("b")))
    }

    // MARK: - Following the default output

    @Test("A followed default output keeps what it runs at, for start")
    func followedDefaultKeepsItsSettings() throws {
        let bench = Bench()
        bench.defaultOutput = bench.devices[0]
        try bench.engine.start(settings: settings(for: nil, sampleRate: 44_100, bufferFrames: 256))

        #expect(bench.opened[0].request.settings == nil)
        #expect(bench.engine.runningSampleRate == 96_000)
        #expect(bench.engine.runningBufferFrames == 512)
    }

    @Test("Plain default settings ask nothing of the default output")
    func defaultSettingsAskNothing() throws {
        let bench = Bench()
        bench.defaultOutput = bench.devices[0]
        try bench.engine.start(settings: .defaults)
        #expect(bench.opened[0].request.settings == nil)
    }

    @Test("Headphones leaving hand over to the interface without touching its settings")
    func aPlugEventWritesNothing() throws {
        let headphones = device("headphones")
        let interface = device("interface")
        let bench = Bench(devices: [headphones, interface])
        bench.defaultOutput = headphones
        bench.deviceSettings = DeviceSettings(sampleRate: 44_100, bufferFrames: 256)
        try bench.engine.start(settings: settings(for: nil))

        bench.devices = [interface]
        bench.defaultOutput = interface
        bench.deviceSettings = DeviceSettings(sampleRate: 96_000, bufferFrames: 64)
        bench.engine.handleDeviceChange()

        #expect(bench.engine.state == .running(interface))
        #expect(bench.opened[1].request.settings == nil)
        #expect(bench.engine.runningSampleRate == 96_000)
        #expect(bench.engine.runningBufferFrames == 64)
        #expect(abs(renderedBeat(bench.engine.renderEngine, frames: 960) - beats(frames: 960, at: 96_000)) < 1e-9)
    }

    @Test("Settings a followed default would not use do not stop it")
    func followedDefaultIgnoresTheValues() throws {
        let bench = Bench()
        bench.defaultOutput = bench.devices[0]
        try bench.engine.start(settings: settings(for: nil, sampleRate: 0, bufferFrames: renderCoreLimit + 1))
        #expect(bench.engine.state == .running(bench.devices[0]))
    }

    @Test("A followed default with too large a buffer is refused, not written")
    func oversizedDefaultIsRefused() {
        let bench = Bench()
        bench.defaultOutput = bench.devices[0]
        bench.deviceSettings = DeviceSettings(sampleRate: 48_000, bufferFrames: UInt32(renderCoreLimit) + 1)

        #expect(throws: AudioEngineError.self) { try bench.engine.start(settings: settings(for: nil)) }

        #expect(bench.opened[0].request.settings == nil)
        #expect(bench.opened[0].startCalls == 0)
        #expect(bench.opened[0].stopCalls == 1)
        #expect(!bench.markedRunning)
        #expect(bench.engine.state == .stopped)
        #expect(bench.engine.runningSampleRate == nil)
    }

    @Test("The largest buffer on a followed default plays")
    func largestBufferOnDefaultPlays() throws {
        let bench = Bench()
        bench.defaultOutput = bench.devices[0]
        bench.deviceSettings = DeviceSettings(sampleRate: 48_000, bufferFrames: UInt32(renderCoreLimit))
        try bench.engine.start(settings: settings(for: nil))
        #expect(bench.engine.runningBufferFrames == renderCoreLimit)
    }

    @Test("A restart onto a default with too large a buffer reports it missing, and retries")
    func oversizedDefaultOnRestart() throws {
        let headphones = device("headphones")
        let interface = device("interface")
        let bench = Bench(devices: [headphones, interface])
        bench.defaultOutput = headphones
        try bench.engine.start(settings: settings(for: nil))

        bench.devices = [interface]
        bench.defaultOutput = interface
        bench.deviceSettings = DeviceSettings(sampleRate: 48_000, bufferFrames: 8_192)
        bench.engine.handleDeviceChange()
        #expect(bench.engine.state == .deviceMissing("interface"))
        #expect(!bench.markedRunning)
        #expect(bench.opened[1].startCalls == 0)

        bench.deviceSettings = DeviceSettings(sampleRate: 48_000, bufferFrames: 1_024)
        bench.engine.handleDeviceChange()
        #expect(bench.engine.state == .running(interface))
    }

    // MARK: - What is actually running

    @Test("Running values are what the device reports, not what was asked")
    func runningValuesComeFromTheDevice() throws {
        let bench = Bench()
        bench.prepare = { $0.settings = DeviceSettings(sampleRate: 44_100, bufferFrames: 130) }
        try bench.engine.start(settings: settings(for: bench.devices[0], sampleRate: 48_000, bufferFrames: 128))
        #expect(bench.engine.runningSampleRate == 44_100)
        #expect(bench.engine.runningBufferFrames == 130)
    }

    @Test("The render core runs at the rate the device reports")
    func renderCoreTakesTheReportedRate() throws {
        let bench = Bench()
        bench.prepare = { $0.settings = DeviceSettings(sampleRate: 44_100, bufferFrames: 128) }
        try bench.engine.start(settings: settings(for: bench.devices[0], sampleRate: 48_000))
        #expect(abs(renderedBeat(bench.engine.renderEngine, frames: 960) - beats(frames: 960, at: 44_100)) < 1e-9)
    }

    @Test("Running values are nil unless a device runs")
    func runningValuesFollowTheState() throws {
        let bench = Bench()
        let wanted = bench.devices[0]
        #expect(bench.engine.runningSampleRate == nil)
        #expect(bench.engine.runningBufferFrames == nil)

        try bench.engine.start(settings: settings(for: wanted))
        #expect(bench.engine.runningSampleRate == 48_000)
        #expect(bench.engine.runningBufferFrames == 128)

        bench.devices = []
        bench.engine.handleDeviceChange()
        #expect(bench.engine.runningSampleRate == nil)
        #expect(bench.engine.runningBufferFrames == nil)

        bench.devices = [wanted]
        bench.engine.handleDeviceChange()
        #expect(bench.engine.runningSampleRate == 48_000)

        bench.engine.stop()
        #expect(bench.engine.runningSampleRate == nil)
        #expect(bench.engine.runningBufferFrames == nil)
    }

    @Test("A stream that will not stop no longer counts as running")
    func runningValuesClearOnTimeout() throws {
        let bench = Bench()
        bench.prepare = { $0.stopsInTime = false }
        try bench.engine.start(settings: settings(for: bench.devices[0]))
        bench.engine.stop()
        #expect(bench.engine.runningSampleRate == nil)
    }

    @Test("onDeviceChange sees the running values of the new state")
    func onDeviceChangeSeesRunningValues() throws {
        let bench = Bench()
        var seen: [Double?] = []
        bench.engine.onDeviceChange = { seen.append(bench.engine.runningSampleRate) }
        try bench.engine.start(settings: settings(for: bench.devices[0], sampleRate: 44_100))
        bench.engine.stop()
        #expect(seen == [44_100, nil])
    }

    @Test("A missing default output starts when the system has one again")
    func defaultOutputReturns() throws {
        let bench = Bench(devices: [])
        try bench.engine.start(settings: settings(for: nil))
        #expect(bench.engine.state == .deviceMissing(""))

        bench.devices = [device("b")]
        bench.defaultOutput = device("b")
        bench.engine.handleDeviceChange()

        #expect(bench.engine.state == .running(device("b")))
    }

    // MARK: - onDeviceChange

    @Test("onDeviceChange runs after each state change and sees the new state")
    func onDeviceChangeFollowsState() throws {
        let bench = Bench()
        var seen: [EngineState] = []
        bench.engine.onDeviceChange = { seen.append(bench.engine.state) }
        let wanted = bench.devices[0]

        try bench.engine.start(settings: settings(for: wanted))
        bench.devices = []
        bench.engine.handleDeviceChange()
        bench.devices = [wanted]
        bench.engine.handleDeviceChange()
        bench.engine.stop()

        #expect(seen == [.running(wanted), .deviceMissing("a"), .running(wanted), .stopped])
    }

    @Test("onDeviceChange stays quiet when the state does not change")
    func onDeviceChangeIsQuietWithoutAChange() throws {
        let bench = Bench()
        var calls = 0
        try bench.engine.start(settings: settings(for: bench.devices[0]))
        bench.engine.onDeviceChange = { calls += 1 }
        bench.engine.handleDeviceChange()
        try bench.engine.start(settings: settings(for: bench.devices[0]))
        #expect(calls == 0)
    }

    @Test("onDeviceChange can stop the engine it was called from")
    func onDeviceChangeCanStopTheEngine() throws {
        let bench = Bench()
        bench.engine.onDeviceChange = {
            bench.engine.onDeviceChange = nil
            bench.engine.stop()
        }
        try bench.engine.start(settings: settings(for: bench.devices[0]))
        #expect(bench.engine.state == .stopped)
        #expect(!bench.markedRunning)
    }

    // MARK: - Microphone permission

    private static let interface = device("fuse", inputs: ["In 1", "In 2"], outputs: ["Out 1", "Out 2"])

    @Test("An output-only device never touches the microphone")
    func outputOnlyDeviceAsksNothing() throws {
        let bench = Bench()
        bench.microphone = .notDetermined
        bench.engine.seams.microphoneStatus = {
            Issue.record("the microphone status was read for an output-only device")
            return .notDetermined
        }
        try bench.engine.start(settings: settings(for: bench.devices[0]))
        #expect(bench.microphoneRequests == 0)
        #expect(bench.opened[0].request.usesInput == false)
        #expect(!bench.engine.inputPermissionDenied)
    }

    @Test("A device with inputs uses them when permission is granted")
    func grantedInput() throws {
        let bench = Bench(devices: [Self.interface])
        try bench.engine.start(settings: settings(for: Self.interface))
        #expect(bench.opened[0].request.usesInput)
        #expect(bench.microphoneRequests == 0)
        #expect(!bench.engine.inputPermissionDenied)
    }

    @Test("Denied permission reads as silence, not a failure", arguments: [AVAuthorizationStatus.denied, .restricted])
    func deniedInput(status: AVAuthorizationStatus) throws {
        let bench = Bench(devices: [Self.interface])
        bench.microphone = status
        try bench.engine.start(settings: settings(for: Self.interface))
        #expect(bench.engine.state == .running(Self.interface))
        #expect(bench.opened[0].request.usesInput == false)
        #expect(bench.engine.inputPermissionDenied)
        #expect(bench.microphoneRequests == 0)
    }

    @Test("An unanswered permission is requested while output plays")
    func unansweredPermissionIsRequested() throws {
        let bench = Bench(devices: [Self.interface])
        bench.microphone = .notDetermined
        try bench.engine.start(settings: settings(for: Self.interface))
        #expect(bench.microphoneRequests == 1)
        #expect(bench.engine.state == .running(Self.interface))
        #expect(bench.opened[0].request.usesInput == false)
        #expect(!bench.engine.inputPermissionDenied)
    }

    @Test("Granting permission restarts the device with its input")
    func grantRestartsWithInput() async throws {
        let bench = Bench(devices: [Self.interface])
        bench.microphone = .notDetermined
        try bench.engine.start(settings: settings(for: Self.interface))
        var changes = 0
        bench.engine.onDeviceChange = { changes += 1 }

        bench.microphone = .authorized
        bench.answerMicrophone?(true)
        await bench.settle()

        #expect(bench.opened.count == 2)
        #expect(bench.opened[0].stopCalls == 1)
        #expect(bench.opened[1].request.usesInput)
        #expect(!bench.engine.inputPermissionDenied)
        #expect(changes == 0)
    }

    @Test("Refusing permission keeps the device playing")
    func refusalKeepsPlaying() async throws {
        let bench = Bench(devices: [Self.interface])
        bench.microphone = .notDetermined
        try bench.engine.start(settings: settings(for: Self.interface))

        bench.answerMicrophone?(false)
        await bench.settle()

        #expect(bench.opened.count == 1)
        #expect(bench.opened[0].stopCalls == 0)
        #expect(bench.engine.inputPermissionDenied)
    }

    @Test("A later output-only device clears the denied flag")
    func deniedFlagFollowsTheDevice() throws {
        let plain = device("plain")
        let bench = Bench(devices: [Self.interface, plain])
        bench.microphone = .denied
        try bench.engine.start(settings: settings(for: Self.interface))
        #expect(bench.engine.inputPermissionDenied)
        try bench.engine.start(settings: settings(for: plain))
        #expect(!bench.engine.inputPermissionDenied)
    }

    // MARK: - dspLoad

    @Test("dspLoad reads the render core's load")
    func dspLoadReadsTheCore() {
        let bench = Bench()
        #expect(bench.engine.dspLoad == 0)
        let renderEngine = bench.engine.renderEngine
        var left = [Float](repeating: 0, count: 128)
        left.withUnsafeMutableBufferPointer { samples in
            let outputs: [UnsafeMutablePointer<Float>?] = [samples.baseAddress]
            pr_engine_render(renderEngine, 128, nil, 0, outputs, 1)
        }
        #expect(bench.engine.dspLoad == pr_engine_load(renderEngine))
    }

    // MARK: - The stop bound

    @Test("Waiting ends as soon as the condition holds")
    func waitEndsEarly() {
        var polls = 0
        let start = ContinuousClock.now
        let result = waitUntil(timeout: .seconds(5)) {
            polls += 1
            return polls == 3
        }
        #expect(result)
        #expect(polls == 3)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test("Waiting gives up at the bound")
    func waitGivesUp() {
        let start = ContinuousClock.now
        #expect(!waitUntil(timeout: .milliseconds(50)) { false })
        #expect(ContinuousClock.now - start >= .milliseconds(50))
    }

    // MARK: - Render callback

    @Test("The callback plays the engine on the device's channels")
    func callbackPlaysTheEngine() async throws {
        let rig = Rig()
        rig.install([StripSpec(source: try await instrument(), midiSlot: 0)])
        rig.press(slot: 0)
        let link = try #require(pr_device_link_create(rig.engine, nil, unitMaxFrames, 0, 3))
        defer { pr_device_link_destroy(link) }

        let (output, _) = renderDeviceBlock(link, frames: blockFrames, channels: 3)
        expectLevel(output[0], 0.25)
        expectLevel(output[1], 0.25)
        expectLevel(output[2], 0)
    }

    @Test("Input is pulled from bus 1 and reaches the graph")
    func callbackPullsInput() async throws {
        let rig = try await inputRig()
        let level = gainLevel(from: rig)
        let source = try await splitter()
        let feed = InputFeed()
        #expect(feed.attach(to: source.audioUnit) == noErr)
        let link = try #require(pr_device_link_create(rig.engine, source.audioUnit, unitMaxFrames, 2, 2))
        defer { pr_device_link_destroy(link) }

        let (output, _) = renderDeviceBlock(link, frames: blockFrames)
        expectLevel(output[0], level)
        expectLevel(output[1], level)
    }

    @Test("Input never comes from the output element")
    func callbackDoesNotPullTheOutputElement() async throws {
        let rig = try await inputRig()
        // A version 2 unit that checks the element: it plays the feed on 0 and has no 1, so only a
        // pull on 0 would be heard. Version 3 test units ignore the element.
        let delay = try await loadPlugin(type: "aufx", subtype: "dely", manufacturer: "appl")
        let feed = InputFeed()
        #expect(feed.attach(to: delay.audioUnit) == noErr)
        let link = try #require(pr_device_link_create(rig.engine, delay.audioUnit, unitMaxFrames, 2, 2))
        defer { pr_device_link_destroy(link) }

        expectLevel(renderDeviceBlock(link, frames: blockFrames).output[0], 0)
    }

    @Test("Input frames that are not available read as silence")
    func callbackFeedsSilenceWhenThePullFails() async throws {
        let rig = try await inputRig()
        let level = gainLevel(from: rig)
        let source = try await splitter()
        let feed = InputFeed()
        #expect(feed.attach(to: source.audioUnit) == noErr)
        let link = try #require(pr_device_link_create(rig.engine, source.audioUnit, unitMaxFrames, 2, 2))
        defer { pr_device_link_destroy(link) }

        // The good block first, so the input buffers hold samples that must not play again.
        expectLevel(renderDeviceBlock(link, frames: blockFrames, sampleTime: 0).output[0], level)
        feed.pullStatus = kAudioUnitErr_CannotDoInCurrentContext
        let (output, _) = renderDeviceBlock(link, frames: blockFrames, sampleTime: Double(blockFrames))
        expectLevel(output[0], 0)
        expectLevel(output[1], 0)
    }

    @Test("A block beyond the input buffers reads as silence and overruns nothing")
    func callbackFeedsSilenceBeyondCapacity() async throws {
        let rig = try await inputRig()
        let level = gainLevel(from: rig)
        let source = try await splitter()
        let feed = InputFeed()
        var pulls = 0
        feed.onPull = { pulls += 1 }
        #expect(feed.attach(to: source.audioUnit) == noErr)
        let capacity: UInt32 = 64
        let link = try #require(pr_device_link_create(rig.engine, source.audioUnit, capacity, 2, 2))
        defer { pr_device_link_destroy(link) }

        expectLevel(renderDeviceBlock(link, frames: capacity, sampleTime: 0).output[0], level)
        #expect(pulls == 1)
        expectLevel(renderDeviceBlock(link, frames: capacity + 1, sampleTime: 64).output[0], 0)
        #expect(pulls == 1)
    }

    @Test("A closed link writes silence and leaves the engine alone")
    func closedLinkLeavesTheEngineAlone() async throws {
        let rig = Rig()
        rig.install([StripSpec(source: try await instrument(), midiSlot: 0)])
        rig.press(slot: 0)
        let link = try #require(pr_device_link_create(rig.engine, nil, unitMaxFrames, 0, 2))
        defer { pr_device_link_destroy(link) }
        pr_engine_set_audio_running(rig.engine, true)
        defer { pr_engine_set_audio_running(rig.engine, false) }
        let generation = rig.install([])

        pr_device_link_close(link)
        let (output, flags) = renderDeviceBlock(link, frames: blockFrames)

        expectLevel(output[0], 0)
        expectLevel(output[1], 0)
        #expect(flags.contains(.unitRenderAction_OutputIsSilence))
        #expect(!rig.isTaken(generation))
    }

    @Test("The link reports a callback in flight until it returns, even when closed meanwhile")
    func idleOnlyAfterTheCallbackReturned() async throws {
        let rig = try await inputRig()
        let source = try await splitter()
        let feed = InputFeed()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        feed.onPull = {
            entered.signal()
            release.wait()
        }
        #expect(feed.attach(to: source.audioUnit) == noErr)
        let link = EngineHandle(engine: try #require(pr_device_link_create(rig.engine, source.audioUnit, unitMaxFrames, 2, 2)))
        defer { pr_device_link_destroy(link.engine) }
        #expect(pr_device_link_is_idle(link.engine))

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            renderDeviceBlock(link.engine, frames: blockFrames)
            done.signal()
        }
        blockUntilSignalled(entered)
        #expect(!pr_device_link_is_idle(link.engine))
        pr_device_link_close(link.engine)
        #expect(!pr_device_link_is_idle(link.engine))
        #expect(!waitUntil(timeout: .milliseconds(20)) { pr_device_link_is_idle(link.engine) })

        release.signal()
        blockUntilSignalled(done)
        #expect(pr_device_link_is_idle(link.engine))
    }

    @Test("No link is made without output channels or a block size")
    func linkNeedsChannelsAndFrames() {
        let rig = Rig()
        #expect(pr_device_link_create(rig.engine, nil, 0, 0, 2) == nil)
        #expect(pr_device_link_create(rig.engine, nil, unitMaxFrames, 0, 0) == nil)
    }

    // MARK: - Sample rate

    private func beats(frames: UInt32, at rate: Double) -> Double {
        Double(frames) * 2 / rate
    }

    /// Renders one block at 120 BPM and returns the beat it reached.
    private func renderedBeat(_ engine: OpaquePointer, frames: UInt32) -> Double {
        pr_engine_set_transport(engine, 120, true)
        var left = [Float](repeating: 0, count: Int(frames))
        left.withUnsafeMutableBufferPointer { samples in
            let outputs: [UnsafeMutablePointer<Float>?] = [samples.baseAddress]
            pr_engine_render(engine, frames, nil, 0, outputs, 1)
        }
        let info = pr_host_callback_info(engine)
        var beat = 0.0
        #expect(info.beatAndTempoProc?(info.hostUserData, &beat, nil) == noErr)
        return beat
    }

    @Test("Beats follow the sample rate set while stopped")
    func sampleRateDrivesTheBeat() {
        let rig = Rig()
        pr_engine_set_sample_rate(rig.engine, 96_000)
        #expect(abs(renderedBeat(rig.engine, frames: 960) - beats(frames: 960, at: 96_000)) < 1e-9)
    }

    @Test("A sample rate that is not positive is ignored")
    func badSampleRateIsIgnored() {
        let rig = Rig()
        pr_engine_set_sample_rate(rig.engine, 0)
        pr_engine_set_sample_rate(rig.engine, -1)
        pr_engine_set_sample_rate(rig.engine, .nan)
        #expect(abs(renderedBeat(rig.engine, frames: 960) - beats(frames: 960, at: sampleRate)) < 1e-9)
    }

    // MARK: - A real device

    /// Silent and writes nothing, under the rules at the top of this file.
    @Test func deviceLossAndReturn() throws {
        let output = try #require(DeviceCatalog.defaultOutput())
        guard output.inputChannels.isEmpty else {
            try Test.cancel("\(output.name) has inputs; starting it would enable the input element and ask for the microphone")
        }
        let before = try #require(DeviceCatalog.currentSettings(of: output))

        var list = [output]
        let engine = AudioEngine(devices: { list })
        // No fault in the engine may reach the device: a stream that asks for settings never opens.
        let open = engine.seams.open
        engine.seams.open = { request, renderEngine in
            #expect(request.settings == nil)
            guard request.settings == nil else { throw StartFailed() }
            return try open(request, renderEngine)
        }
        do {
            try engine.start(settings: settings(for: nil))
        } catch {
            try Test.cancel("\(output.name) has no way to start here: \(error)")
        }
        #expect(engine.state == .running(output))
        #expect(engine.runningSampleRate == before.sampleRate)
        #expect(engine.runningBufferFrames == Int(before.bufferFrames))

        // A generation is only taken by a render, so this proves the device calls the render core.
        let generation = pr_engine_install_graph(engine.renderEngine, nil, 0)
        #expect(waitUntil(timeout: .seconds(5)) { pr_engine_is_generation_taken(engine.renderEngine, generation) })

        list = []
        engine.handleDeviceChange()
        #expect(engine.state == .deviceMissing(output.id))
        #expect(pr_engine_is_generation_taken(engine.renderEngine, pr_engine_install_graph(engine.renderEngine, nil, 0)))

        list = [output]
        engine.handleDeviceChange()
        #expect(engine.state == .running(output))

        engine.stop()
        #expect(engine.state == .stopped)
        #expect(DeviceCatalog.currentSettings(of: output) == before)
    }
}
