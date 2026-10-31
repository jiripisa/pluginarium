import AudioToolbox
import CRenderCore
import Foundation
import Observation
import PluginariumCore
import os

private let logger = Logger(subsystem: "io.jp4.pluginarium", category: "runner")

private let midiSlotCount: Int32 = 64
private let failedInstall = UInt64.max

public enum ChannelStatus: Equatable, Sendable {
    case loading
    case ready
    case pluginMissing
    case loadFailed(String)
    /// Carries the channel label, such as "Out 15–16".
    case routingUnavailable(String)
}

/// Turns configurations into plugins playing through the render core, while audio may be running.
///
/// Plugins are kept by channel and effect ID. An edit loads what is new, retires what is gone and
/// reinstalls the graph, so what keeps playing is never reloaded.
///
/// A unit lives until no render can reach it: a plugin that leaves the graph waits in a retire queue
/// until the render core has taken the generation that replaced it. The runner does not own the
/// engine, and `shutDown` must run before the engine is destroyed.
@MainActor
@Observable
public final class ConfigurationRunner {

    /// What the runner calls outside itself, so a test can hold a load open or fail an install.
    struct Seams {
        var load: @Sendable (PluginID) async throws -> HostedPlugin = { try await HostedPlugin.load($0) }
        var prepare: @Sendable (HostedPlugin, PluginSlot, Double, UInt32) async throws -> Void = ConfigurationRunner.prepare
        var installCallbacks: @MainActor (HostedPlugin, OpaquePointer) throws -> Void = ConfigurationRunner.installCallbacks
        var installGraph: @MainActor (OpaquePointer, UnsafePointer<PRStrip>?, UInt32) -> UInt64 = { pr_engine_install_graph($0, $1, $2) }
    }

    /// One plugin on its way to one channel or effect. Each runs at most once at a time, so a newer
    /// configuration that wants the same plugin there waits for it instead of loading it again.
    private struct Load: Hashable {
        var node: UUID
        var plugin: PluginID
    }

    private struct RetiredPlugin {
        var plugin: HostedPlugin
        var generation: UInt64
    }

    public private(set) var status: [UUID: ChannelStatus] = [:]

    /// Called during `apply` once `midiSlot` answers for the new configuration. A plugin may still
    /// take seconds to load, and `apply` returns only after that.
    public var onMIDISlotsAssigned: (() -> Void)?

    var seams = Seams()
    var pendingLoads: Int { loads.count }

    private let engine: OpaquePointer
    private let sampleRate: Double
    private let maxFrames: UInt32
    private let cache: CapabilityCache
    private let builder: GraphBuilder

    /// The newest configuration's channels, and its slots by channel or effect ID.
    private var channels: [Channel] = []
    private var wanted: [UUID: PluginSlot] = [:]

    private var hosted: [UUID: HostedPlugin] = [:]
    private var loads: Set<Load> = []
    /// Calls to `apply` waiting for the newest configuration to settle.
    private var settling: [CheckedContinuation<Void, Never>] = []
    private var failures: [UUID: any Error] = [:]
    private var midiSlots: [UUID: Int32] = [:]

    /// What the render core was last given.
    private var installed: [GraphStrip] = []
    /// Left `hosted` but may still be in the installed graph, so no generation covers them yet.
    private var outgoing: [HostedPlugin] = []
    private var retired: [RetiredPlugin] = []
    /// Channels the last install would have changed, had it not run out of memory.
    private var notInstalled: Set<UUID> = []
    private var isShutDown = false

    public init(engine: OpaquePointer, sampleRate: Double, maxFrames: UInt32, deviceInputs: Int, deviceOutputs: Int, cache: CapabilityCache) {
        self.engine = engine
        self.sampleRate = sampleRate
        self.maxFrames = maxFrames
        self.cache = cache
        builder = GraphBuilder(deviceInputs: deviceInputs, deviceOutputs: deviceOutputs)
    }

    /// Makes `configuration` the one that plays, and returns once its plugins have settled. A call
    /// made during an earlier one replaces it: the newest configuration wins, and both return once
    /// that one has settled, so a discarded plugin holds up neither. A plugin that failed before
    /// gets another try.
    public func apply(_ configuration: Configuration) async {
        guard !isShutDown else { return }
        collectRetired()

        channels = configuration.channels
        wanted = [:]
        for channel in channels {
            wanted[channel.id] = channel.slot
            for effect in channel.effects.joined() { wanted[effect.id] = effect.slot }
        }
        for (node, plugin) in hosted where wanted[node]?.plugin != plugin.id {
            hosted[node] = nil
            outgoing.append(plugin)
        }
        failures = [:]
        for (node, slot) in wanted where hosted[node] == nil {
            startLoad(Load(node: node, plugin: slot.plugin))
        }
        assignMIDISlots()
        installGraph()
        updateStatus()
        onMIDISlotsAssigned?()

        resumeSettled()
        if !isSettled {
            await withCheckedContinuation { settling.append($0) }
        }
        collectRetired()
    }

