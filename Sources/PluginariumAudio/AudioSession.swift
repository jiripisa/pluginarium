import Foundation
import Observation
import PluginariumCore
import os

private let logger = Logger(subsystem: "io.jp4.pluginarium", category: "session")

private let tickInterval = Duration.seconds(1)

/// Owns what plays a configuration: one engine, one router, and a runner for as long as the device
/// lets one run. The configuration wanted outlives any runner, so it comes back when a device does.
///
/// A runner is only good for the device values it was built from, and those come from the running
/// device, never from `AppSettings`. Whatever changes them goes through the one order that is safe:
/// stop audio, shut the runner down, start again, build a new runner and apply. Audio has to be
/// stopped because `shutDown` releases what a render could be inside. When a stream will not stop
/// the plugins leak instead, as `AudioEngine` says.
///
/// Creating this opens a CoreMIDI client and listens to the system's device list, but no device
/// starts until a configuration opens. Call `close` before letting go of it.
@MainActor
@Observable
public final class AudioSession {

    /// What a runner is built from.
    private struct RunningValues: Equatable {
        var sampleRate: Double
        var deviceInputs: Int
        var deviceOutputs: Int
    }

    public private(set) var runner: ConfigurationRunner?
    /// Declared before `engine`, since both point at the render core the engine owns.
    public private(set) var router: MIDIRouter
    public let engine: AudioEngine

    /// Why audio did not start, the last time it was asked to, until it runs. The engine tries again
    /// at each device change. A device that is merely gone is not a failure here: `engine.state`
    /// reports that one.
    public private(set) var startFailure: String?

    /// The apply a device change started, since the engine's callback cannot wait for it.
    @ObservationIgnored var reapplying: Task<Void, Never>?

