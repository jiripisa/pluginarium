import AudioToolbox
import CRenderCore
import Foundation
import PluginariumCore
import PluginariumTestUnits
import Testing
@testable import PluginariumAudio

// Hardware safety: every stream here is a `FakeStream` over the bench's own device list, so no test
// opens a device, writes a setting or makes a sound.

private let instrumentID = PluginID(type: "aumu", subtype: "PlIn", manufacturer: "Plug")
private let delayID = PluginID(type: "aufx", subtype: "dely", manufacturer: "appl")

private let out01 = AudioChannels.stereo(left: 0, right: 1)
private let out23 = AudioChannels.stereo(left: 2, right: 3)
private let out1415 = AudioChannels.stereo(left: 14, right: 15)
private let keyDown = MIDIEvent.channelVoice(status: 0x90, data1: 60, data2: 100)
private let instrumentLevel: Float = 0.25
private let stereoOut = ["Left", "Right"]
private let sixteenOut = (1...16).map { "Out \($0)" }

private func device(_ id: String, outputs: [String] = stereoOut) -> AudioDevice {
    AudioDevice(id: id, name: "Device \(id)", inputChannels: [], outputChannels: outputs)
}

private func settings(for device: AudioDevice?, sampleRate: Double = 48_000, bufferFrames: Int = 128) -> AppSettings {
    var settings = AppSettings.defaults
    settings.audioDeviceUID = device?.id
    settings.sampleRate = sampleRate
    settings.bufferFrames = bufferFrames
    return settings
}

private func instrumentChannel(out: AudioChannels = out01, midiIn: MIDIRoute? = nil) -> Channel {
    Channel(kind: .instrument, slot: PluginSlot(plugin: instrumentID, displayName: "Instrument"), midiIn: midiIn, audioOut: out)
}

private func delayChannel(state: Data? = nil, out: AudioChannels = out01) -> Channel {
    Channel(kind: .effect, slot: PluginSlot(plugin: delayID, displayName: "Delay", state: state), audioIn: nil, audioOut: out)
}

private func configuration(_ channels: Channel...) -> Configuration {
    Configuration(name: "Test", channels: channels)
}