    public func plugin(channel: UUID, effect: UUID?) -> HostedPlugin? {
        guard let owner = channels.first(where: { $0.id == channel }) else { return nil }
        guard let effect else { return hosted[channel] }
        return owner.effects.joined().contains { $0.id == effect } ? hosted[effect] : nil
    }

    /// Why the effect is not playing, for the owner. Nil for an effect that runs or is on its way.
    public func failure(effect: UUID) -> String? {
        guard let failure = failures[effect], let slot = wanted[effect] else { return nil }
        return Self.message(for: failure, in: slot)
    }

    public func capabilities(channel: UUID) -> PluginCapabilities? {
        wanted[channel].flatMap { cache[$0.plugin] }
    }

    /// `configuration` with each slot holding the current state of its running plugin. A slot
    /// whose plugin does not run keeps the state it has.
    public func capturingState(of configuration: Configuration) -> Configuration {
        var result = configuration
        for channel in result.channels.indices {
            capture(&result.channels[channel].slot, node: result.channels[channel].id)
            for row in result.channels[channel].effects.indices {
                for effect in result.channels[channel].effects[row].indices {
                    capture(&result.channels[channel].effects[row][effect].slot, node: result.channels[channel].effects[row][effect].id)
                }
            }
        }
        return result
    }

    /// The channel's slot in 0...63, stable while the channel exists. None when the channel does
    /// not accept MIDI or every slot is taken.
    public func midiSlot(channel: UUID) -> Int32? {
        midiSlots[channel]
    }

    /// The strip of `channel` in the installed graph, which `pr_engine_read_meters` takes. A channel
    /// that is not in the graph has none, and the strips after it shift down.
    public func meterStrip(channel: UUID) -> UInt32? {
        installed.firstIndex { $0.channel == channel }.map { UInt32($0) }
    }

    /// Releases the retired plugins no render can reach and frees the graphs the render thread has
    /// finished with.
    public func collectRetired() {
        guard !isShutDown else { return }
        retired.removeAll { pr_engine_is_generation_taken(engine, $0.generation) }
        pr_engine_collect_garbage(engine)
    }

    /// For audio that would not stop: a render may still be inside any plugin here, so `shutDown`
    /// cannot run. The runner does nothing after this and holds on to every plugin it has, so whoever
    /// calls this has to keep it for as long as that render can last.
    public func abandon() {
        guard !isShutDown else { return }
        isShutDown = true
        wanted = [:]
        resumeSettled()
    }

    /// Call after audio has stopped and before destroying the engine. Installs an empty graph and
    /// releases every plugin. The runner does nothing after this, and a load still under way is
    /// discarded when it finishes.
    public func shutDown() {
        guard !isShutDown else { return }
        if seams.installGraph(engine, nil, 0) == failedInstall {
            // The old graph stays, but with audio stopped no render reaches its units.
            logger.error("Not enough memory for the empty graph")
        }
        isShutDown = true
        channels = []
        wanted = [:]
        hosted = [:]
        failures = [:]
        midiSlots = [:]
        installed = []
        outgoing = []
        retired = []
        notInstalled = []
        status = [:]
        pr_engine_collect_garbage(engine)
        resumeSettled()
    }

    // MARK: - Loading

    private func isWanted(_ load: Load) -> Bool {
        wanted[load.node]?.plugin == load.plugin
    }

    private var isSettled: Bool {
        !loads.contains(where: isWanted)
    }

    private func resumeSettled() {
        guard isSettled else { return }
        settling.forEach { $0.resume() }
        settling = []
    }

    private func startLoad(_ load: Load) {
        guard loads.insert(load).inserted else { return }
        Task {
            await perform(load)
            loads.remove(load)
            installGraph()
            updateStatus()
            resumeSettled()
        }
    }

    /// Host a plugin only if the newest configuration still wants it when it is ready. Otherwise it
    /// goes with this call: it never reached a graph, so nothing else can hold its unit.
    private func perform(_ load: Load) async {
        do {
            let plugin = try await seams.load(load.plugin)
            if cache[load.plugin] == nil {
                cache[load.plugin] = .derive(auType: load.plugin.type, inputBusNames: plugin.inputBusNames)
            }
            guard let slot = wanted[load.node], slot.plugin == load.plugin else { return }
            try await seams.prepare(plugin, slot, sampleRate, maxFrames)
            guard isWanted(load) else { return }
            try seams.installCallbacks(plugin, engine)
            hosted[load.node] = plugin
        } catch {
            if isWanted(load) { failures[load.node] = error }
        }
    }