    @ObservationIgnored private let cache: CapabilityCache
    /// What should play. It takes over the state of plugins that have gone with their runner.
    @ObservationIgnored private var wanted: Configuration?
    @ObservationIgnored private var settings: AppSettings?
    @ObservationIgnored private var runnerValues: RunningValues?
    /// Set while this object stops or starts the engine, so it does not answer itself.
    @ObservationIgnored private var isSwitching = false
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public init(cache: CapabilityCache, engine: AudioEngine = AudioEngine()) {
        self.cache = cache
        self.engine = engine
        router = MIDIRouter(engine: engine.renderEngine)
        engine.onDeviceChange = { [weak self] in self?.followDevice() }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tickInterval)
                guard let self else { return }
                tick()
            }
        }
    }

    deinit {
        ticker?.cancel()
    }

    /// Plays `configuration`, starting the engine if it is not running. With no device there yet, it
    /// starts playing when one comes.
    public func open(_ configuration: Configuration, settings: AppSettings) async {
        guard !isClosed else { return }
        wanted = configuration
        take(settings)
        startIfNotRunning(settings)
        await play()
    }

    /// Plays an edit of the configuration, leaving what stays in it alone.
    public func update(_ configuration: Configuration) async {
        guard !isClosed else { return }
        wanted = wanted.map(configuration.keepingState(of:)) ?? configuration
        await apply()
    }

    /// Plays a saved `configuration` from the state it was saved with. Everything playing goes first,
    /// because `apply` never restores state on a plugin that runs.
    public func reload(_ configuration: Configuration, settings: AppSettings) async {
        guard !isClosed else { return }
        wanted = configuration
        take(settings)
        await runner?.apply(Configuration(name: ""))
        startIfNotRunning(settings)
        await play()
    }

    /// A new device or sample rate restarts audio and rebuilds. A new buffer size restarts the device
    /// under the same plugins, which take blocks up to `AudioEngine.maxFrames` either way. With no
    /// device picked, sample rate and buffer size ask nothing of the device, so nothing restarts.
    public func applySettings(_ settings: AppSettings) async {
        guard !isClosed else { return }
        let before = self.settings
        take(settings)
        guard wanted != nil else { return }

        let asked = before.flatMap(chosenSettings)
        let asks = chosenSettings(in: settings)
        if before?.audioDeviceUID != settings.audioDeviceUID || asked?.sampleRate != asks?.sampleRate {
            restart(settings)
            await apply()
        } else if asked?.bufferFrames != asks?.bufferFrames {
            start(settings)
            await play()
        }
    }

    /// `configuration` with the state of its plugins, whether they run or left with the device.
    public func capturingState(of configuration: Configuration) -> Configuration {
        let held = wanted.map(configuration.keepingState(of:)) ?? configuration
        return runner?.capturingState(of: held) ?? held
    }

    /// Takes everything down for quitting: audio first, then the plugins, then the router. The engine
    /// goes last, with this object. Nothing runs after this.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        ticker?.cancel()
        engine.onDeviceChange = nil
        engine.stop()
        wanted = nil
        releaseRunner()
        router.close()
    }

    /// What the timer does each time. A device can restart at another rate without `state` changing,
    /// so this also looks at the running values.
    func tick() {
        runner?.collectRetired()
        followDevice()
    }

    // MARK: - Private

    private var runningValues: RunningValues? {
        guard case .running(let device) = engine.state, let sampleRate = engine.runningSampleRate else { return nil }
        return RunningValues(sampleRate: sampleRate, deviceInputs: device.inputChannels.count, deviceOutputs: device.outputChannels.count)
    }

    private func take(_ settings: AppSettings) {
        self.settings = settings
        router.setClockSource(settings.clockSource)
    }

    private func followDevice() {
        guard adoptRunningValues() else { return }
        reapplying = Task { [weak self] in await self?.apply() }
    }

    private func play() async {
        adoptRunningValues()
        await apply()
    }

    private func apply() async {
        guard let runner, let wanted else { return }
        await runner.apply(wanted)
    }

    /// Brings the runner in line with what the engine runs. True when a new runner waits to be
    /// applied to.
    @discardableResult
    private func adoptRunningValues() -> Bool {
        guard !isSwitching else { return false }
        guard let values = runningValues else {
            releaseRunner()
            return false
        }
        if startFailure != nil { startFailure = nil }
        if runner == nil { return makeRunner(values) }
        guard values != runnerValues, let settings else { return false }
        restart(settings)
        return runner != nil
    }

    /// The one safe order. The runner has to be gone before the engine starts on anything new, and
    /// the stop forgets the device, so this works as well for a device that is not there.
    private func restart(_ settings: AppSettings) {
        withoutFollowing {
            engine.stop()
            releaseRunner()
        }
        start(settings)
        if let values = runningValues { makeRunner(values) }
    }

    private func startIfNotRunning(_ settings: AppSettings) {
        if case .running = engine.state { return }
        start(settings)
    }

    private func start(_ settings: AppSettings) {
        withoutFollowing {
            do {
                try engine.start(settings: settings)
                startFailure = nil
            } catch {
                logger.error("Cannot start audio: \(error.localizedDescription, privacy: .public)")
                startFailure = error.localizedDescription
            }
        }
    }

    private func withoutFollowing(_ change: () -> Void) {
        isSwitching = true
        defer { isSwitching = false }
        change()
    }

    @discardableResult
    private func makeRunner(_ values: RunningValues) -> Bool {
        guard wanted != nil else { return false }
        let runner = ConfigurationRunner(
            engine: engine.renderEngine, sampleRate: values.sampleRate, maxFrames: AudioEngine.maxFrames,
            deviceInputs: values.deviceInputs, deviceOutputs: values.deviceOutputs, cache: cache
        )
        runner.onMIDISlotsAssigned = { [weak self] in self?.refreshRoutes() }
        self.runner = runner
        runnerValues = values
        return true
    }

    /// Lets the runner go once audio has stopped. What its plugins were doing stays with `wanted`.
    ///
    /// A stream that would not stop can still be inside any plugin, even inside a call that reads its
    /// state, so then nothing is read and the runner is kept for good.
    private func releaseRunner() {
        guard let runner else { return }
        self.runner = nil
        runnerValues = nil
        router.setRoutes([])
        if engine.canRender {
            runner.abandon()
            _ = Unmanaged.passRetained(runner)
        } else {
            wanted = wanted.map(runner.capturingState)
            runner.shutDown()
        }
    }

    private func refreshRoutes() {
        guard let runner, let wanted else { return }
        router.setRoutes(
            wanted.channels.compactMap { channel in
                guard let route = channel.midiIn, let slot = runner.midiSlot(channel: channel.id) else { return nil }
                return MIDIRouteTarget(route: route, slot: slot)
            })
    }
}

private extension Configuration {

    /// A copy of this configuration whose plugins keep the state `older` has for them. An edit does
    /// not carry state, which lives in the plugin and comes out with `capturingState`.
    func keepingState(of older: Configuration) -> Configuration {
        let held = older.slots
        func keep(_ slot: inout PluginSlot, node: UUID) {
            guard let old = held[node], old.plugin == slot.plugin, let state = old.state else { return }
            slot.state = state
        }
        var result = self
        for channel in result.channels.indices {
            keep(&result.channels[channel].slot, node: result.channels[channel].id)
            for row in result.channels[channel].effects.indices {
                for effect in result.channels[channel].effects[row].indices {
                    keep(&result.channels[channel].effects[row][effect].slot, node: result.channels[channel].effects[row][effect].id)
                }
            }
        }
        return result
    }

    /// By channel or effect ID.
    var slots: [UUID: PluginSlot] {
        var slots: [UUID: PluginSlot] = [:]
        for channel in channels {
            slots[channel.id] = channel.slot
            for effect in channel.effects.joined() { slots[effect.id] = effect.slot }
        }
        return slots
    }
}