private func makeCache() -> CapabilityCache {
    CapabilityCache(file: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json"))
}

private func wetDryMix(of plugin: HostedPlugin?) throws -> AudioUnitParameterValue {
    let plugin = try #require(plugin)
    var value: AudioUnitParameterValue = 0
    AudioUnitGetParameter(plugin.audioUnit, kDelayParam_WetDryMix, kAudioUnitScope_Global, 0, &value)
    return value
}

private func setWetDryMix(of plugin: HostedPlugin?, to value: AudioUnitParameterValue) throws {
    AudioUnitSetParameter(try #require(plugin).audioUnit, kDelayParam_WetDryMix, kAudioUnitScope_Global, 0, value, 0)
}

private func runningRate(of plugin: HostedPlugin?) throws -> Double {
    let plugin = try #require(plugin)
    var rate = 0.0
    var size = UInt32(MemoryLayout<Double>.size)
    AudioUnitGetProperty(plugin.audioUnit, kAudioUnitProperty_SampleRate, kAudioUnitScope_Output, 0, &rate, &size)
    return rate
}

private struct StartFailed: Error {}

/// Stands in for the AUHAL unit, so a session can run without a device.
private final class FakeStream: DeviceStream, @unchecked Sendable {
    let request: StreamRequest
    let settings: DeviceSettings
    var startError: (any Error)?
    var stopsInTime = true
    var onStop: () -> Void = {}
    private(set) var startCalls = 0
    private(set) var stopCalls = 0

    init(request: StreamRequest, settings: DeviceSettings) {
        self.request = request
        self.settings = settings
    }

    func start() throws {
        startCalls += 1
        if let startError { throw startError }
    }

    func stop() -> Bool {
        stopCalls += 1
        onStop()
        return stopsInTime
    }
}

/// A session whose engine opens fake streams, over a device list a test can change. The session
/// follows the default output unless a test names a device.
@MainActor
private final class Bench {
    var devices: [AudioDevice]
    var defaultOutput: AudioDevice?
    var opened: [FakeStream] = []
    var prepare: (FakeStream) -> Void = { _ in }
    /// What a device runs at when nothing is asked of it.
    var deviceSettings = DeviceSettings(sampleRate: 96_000, bufferFrames: 512)
    private(set) var engine: AudioEngine!
    private(set) var session: AudioSession!

    init(devices: [AudioDevice] = [device("a")]) {
        registerTestUnits()
        self.devices = devices
        defaultOutput = devices.first
        engine = AudioEngine(devices: { [unowned self] in self.devices })
        engine.seams.defaultOutput = { [unowned self] in self.defaultOutput }
        engine.seams.open = { [unowned self] request, _ in
            let stream = FakeStream(request: request, settings: request.settings ?? self.deviceSettings)
            self.prepare(stream)
            self.opened.append(stream)
            return stream
        }
        session = AudioSession(cache: makeCache(), engine: engine)
    }

    /// The device leaves, which the engine hears about from the system.
    func loseDevices() {
        devices = []
        defaultOutput = nil
        engine.handleDeviceChange()
    }

    /// `device` becomes the default output, as the only device or next to the ones there are.
    func bringDevice(_ device: AudioDevice, replacing: Bool = true) async {
        devices = replacing ? [device] : devices + [device]
        defaultOutput = device
        engine.handleDeviceChange()
        await session.reapplying?.value
    }

    /// Counts what the session is told, and passes it on.
    func countDeviceChanges() -> () -> Int {
        var calls = 0
        let forward = engine.onDeviceChange
        engine.onDeviceChange = {
            calls += 1
            forward?()
        }
        return { calls }
    }

    /// One block through the render core, the way the device would ask for it.
    func render() -> [[Float]] {
        var output = [[Float]](repeating: [Float](repeating: 1, count: Int(blockFrames)), count: 2)
        withMutablePointers(&output) { outputs in
            pr_engine_render(engine.renderEngine, blockFrames, nil, 0, outputs.baseAddress, UInt32(outputs.count))
        }
        return output
    }
}

/// Holds plugin loads until a test lets them go.
private actor LoadGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

@Suite("Audio session")
@MainActor
struct AudioSessionTests {

    // MARK: - Opening

    @Test("Nothing touches audio until a configuration opens")
    func nothingStartsBeforeOpen() {
        let bench = Bench()
        defer { bench.session.close() }
        #expect(bench.engine.state == .stopped)
        #expect(bench.opened.isEmpty)
        #expect(bench.session.runner == nil)
    }

    @Test("Opening starts the engine and plays the configuration")
    func openStartsAudio() async throws {
        let bench = Bench()
        defer { bench.session.close() }
        let channel = instrumentChannel()

        await bench.session.open(configuration(channel), settings: .defaults)

        #expect(bench.engine.state == .running(bench.devices[0]))
        #expect(bench.opened.count == 1)
        #expect(bench.opened[0].startCalls == 1)
        let runner = try #require(bench.session.runner)
        #expect(runner.plugin(channel: channel.id, effect: nil) != nil)
        #expect(runner.status == [channel.id: .ready])
    }

    @Test("Opening on a running engine leaves it running")
    func openKeepsARunningEngine() async {
        let bench = Bench()
        defer { bench.session.close() }
        await bench.session.open(configuration(instrumentChannel()), settings: .defaults)
        let runner = bench.session.runner

        await bench.session.open(configuration(instrumentChannel(out: out23)), settings: .defaults)

        #expect(bench.opened.count == 1)
        #expect(bench.session.runner === runner)
    }

    @Test("A runner takes the running sample rate, whatever the settings say")
    func runnerUsesTheRunningRate() async throws {
        let bench = Bench()
        defer { bench.session.close() }
        let channel = delayChannel()

        await bench.session.open(configuration(channel), settings: settings(for: nil, sampleRate: 44_100))

        #expect(bench.engine.runningSampleRate == 96_000)
        #expect(try runningRate(of: bench.session.runner?.plugin(channel: channel.id, effect: nil)) == 96_000)
    }

    @Test("A runner takes the channels of the running device")
    func runnerUsesTheRunningChannels() async throws {
        let bench = Bench()
        defer { bench.session.close() }
        let channel = instrumentChannel(out: out1415)

        await bench.session.open(configuration(channel), settings: .defaults)

        #expect(bench.session.runner?.status[channel.id] == .routingUnavailable("Out 15–16"))
    }

    @Test("A device nobody picked is never asked for settings")
    func noDeviceIsNamedUnlessPicked() async {
        let bench = Bench()
        defer { bench.session.close() }
        await bench.session.open(configuration(instrumentChannel()), settings: settings(for: nil, sampleRate: 44_100))
        bench.deviceSettings = DeviceSettings(sampleRate: 44_100, bufferFrames: 512)
        await bench.bringDevice(device("b"))

        #expect(bench.opened.count > 1)
        #expect(bench.opened.allSatisfy { $0.request.settings == nil })
    }

    @Test("A configuration that opens while the device is missing plays when it returns")
    func openWithoutADevice() async throws {
        let bench = Bench(devices: [])
        defer { bench.session.close() }
        let channel = instrumentChannel()

        await bench.session.open(configuration(channel), settings: .defaults)
        #expect(bench.engine.state == .deviceMissing(""))
        #expect(bench.session.runner == nil)

        await bench.bringDevice(device("a"))
        #expect(bench.session.runner?.plugin(channel: channel.id, effect: nil) != nil)
    }

    @Test("A device that fails to start is reported, and a change of settings tries again")
    func startFailureIsReported() async throws {
        let wanted = device("a")
        let bench = Bench(devices: [wanted])
        defer { bench.session.close() }
        bench.prepare = { $0.startError = StartFailed() }
        let channel = instrumentChannel()

        await bench.session.open(configuration(channel), settings: settings(for: wanted))
        #expect(bench.engine.state == .stopped)
        #expect(bench.session.runner == nil)
        #expect(bench.session.startFailure != nil)

        bench.prepare = { _ in }
        await bench.session.applySettings(settings(for: wanted, sampleRate: 44_100))
        #expect(bench.session.startFailure == nil)
        #expect(bench.session.runner?.plugin(channel: channel.id, effect: nil) != nil)
    }

    @Test("A failed open comes back at the next device change, with the configuration")
    func failedOpenRetries() async throws {
        let bench = Bench()
        defer { bench.session.close() }
        bench.prepare = { $0.startError = StartFailed() }
        let channel = instrumentChannel(midiIn: MIDIRoute(sourceName: "Keys", channel: .all))

        await bench.session.open(configuration(channel), settings: .defaults)
        #expect(bench.engine.state == .stopped)
        #expect(bench.session.runner == nil)
        #expect(bench.session.startFailure != nil)

        bench.prepare = { _ in }
        await bench.bringDevice(device("a"))

        #expect(bench.engine.state == .running(device("a")))
        #expect(bench.session.runner?.status == [channel.id: .ready])
        #expect(bench.session.startFailure == nil)
        #expect(bench.opened.allSatisfy { $0.request.settings == nil })
        bench.session.router.handle(keyDown, fromSource: "Keys", at: 0)
        expectLevel(bench.render()[0], instrumentLevel)
    }

    @Test("A failed restart on a moved default output comes back, at its rate and with its state")
    func failedRestartRetries() async throws {
        let bench = Bench()
        defer { bench.session.close() }
        let channel = delayChannel()
        await bench.session.open(configuration(channel), settings: .defaults)
        try setWetDryMix(of: bench.session.runner?.plugin(channel: channel.id, effect: nil), to: 33)

        // The engine opens the new default, and the reopen after the runner has gone fails.
        bench.deviceSettings = DeviceSettings(sampleRate: 44_100, bufferFrames: 512)
        bench.prepare = { [unowned bench] in
            if bench.opened.count == 2 { $0.startError = StartFailed() }
        }
        await bench.bringDevice(device("b"))
        #expect(bench.engine.state == .stopped)
        #expect(bench.session.runner == nil)
        #expect(bench.session.startFailure != nil)

        bench.prepare = { _ in }
        await bench.bringDevice(device("b"))

        let plugin = bench.session.runner?.plugin(channel: channel.id, effect: nil)
        #expect(bench.engine.state == .running(device("b")))
        #expect(try runningRate(of: plugin) == 44_100)
        #expect(try wetDryMix(of: plugin) == 33)
        #expect(bench.session.startFailure == nil)
        #expect(bench.opened.count == 4)
        #expect(bench.opened.allSatisfy { $0.request.settings == nil })
    }

    @Test("A picked device that failed comes back when it is power-cycled")
    func failedPickedDeviceReturns() async throws {
        let wanted = device("a")
        let bench = Bench(devices: [wanted])
        defer { bench.session.close() }
        bench.prepare = { $0.startError = StartFailed() }
        let channel = instrumentChannel()
        await bench.session.open(configuration(channel), settings: settings(for: wanted))

        bench.prepare = { _ in }
        bench.loseDevices()
        #expect(bench.engine.state == .deviceMissing("a"))
        #expect(bench.session.runner == nil)

        await bench.bringDevice(wanted)
        #expect(bench.engine.state == .running(wanted))
        #expect(bench.session.runner?.plugin(channel: channel.id, effect: nil) != nil)
        #expect(bench.session.startFailure == nil)
    }

    @Test("A retry that fails keeps the configuration waiting for the next device change")
    func failedRetryKeepsTheConfiguration() async throws {
        let bench = Bench()
        defer { bench.session.close() }
        bench.prepare = { $0.startError = StartFailed() }
        let channel = instrumentChannel()
        await bench.session.open(configuration(channel), settings: .defaults)

        await bench.bringDevice(device("a"))
        #expect(bench.engine.state == .deviceMissing("a"))
        #expect(bench.session.runner == nil)
        #expect(bench.session.startFailure != nil)
        #expect(bench.opened.count == 2)

        bench.prepare = { _ in }
        await bench.bringDevice(device("a"))
        #expect(bench.session.runner?.plugin(channel: channel.id, effect: nil) != nil)
        #expect(bench.session.startFailure == nil)
        #expect(bench.opened.count == 3)
    }

    @Test("A device change with nothing wanted starts nothing")
    func deviceChangeWithNothingWanted() async {
        let bench = Bench()
        defer { bench.session.close() }

        await bench.bringDevice(device("b"))

        #expect(bench.engine.state == .stopped)
        #expect(bench.opened.isEmpty)
        #expect(bench.session.runner == nil)
    }

    @Test("Closing ends the retries of a failed start")
    func closeEndsTheRetries() async {
        let bench = Bench()
        bench.prepare = { $0.startError = StartFailed() }
        await bench.session.open(configuration(instrumentChannel()), settings: .defaults)

        bench.session.close()
        bench.prepare = { _ in }
        await bench.bringDevice(device("a"))

        #expect(bench.engine.state == .stopped)
        #expect(bench.opened.count == 1)
        #expect(bench.session.runner == nil)
    }

    // MARK: - Edits and MIDI

    @Test("An edit reaches the runner and leaves what plays alone")
    func updateAppliesAnEdit() async throws {
        let bench = Bench()
        defer { bench.session.close() }
        let first = instrumentChannel()
        await bench.session.open(configuration(first), settings: .defaults)
        let kept = bench.session.runner?.plugin(channel: first.id, effect: nil)

        let second = instrumentChannel(out: out23)
        await bench.session.update(configuration(first, second))

        #expect(bench.session.runner?.plugin(channel: first.id, effect: nil) === kept)
        #expect(bench.session.runner?.plugin(channel: second.id, effect: nil) != nil)
        #expect(bench.opened.count == 1)
    }

    @Test("Opening routes MIDI to its channels")
    func openRoutesMIDI() async {
        let bench = Bench()
        defer { bench.session.close() }
        let route = MIDIRoute(sourceName: "Keys", channel: .all)

        await bench.session.open(configuration(instrumentChannel(midiIn: route)), settings: .defaults)
        bench.session.router.handle(keyDown, fromSource: "Keys", at: 0)

        expectLevel(bench.render()[0], instrumentLevel)
    }

    @Test("An edit refreshes the routes")
    func updateRefreshesRoutes() async {
        let bench = Bench()
        defer { bench.session.close() }
        var channel = instrumentChannel()
        await bench.session.open(configuration(channel), settings: .defaults)
        bench.session.router.handle(keyDown, fromSource: "Keys", at: 0)
        expectLevel(bench.render()[0], 0)

        channel.midiIn = MIDIRoute(sourceName: "Keys", channel: .all)
        await bench.session.update(configuration(channel))
        bench.session.router.handle(keyDown, fromSource: "Keys", at: 0)
        expectLevel(bench.render()[0], instrumentLevel)

        channel.midiIn = nil
        await bench.session.update(configuration(channel))
        bench.session.router.handle(.channelVoice(status: 0x80, data1: 60, data2: 0), fromSource: "Keys", at: 0)
        expectLevel(bench.render()[0], instrumentLevel)
    }

    @Test("Routes change at once, and do not wait for a slow plugin")
    func routesDoNotWaitForLoads() async throws {
        let bench = Bench()
        defer { bench.session.close() }
        var channel = instrumentChannel()
        await bench.session.open(configuration(channel), settings: .defaults)
        let runner = try #require(bench.session.runner)
        let gate = LoadGate()
        runner.seams.load = { id in
            await gate.pass()
            return try await HostedPlugin.load(id)
        }

        channel.midiIn = MIDIRoute(sourceName: "Keys", channel: .all)
        let slow = instrumentChannel(out: out23)
        let edit = Task { await bench.session.update(configuration(channel, slow)) }
        while runner.pendingLoads == 0 { await Task.yield() }

        bench.session.router.handle(keyDown, fromSource: "Keys", at: 0)
        expectLevel(bench.render()[0], instrumentLevel)

        await gate.open()
        await edit.value
    }

    // MARK: - Reloading

    @Test("Reloading restores saved state over what the plugin was doing")
    func reloadRestoresSavedState() async throws {
        let saved = try await HostedPlugin.load(delayID)
        try setWetDryMix(of: saved, to: 12)
        let channel = delayChannel(state: try saved.fullState())
        let config = configuration(channel)
        let bench = Bench()
        defer { bench.session.close() }
        await bench.session.open(config, settings: .defaults)
        let before = bench.session.runner?.plugin(channel: channel.id, effect: nil)
        try setWetDryMix(of: before, to: 77)

        await bench.session.reload(config, settings: .defaults)

        let after = bench.session.runner?.plugin(channel: channel.id, effect: nil)
        #expect(after !== before)
        #expect(try wetDryMix(of: after) == 12)
        #expect(bench.opened.count == 1)
    }

    @Test("Reloading starts audio when none runs")
    func reloadStartsAudio() async {
        let bench = Bench()
        defer { bench.session.close() }
        let channel = instrumentChannel()

        await bench.session.reload(configuration(channel), settings: .defaults)

        #expect(bench.opened.count == 1)
        #expect(bench.session.runner?.plugin(channel: channel.id, effect: nil) != nil)
    }

    @Test("A reload while the device is gone plays with its saved state when the device returns")
    func reloadWhileMissing() async throws {
        let saved = try await HostedPlugin.load(delayID)
        try setWetDryMix(of: saved, to: 12)
        let channel = delayChannel(state: try saved.fullState())
        let config = configuration(channel)
        let bench = Bench()
        defer { bench.session.close() }
        await bench.session.open(config, settings: .defaults)
        try setWetDryMix(of: bench.session.runner?.plugin(channel: channel.id, effect: nil), to: 77)
        bench.loseDevices()

        await bench.session.reload(config, settings: .defaults)
        await bench.bringDevice(device("a"))

        #expect(try wetDryMix(of: bench.session.runner?.plugin(channel: channel.id, effect: nil)) == 12)
    }

    // MARK: - Device changes

    @Test("Losing the device shuts the runner down, and its return reapplies")
    func deviceLossAndReturn() async throws {
        let bench = Bench()
        defer { bench.session.close() }
        let channel = instrumentChannel()
        await bench.session.open(configuration(channel), settings: .defaults)
        weak let lost = bench.session.runner?.plugin(channel: channel.id, effect: nil)
        #expect(lost != nil)

        bench.loseDevices()
        #expect(bench.engine.state == .deviceMissing(""))
        #expect(bench.session.runner == nil)
        #expect(lost == nil)

        await bench.bringDevice(device("a"))
        #expect(bench.engine.state == .running(device("a")))
        #expect(bench.session.runner?.plugin(channel: channel.id, effect: nil) != nil)
        #expect(bench.session.runner?.status == [channel.id: .ready])
    }

    @Test("MIDI routes come back with the device")
    func routesReturnWithTheDevice() async {
        let bench = Bench()
        defer { bench.session.close() }
        let route = MIDIRoute(sourceName: "Keys", channel: .all)
        await bench.session.open(configuration(instrumentChannel(midiIn: route)), settings: .defaults)

        bench.loseDevices()
        await bench.bringDevice(device("a"))
        bench.session.router.handle(keyDown, fromSource: "Keys", at: 0)

        expectLevel(bench.render()[0], instrumentLevel)
    }

    @Test("What a plugin was doing survives losing the device")
    func stateSurvivesDeviceLoss() async throws {
        let bench = Bench()
        defer { bench.session.close() }
        let channel = delayChannel()
        await bench.session.open(configuration(channel), settings: .defaults)
        try setWetDryMix(of: bench.session.runner?.plugin(channel: channel.id, effect: nil), to: 33)

        bench.loseDevices()
        await bench.bringDevice(device("a"))

        #expect(try wetDryMix(of: bench.session.runner?.plugin(channel: channel.id, effect: nil)) == 33)
    }

    @Test("An edit made while the device is gone plays when it returns, with the state it had")
    func editWhileMissing() async throws {
        let bench = Bench()
        defer { bench.session.close() }
        let channel = delayChannel()
        await bench.session.open(configuration(channel), settings: .defaults)
        try setWetDryMix(of: bench.session.runner?.plugin(channel: channel.id, effect: nil), to: 33)
        bench.loseDevices()

        let added = instrumentChannel(out: out23)
        await bench.session.update(configuration(channel, added))
        #expect(bench.session.runner == nil)
        await bench.bringDevice(device("a"))

        #expect(try wetDryMix(of: bench.session.runner?.plugin(channel: channel.id, effect: nil)) == 33)
        #expect(bench.session.runner?.plugin(channel: added.id, effect: nil) != nil)
    }

    @Test("State can be captured while the device is gone")
    func capturingWhileMissing() async throws {
        let bench = Bench()
        defer { bench.session.close() }
        let channel = delayChannel()
        let config = configuration(channel)
        await bench.session.open(config, settings: .defaults)
        try setWetDryMix(of: bench.session.runner?.plugin(channel: channel.id, effect: nil), to: 33)
        bench.loseDevices()

        let state = try #require(bench.session.capturingState(of: config).channels[0].slot.state)

        let restored = try await HostedPlugin.load(delayID)
        try restored.restore(state)
        #expect(try wetDryMix(of: restored) == 33)
    }

    @Test("Moving to a device at another rate rebuilds once at the new rate")
    func moveToAnotherRate() async throws {
        let bench = Bench()
        defer { bench.session.close() }
        let channel = delayChannel()
        await bench.session.open(configuration(channel), settings: .defaults)
        try setWetDryMix(of: bench.session.runner?.plugin(channel: channel.id, effect: nil), to: 33)
        let oldRunner = bench.session.runner
        let changes = bench.countDeviceChanges()

        bench.deviceSettings = DeviceSettings(sampleRate: 44_100, bufferFrames: 512)
        await bench.bringDevice(device("b"))

        let plugin = bench.session.runner?.plugin(channel: channel.id, effect: nil)
        #expect(bench.session.runner !== oldRunner)
        #expect(try runningRate(of: plugin) == 44_100)
        #expect(try wetDryMix(of: plugin) == 33)
        // The move, the stop that takes the runner down, and the start that brings the new one.
        #expect(changes() == 3)
        #expect(bench.opened.count == 3)
        #expect(bench.opened.dropLast().allSatisfy { $0.stopCalls == 1 })
        #expect(bench.opened.last?.startCalls == 1)
        #expect(bench.opened.last?.stopCalls == 0)
    }

    @Test("A runner is built from the device's new channels")
    func deviceChannelsChange() async throws {
        let bench = Bench()
        defer { bench.session.close() }
        let channel = instrumentChannel(out: out1415)
        await bench.session.open(configuration(channel), settings: .defaults)
        #expect(bench.session.runner?.status[channel.id] == .routingUnavailable("Out 15–16"))

        await bench.bringDevice(device("a", outputs: sixteenOut))

        #expect(bench.session.runner?.status[channel.id] == .ready)
    }

    @Test("A new device that runs the same way keeps every plugin playing")
    func sameValuesKeepTheRunner() async {
        let bench = Bench()
        defer { bench.session.close() }
        let channel = instrumentChannel()
        await bench.session.open(configuration(channel), settings: .defaults)
        let runner = bench.session.runner
        let plugin = runner?.plugin(channel: channel.id, effect: nil)

        await bench.bringDevice(device("b"))

        #expect(bench.engine.state == .running(device("b")))
        #expect(bench.session.runner === runner)
        #expect(bench.session.runner?.plugin(channel: channel.id, effect: nil) === plugin)
        #expect(bench.opened.count == 2)
    }

    @Test("Starting audio does not come back to the session as a device change")
    func startDoesNotRecurse() async {
        let bench = Bench()
        defer { bench.session.close() }
        let changes = bench.countDeviceChanges()

        await bench.session.open(configuration(instrumentChannel()), settings: .defaults)
        await bench.session.reapplying?.value

        #expect(changes() == 1)
        #expect(bench.session.reapplying == nil)
        #expect(bench.opened.count == 1)
    }

    @Test("A rate that changed without a device change is found on the next tick")
    func quietRateChange() async throws {
        let bench = Bench()
        defer { bench.session.close() }
        let channel = delayChannel()
        await bench.session.open(configuration(channel), settings: .defaults)

        bench.deviceSettings = DeviceSettings(sampleRate: 44_100, bufferFrames: 512)
        try bench.engine.start(settings: .defaults)
        #expect(try runningRate(of: bench.session.runner?.plugin(channel: channel.id, effect: nil)) == 96_000)

        bench.session.tick()
        await bench.session.reapplying?.value

        #expect(try runningRate(of: bench.session.runner?.plugin(channel: channel.id, effect: nil)) == 44_100)
    }

    @Test("A tick with nothing changed leaves everything alone")
    func quietTick() async {
        let bench = Bench()
        defer { bench.session.close() }
        await bench.session.open(configuration(instrumentChannel()), settings: .defaults)
        let runner = bench.session.runner

        bench.session.tick()
        await bench.session.reapplying?.value

        #expect(bench.session.runner === runner)
        #expect(bench.opened.count == 1)
    }

    @Test("A device that will not come back at the restart leaves the configuration waiting")
    func restartOntoAMissingDevice() async throws {
        let wanted = device("a")
        let bench = Bench(devices: [wanted])
        defer { bench.session.close() }
        let channel = instrumentChannel()
        await bench.session.open(configuration(channel), settings: settings(for: wanted))

        bench.devices = []
        await bench.session.applySettings(settings(for: wanted, sampleRate: 44_100))
        #expect(bench.engine.state == .deviceMissing("a"))
        #expect(bench.session.runner == nil)

        await bench.bringDevice(wanted)
        #expect(bench.session.runner?.plugin(channel: channel.id, effect: nil) != nil)
        #expect(bench.engine.runningSampleRate == 44_100)
    }

    // MARK: - Streams that will not stop

    @Test("A stream that will not stop keeps its plugins, on a lost device and at close")
    func stuckStreamKeepsPlugins() async throws {
        let bench = Bench()
        bench.prepare = { $0.stopsInTime = false }
        let channel = instrumentChannel()
        await bench.session.open(configuration(channel), settings: .defaults)
        weak let plugin = bench.session.runner?.plugin(channel: channel.id, effect: nil)

        bench.loseDevices()
        #expect(bench.engine.state == .deviceMissing(""))
        #expect(bench.session.runner == nil)
        #expect(plugin != nil)

        bench.session.close()
        #expect(plugin != nil)
    }

    @Test("A stream that will not stop at a restart keeps its plugins, and the device is tried again")
    func stuckStreamAtARestart() async throws {
        let wanted = device("a")
        let bench = Bench(devices: [wanted])
        defer { bench.session.close() }
        bench.prepare = { $0.stopsInTime = false }
        let channel = instrumentChannel()
        await bench.session.open(configuration(channel), settings: settings(for: wanted))
        weak let plugin = bench.session.runner?.plugin(channel: channel.id, effect: nil)

        await bench.session.applySettings(settings(for: wanted, sampleRate: 44_100))
        #expect(bench.engine.state == .deviceMissing("a"))
        #expect(bench.session.runner == nil)
        #expect(plugin != nil)

        bench.prepare = { _ in }
        bench.opened[0].stopsInTime = true
        await bench.bringDevice(wanted)
        #expect(bench.session.runner?.plugin(channel: channel.id, effect: nil) != nil)
        #expect(bench.engine.runningSampleRate == 44_100)
    }

    // MARK: - Settings

    @Test("A new sample rate rebuilds at that rate and keeps what plugins were doing")
    func newRateRebuilds() async throws {
        let wanted = device("a")
        let bench = Bench(devices: [wanted])
        defer { bench.session.close() }
        let channel = delayChannel()
        await bench.session.open(configuration(channel), settings: settings(for: wanted))
        try setWetDryMix(of: bench.session.runner?.plugin(channel: channel.id, effect: nil), to: 33)
        let oldRunner = bench.session.runner

        await bench.session.applySettings(settings(for: wanted, sampleRate: 44_100))

        let plugin = bench.session.runner?.plugin(channel: channel.id, effect: nil)
        #expect(bench.session.runner !== oldRunner)
        #expect(try runningRate(of: plugin) == 44_100)
        #expect(try wetDryMix(of: plugin) == 33)
        #expect(bench.opened.count == 2)
        #expect(bench.opened[0].stopCalls == 1)
    }

    @Test("A new device rebuilds on that device")
    func newDeviceRebuilds() async throws {
        let first = device("a")
        let second = device("b", outputs: sixteenOut)
        let bench = Bench(devices: [first, second])
        defer { bench.session.close() }
        let channel = instrumentChannel(out: out1415)
        await bench.session.open(configuration(channel), settings: settings(for: first))

        await bench.session.applySettings(settings(for: second))

        #expect(bench.engine.state == .running(second))
        #expect(bench.session.runner?.status[channel.id] == .ready)
        #expect(bench.opened.count == 2)
    }

    @Test("Whoever shows a plugin hears before a lost device takes it")
    func aLostDeviceWarnsBeforeThePluginsGo() async throws {
        let bench = Bench()
        defer { bench.session.close() }
        let channel = instrumentChannel()
        await bench.session.open(configuration(channel), settings: .defaults)
        var plugins: [HostedPlugin?] = []
        bench.session.willReleasePlugins = {
            plugins.append(bench.session.runner?.plugin(channel: channel.id, effect: nil))
        }

        bench.loseDevices()

        #expect(plugins.count == 1)
        #expect(plugins.first.flatMap { $0 } != nil)
        #expect(bench.session.runner == nil)
    }

    @Test("Whoever shows a plugin hears before a new device takes it")
    func aNewDeviceWarnsBeforeThePluginsGo() async throws {
        let first = device("a")
        let second = device("b")
        let bench = Bench(devices: [first, second])
        defer { bench.session.close() }
        let channel = instrumentChannel()
        await bench.session.open(configuration(channel), settings: settings(for: first))
        let old = try #require(bench.session.runner?.plugin(channel: channel.id, effect: nil))
        var told: [Bool] = []
        bench.session.willReleasePlugins = {
            told.append(bench.session.runner?.plugin(channel: channel.id, effect: nil) === old)
        }

        await bench.session.applySettings(settings(for: second))

        #expect(told == [true])
        #expect(bench.session.runner?.plugin(channel: channel.id, effect: nil) !== old)
    }

    @Test("Closing tells whoever shows a plugin too")
    func closingWarnsBeforeThePluginsGo() async throws {
        let bench = Bench()
        let channel = instrumentChannel()
        await bench.session.open(configuration(channel), settings: .defaults)
        var calls = 0
        bench.session.willReleasePlugins = { calls += 1 }

        bench.session.close()

        #expect(calls == 1)
    }

    @Test("A new buffer size restarts the device and keeps the plugins")
    func newBufferKeepsTheRunner() async {
        let wanted = device("a")
        let bench = Bench(devices: [wanted])
        defer { bench.session.close() }
        await bench.session.open(configuration(instrumentChannel()), settings: settings(for: wanted))
        let runner = bench.session.runner

        await bench.session.applySettings(settings(for: wanted, bufferFrames: 256))

        #expect(bench.engine.runningBufferFrames == 256)
        #expect(bench.session.runner === runner)
        #expect(bench.opened.count == 2)
    }

    @Test("A sample rate means nothing to a device the engine only follows")
    func rateIsIgnoredWithoutAPickedDevice() async {
        let bench = Bench()
        defer { bench.session.close() }
        await bench.session.open(configuration(instrumentChannel()), settings: settings(for: nil))
        let runner = bench.session.runner

        await bench.session.applySettings(settings(for: nil, sampleRate: 44_100, bufferFrames: 256))

        #expect(bench.opened.count == 1)
        #expect(bench.session.runner === runner)
    }

    @Test("Settings with no configuration open start nothing")
    func settingsBeforeOpen() async {
        let wanted = device("a")
        let bench = Bench(devices: [wanted])
        defer { bench.session.close() }

        await bench.session.applySettings(settings(for: wanted))

        #expect(bench.engine.state == .stopped)
        #expect(bench.opened.isEmpty)
    }

    @Test("A new clock source goes to the router, without touching audio")
    func clockSource() async {
        let bench = Bench()
        defer { bench.session.close() }
        await bench.session.open(configuration(instrumentChannel()), settings: .defaults)
        let runner = bench.session.runner
        var withClock = AppSettings.defaults
        withClock.clockSource = "Keys"

        await bench.session.applySettings(withClock)
        let interval = 60.0 / 124 / 24
        for tick in 1...48 { bench.session.router.handle(.clock, fromSource: "Keys", at: Double(tick) * interval) }
        bench.session.router.refreshClock(at: 48 * interval)

        #expect(bench.session.router.clockRunning)
        #expect(bench.session.runner === runner)
        #expect(bench.opened.count == 1)
    }

    // MARK: - Collecting

    @Test("The timer collects what left the graph")
    func timerCollectsRetired() async throws {
        let bench = Bench()
        defer { bench.session.close() }
        let channel = instrumentChannel()
        await bench.session.open(configuration(channel), settings: .defaults)
        _ = bench.render()
        weak let plugin = bench.session.runner?.plugin(channel: channel.id, effect: nil)

        await bench.session.update(configuration())
        _ = bench.render()
        #expect(plugin != nil, "only collecting releases it")

        let deadline = ContinuousClock.now + .seconds(3)
        while plugin != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(plugin == nil)
    }

    // MARK: - Closing

    @Test("Closing stops audio, then the plugins, then the router")
    func closeRunsInOrder() async throws {
        let bench = Bench()
        let channel = instrumentChannel()
        await bench.session.open(configuration(channel), settings: .defaults)
        let runner = try #require(bench.session.runner)
        let stream = bench.opened[0]
        weak let plugin = runner.plugin(channel: channel.id, effect: nil)
        var order: [String] = []
        stream.onStop = {
            MainActor.assumeIsolated {
                order.append("audio")
                #expect(plugin != nil)
                #expect(!bench.session.router.isClosed)
            }
        }
        runner.seams.installGraph = { engine, strips, count in
            order.append("plugins")
            #expect(stream.stopCalls == 1)
            #expect(strips == nil && count == 0)
            #expect(!bench.session.router.isClosed)
            return pr_engine_install_graph(engine, strips, count)
        }

        bench.session.close()

        #expect(order == ["audio", "plugins"])
        #expect(bench.session.router.isClosed)
        #expect(bench.session.runner == nil)
        #expect(plugin == nil)
        #expect(bench.engine.state == .stopped)
    }

    @Test("Closing with nothing open closes the router")
    func closeWithNothingOpen() {
        let bench = Bench()
        bench.session.close()
        #expect(bench.session.router.isClosed)
        #expect(bench.opened.isEmpty)
    }

    @Test("Closing twice does nothing more")
    func closeTwice() async {
        let bench = Bench()
        await bench.session.open(configuration(instrumentChannel()), settings: .defaults)
        bench.session.close()
        bench.session.close()
        #expect(bench.opened[0].stopCalls == 1)
    }

    @Test("Nothing comes back after closing")
    func nothingAfterClose() async {
        let bench = Bench()
        let channel = instrumentChannel()
        await bench.session.open(configuration(channel), settings: .defaults)
        bench.session.close()

        await bench.session.update(configuration(channel))
        await bench.session.reload(configuration(channel), settings: .defaults)
        await bench.session.open(configuration(channel), settings: .defaults)
        await bench.session.applySettings(settings(for: device("a")))
        await bench.bringDevice(device("a"))
        bench.session.tick()

        #expect(bench.opened.count == 1)
        #expect(bench.session.runner == nil)
        #expect(bench.engine.state == .stopped)
    }

    @Test("Closing during a load ends the wait for it")
    func closeDuringALoad() async throws {
        let bench = Bench()
        await bench.session.open(configuration(), settings: .defaults)
        let runner = try #require(bench.session.runner)
        let gate = LoadGate()
        runner.seams.load = { id in
            await gate.pass()
            return try await HostedPlugin.load(id)
        }
        let edit = Task { await bench.session.update(configuration(instrumentChannel())) }
        while runner.pendingLoads == 0 { await Task.yield() }

        bench.session.close()
        await edit.value
        await gate.open()
        while runner.pendingLoads > 0 { await Task.yield() }

        #expect(bench.session.runner == nil)
    }
}