    /// Nonisolated because initializing a unit can take seconds, which the main actor must not wait for.
    /// A slot that names a preset but holds no state names a factory preset. One the plugin no longer
    /// has leaves it on its default sound, which is no reason to keep it from playing.
    private nonisolated static func prepare(_ plugin: HostedPlugin, _ slot: PluginSlot, _ sampleRate: Double, _ maxFrames: UInt32) async throws {
        try plugin.configure(sampleRate: sampleRate, maxFrames: maxFrames)
        if let state = slot.state {
            try plugin.restore(state)
        } else if let preset = slot.presetName {
            do {
                try plugin.selectFactoryPreset(preset)
            } catch {
                let name = slot.displayName
                logger.error("Cannot select \(preset, privacy: .public) on \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func installCallbacks(_ plugin: HostedPlugin, _ engine: OpaquePointer) throws {
        var status = pr_install_input_callbacks(plugin.audioUnit, engine)
        if status != noErr { throw HostedPluginError.osStatus(status, "Input callbacks") }
        status = pr_install_host_callbacks(plugin.audioUnit, engine)
        if status != noErr { throw HostedPluginError.osStatus(status, "Host callbacks") }
    }

    // MARK: - Graph

    private func installGraph() {
        guard !isShutDown else { return }
        let strips = builder.strips(for: channels, units: hosted.mapValues(GraphUnit.init), midiSlots: midiSlots)
        guard strips != installed || !outgoing.isEmpty else {
            notInstalled = []
            return
        }
        let generation = GraphBuilder.withCStrips(strips) { seams.installGraph(engine, $0.baseAddress, UInt32($0.count)) }
        guard generation != failedInstall else {
            logger.error("Not enough memory for a new graph")
            let before = Dictionary(installed.map { ($0.channel, $0) }, uniquingKeysWith: { first, _ in first })
            let after = Dictionary(strips.map { ($0.channel, $0) }, uniquingKeysWith: { first, _ in first })
            notInstalled = Set(channels.map(\.id).filter { before[$0] != after[$0] })
            return
        }
        installed = strips
        notInstalled = []
        retired += outgoing.map { RetiredPlugin(plugin: $0, generation: generation) }
        outgoing = []
    }

    private func assignMIDISlots() {
        // A plugin's type alone decides this, so it is known before the plugin has loaded.
        let accepting = channels.filter { PluginCapabilities.derive(auType: $0.slot.plugin.type, inputBusNames: []).acceptsMIDI }
        let keep = Set(accepting.map(\.id))
        midiSlots = midiSlots.filter { keep.contains($0.key) }
        var free = (0..<midiSlotCount).filter { !midiSlots.values.contains($0) }[...]
        for channel in accepting where midiSlots[channel.id] == nil {
            guard let slot = free.popFirst() else { break }
            midiSlots[channel.id] = slot
        }
    }

    // MARK: - Status and state

    private func updateStatus() {
        guard !isShutDown else { return }
        status = Dictionary(channels.map { ($0.id, status(of: $0)) }, uniquingKeysWith: { first, _ in first })
    }

    private func status(of channel: Channel) -> ChannelStatus {
        if let failure = failures[channel.id] {
            if case HostedPluginError.notFound = failure { return .pluginMissing }
            return .loadFailed(failure.localizedDescription)
        }
        if hosted[channel.id] == nil { return .loading }
        if notInstalled.contains(channel.id) { return .loadFailed("Not enough memory") }
        let effects = channel.effects.joined()
        if let (effect, failure) = effects.lazy.compactMap({ effect in self.failures[effect.id].map { (effect, $0) } }).first {
            return .loadFailed(Self.message(for: failure, in: effect.slot))
        }
        if effects.contains(where: { hosted[$0.id] == nil }) { return .loading }
        return builder.missingRoute(of: channel).map(ChannelStatus.routingUnavailable) ?? .ready
    }

    /// For the owner, so a plugin that is gone is named by its display name, not its codes.
    private static func message(for failure: any Error, in slot: PluginSlot) -> String {
        if case HostedPluginError.notFound = failure { return "\(slot.displayName) is not installed on this Mac" }
        return failure.localizedDescription
    }

    private func capture(_ slot: inout PluginSlot, node: UUID) {
        guard let plugin = hosted[node], plugin.id == slot.plugin else { return }
        do {
            slot.state = try plugin.fullState()
        } catch {
            let name = slot.displayName
            logger.error("Cannot capture \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
