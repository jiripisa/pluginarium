import AudioToolbox
import CRenderCore
import Foundation
import PluginariumCore
import PluginariumTestUnits
import Testing
@testable import PluginariumAudio

private let instrumentID = PluginID(type: "aumu", subtype: "PlIn", manufacturer: "Plug")
private let voiceID = PluginID(type: "aumf", subtype: "PlVo", manufacturer: "Plug")
private let tempoID = PluginID(type: "aumu", subtype: "PlTp", manufacturer: "Plug")
private let gainID = PluginID(type: "aufx", subtype: "PlFx", manufacturer: "Plug")
private let sidechainID = PluginID(type: "aufx", subtype: "PlSc", manufacturer: "Plug")
private let monoID = PluginID(type: "aufx", subtype: "PlMo", manufacturer: "Plug")
private let brokenID = PluginID(type: "aufx", subtype: "PlBd", manufacturer: "Plug")
private let unknownInstrumentID = PluginID(type: "aumu", subtype: "None", manufacturer: "Plug")
private let unknownEffectID = PluginID(type: "aufx", subtype: "None", manufacturer: "Plug")
private let delayID = PluginID(type: "aufx", subtype: "dely", manufacturer: "appl")
private let reverbID = PluginID(type: "aufx", subtype: "mrev", manufacturer: "appl")

private let out01 = AudioChannels.stereo(left: 0, right: 1)
private let out23 = AudioChannels.stereo(left: 2, right: 3)
private let out45 = AudioChannels.stereo(left: 4, right: 5)
private let in01 = AudioChannels.stereo(left: 0, right: 1)

private func slot(_ plugin: PluginID, state: Data? = nil) -> PluginSlot {
    PluginSlot(plugin: plugin, displayName: plugin.subtype, state: state)
}

private func instrumentChannel(
    _ plugin: PluginID = instrumentID, state: Data? = nil, audioIn: AudioChannels? = nil, out: AudioChannels = out01,
    effects: [[InsertEffect]] = []
) -> Channel {
    Channel(kind: .instrument, slot: slot(plugin, state: state), audioIn: audioIn, audioOut: out, effects: effects)
}

private func effectChannel(
    _ plugin: PluginID = gainID, state: Data? = nil, audioIn: AudioChannels? = in01, sidechainIn: AudioChannels? = nil,
    out: AudioChannels = out01, effects: [[InsertEffect]] = []
) -> Channel {
    Channel(kind: .effect, slot: slot(plugin, state: state), audioIn: audioIn, sidechainIn: sidechainIn, audioOut: out, effects: effects)
}

private func insert(_ plugin: PluginID = gainID, sidechainIn: AudioChannels? = nil) -> InsertEffect {
    InsertEffect(slot: slot(plugin), sidechainIn: sidechainIn)
}

private func configuration(_ channels: Channel...) -> Configuration {
    Configuration(name: "Test", channels: channels)
}

private func makeCache() -> CapabilityCache {
    CapabilityCache(file: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json"))
}

/// Runs `body` with a runner on a new engine, and shuts it down before the engine goes.
@MainActor
private func withRunner(
    deviceInputs: Int = 8, deviceOutputs: Int = 8, cache: CapabilityCache = makeCache(),
    _ body: @MainActor (ConfigurationRunner, Rig) async throws -> Void
) async throws {
    registerTestUnits()
    let rig = Rig()
    let runner = ConfigurationRunner(
        engine: rig.engine, sampleRate: sampleRate, maxFrames: unitMaxFrames,
        deviceInputs: deviceInputs, deviceOutputs: deviceOutputs, cache: cache
    )
    defer { withExtendedLifetime(rig) { runner.shutDown() } }
    try await body(runner, rig)
}

@MainActor
private func press(_ channel: Channel, _ runner: ConfigurationRunner, _ rig: Rig) throws {
    rig.press(slot: try #require(runner.midiSlot(channel: channel.id)))
}

private func failureMessage(_ status: ChannelStatus?) -> String? {
    if case .loadFailed(let message) = status { return message }
    return nil
}

/// Gives up after a few seconds, so a load that never ends fails rather than hangs.
@MainActor
private func finishLoads(_ runner: ConfigurationRunner) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while runner.pendingLoads > 0, ContinuousClock.now < deadline { await Task.yield() }
    #expect(runner.pendingLoads == 0)
}

/// Holds plugin loads open until a test lets them finish, and remembers each one.
private actor LoadGate {
    private struct Loaded {
        weak var plugin: HostedPlugin?
    }

    private(set) var requested: [PluginID] = []
    private var finished: [Loaded] = []
    private var opened: Set<PluginID> = []
    private var waiting: [(id: PluginID, continuation: CheckedContinuation<Void, Never>)] = []

    var alive: [HostedPlugin] { finished.compactMap(\.plugin) }

    func pass(_ id: PluginID) async {
        requested.append(id)
        if !opened.contains(id) {
            await withCheckedContinuation { waiting.append((id, $0)) }
        }
    }

    func load(_ id: PluginID) async throws -> HostedPlugin {
        await pass(id)
        let plugin = try await HostedPlugin.load(id)
        finished.append(Loaded(plugin: plugin))
        return plugin
    }

    func open(_ id: PluginID) {
        opened.insert(id)
        for entry in waiting where entry.id == id { entry.continuation.resume() }
        waiting.removeAll { $0.id == id }
    }

    /// Gives up after a few seconds, so a test that went wrong fails on its next check.
    func waitUntilRequested(_ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while requested.count < count, ContinuousClock.now < deadline { await Task.yield() }
    }
}

@MainActor
private func gated(_ runner: ConfigurationRunner) -> LoadGate {
    let gate = LoadGate()
    runner.seams.load = { try await gate.load($0) }
    return gate
}

@Suite("Configuration runner")
@MainActor
struct RunnerTests {

    // MARK: - Faults stay on their channel

    @Test func missingPluginDoesNotStopOthers() async throws {
        try await withRunner { runner, rig in
            let good = instrumentChannel()
            let missing = instrumentChannel(unknownInstrumentID, out: out23)
            await runner.apply(configuration(good, missing))
            #expect(runner.status == [good.id: .ready, missing.id: .pluginMissing])
            try press(good, runner, rig)
            let output = rig.render()
            expectLevel(output[0], 0.25)
            expectLevel(output[2], 0)
        }
    }

    @Test func failingPluginStaysOnItsChannel() async throws {
        try await withRunner { runner, rig in
            let good = instrumentChannel()
            let bad = effectChannel(brokenID, out: out23)
            await runner.apply(configuration(good, bad))
            #expect(runner.status[good.id] == .ready)
            let message = try #require(failureMessage(runner.status[bad.id]))
            #expect(message.contains("AudioUnitInitialize"))
            try press(good, runner, rig)
            expectLevel(rig.render()[0], 0.25)
        }
    }

    @Test func outputBeyondDeviceIsFlagged() async throws {
        try await withRunner(deviceOutputs: 2) { runner, rig in
            let beyond = instrumentChannel(out: .stereo(left: 14, right: 15))
            let good = instrumentChannel()
            await runner.apply(configuration(beyond, good))
            #expect(runner.status == [beyond.id: .routingUnavailable("Out 15–16"), good.id: .ready])
            // Left out of the graph, so the channel that plays is the only strip.
            try press(good, runner, rig)
            expectLevel(rig.render()[0], 0.25)
            #expect(rig.meters(strip: 0).left == 0.25)
            #expect(rig.meters(strip: 1).left == 0)
        }
    }

    @Test func outputPartlyBeyondDeviceIsLeftOut() async throws {
        try await withRunner(deviceOutputs: 3) { runner, rig in
            let partly = instrumentChannel(out: out23)
            await runner.apply(configuration(partly))
            #expect(runner.status == [partly.id: .routingUnavailable("Out 3–4")])
            try press(partly, runner, rig)
            expectLevel(rig.render()[2], 0)
        }
    }

    @Test func inputBeyondDeviceIsFlagged() async throws {
        try await withRunner(deviceInputs: 0) { runner, rig in
            let standalone = effectChannel(audioIn: .stereo(left: 8, right: 9))
            await runner.apply(configuration(standalone))
            #expect(runner.status == [standalone.id: .routingUnavailable("In 9–10")])
            expectLevel(rig.render(input: constantInput([0: 0.8, 1: 0.8]))[0], 0)
        }
    }

    @Test func missingMonoInputIsNamed() async throws {
        try await withRunner(deviceInputs: 0) { runner, _ in
            let standalone = effectChannel(audioIn: .mono(0))
            await runner.apply(configuration(standalone))
            #expect(runner.status == [standalone.id: .routingUnavailable("In 1")])
        }
    }

    @Test func missingSidechainTurnsOffOnlyThatInput() async throws {
        try await withRunner(deviceInputs: 2) { runner, rig in
            let standalone = effectChannel(sidechainID, sidechainIn: .mono(6))
            await runner.apply(configuration(standalone))
            #expect(runner.status == [standalone.id: .routingUnavailable("In 7")])
            let output = rig.render(input: constantInput([0: 0.8, 1: 0.8, 6: 0.4]))
            expectLevel(output[0], 0.4)
        }
    }

    @Test func missingInsertSidechainLeavesTheEffectPlaying() async throws {
        try await withRunner(deviceInputs: 2) { runner, rig in
            let channel = instrumentChannel(effects: [[insert(sidechainID, sidechainIn: .mono(6))]])
            await runner.apply(configuration(channel))
            #expect(runner.status == [channel.id: .routingUnavailable("In 7")])
            try press(channel, runner, rig)
            expectLevel(rig.render(input: constantInput([6: 0.4]))[0], 0.125)
        }
    }

    @Test func instrumentWithoutAudioInIsOff() async throws {
        try await withRunner { runner, rig in
            let channel = instrumentChannel(voiceID)
            await runner.apply(configuration(channel))
            #expect(runner.status == [channel.id: .ready])
            expectLevel(rig.render(input: constantInput([0: 0.8, 1: 0.8]))[0], 0)
        }
    }

    @Test func oneBadPluginInsertIsSkippedNotFatal() async throws {
        try await withRunner { runner, rig in
            let seriesBad = instrumentChannel(effects: [[insert()], [insert(brokenID)]])
            let parallelBad = instrumentChannel(out: out23, effects: [[insert(brokenID), insert()]])
            let onlyBad = instrumentChannel(out: out45, effects: [[insert(brokenID)]])
            await runner.apply(configuration(seriesBad, parallelBad, onlyBad))
            for channel in [seriesBad, parallelBad, onlyBad] {
                #expect(failureMessage(runner.status[channel.id]) != nil)
                try press(channel, runner, rig)
            }
            let output = rig.render()
            expectLevel(output[0], 0.125)
            expectLevel(output[2], 0.125)
            expectLevel(output[4], 0.25)
        }
    }

    @Test func missingInsertIsAFailureOfTheChannelNotAMissingPlugin() async throws {
        try await withRunner { runner, rig in
            let channel = instrumentChannel(effects: [[insert(unknownEffectID)]])
            await runner.apply(configuration(channel))
            // Named by what the owner sees, not by its codes.
            #expect(failureMessage(runner.status[channel.id]) == "None is not installed on this Mac")
            try press(channel, runner, rig)
            expectLevel(rig.render()[0], 0.25)
        }
    }

    @Test func aChannelsOwnPluginDecidesItsStatusFirst() async throws {
        try await withRunner(deviceOutputs: 2) { runner, _ in
            let missing = instrumentChannel(unknownInstrumentID, out: out45, effects: [[insert(brokenID)]])
            let failed = effectChannel(brokenID, out: out45, effects: [[insert(unknownEffectID)]])
            let badInsert = instrumentChannel(out: out45, effects: [[insert(brokenID)]])
            await runner.apply(configuration(missing, failed, badInsert))
            #expect(runner.status[missing.id] == .pluginMissing)
            #expect(failureMessage(runner.status[failed.id])?.contains("AudioUnitInitialize") == true)
            #expect(failureMessage(runner.status[badInsert.id])?.contains("AudioUnitInitialize") == true)
        }
    }

    @Test func unreadableStateIsALoadFailure() async throws {
        try await withRunner { runner, _ in
            let channel = effectChannel(delayID, state: Data("not a property list".utf8))
            await runner.apply(configuration(channel))
            #expect(failureMessage(runner.status[channel.id]) != nil)
            #expect(runner.plugin(channel: channel.id, effect: nil) == nil)
        }
    }

    @Test func aFailedPluginGetsAnotherTryOnTheNextApply() async throws {
        try await withRunner { runner, _ in
            let gate = gated(runner)
            await gate.open(brokenID)
            let bad = effectChannel(brokenID)
            await runner.apply(configuration(bad))
            await runner.apply(configuration(bad))
            #expect(await gate.requested == [brokenID, brokenID])
            #expect(failureMessage(runner.status[bad.id]) != nil)
        }
    }

    // MARK: - The main thread

    @Test func applyCreatesAndConfiguresOnTheMainThreadAndShutDownDisposesThere() async throws {
        try await withRunner { runner, _ in
            let channel = effectChannel(followedUnit("PlR1"))
            await runner.apply(configuration(channel))
            #expect(runner.status[channel.id] == .ready)
            #expect(await lifeEvent(.created, subtype: "PlR1")?.onMainThread == true)
            #expect(await lifeEvent(.renderResourcesAllocated, subtype: "PlR1")?.onMainThread == true)

            runner.shutDown()
            #expect(await lifeEvent(.renderResourcesDeallocated, subtype: "PlR1")?.onMainThread == true)
            #expect(await lifeEvent(.destroyed, subtype: "PlR1")?.onMainThread == true)
        }
    }

    @Test func pluginsHoldTheMainThreadOneAtATimeWithTimeToDrawAfterEach() async throws {
        try await withRunner { runner, _ in
            var held: [(start: ContinuousClock.Instant, end: ContinuousClock.Instant)] = []
            runner.seams.load = { id in
                let start = ContinuousClock.now
                usleep(50_000)
                held.append((start, .now))
                return try await HostedPlugin.load(id)
            }
            await runner.apply(configuration(instrumentChannel(), effectChannel(out: out23), instrumentChannel(out: out45)))
            #expect(held.count == 3)
            for (first, next) in zip(held, held.dropFirst()) {
                #expect(first.end + .milliseconds(15) <= next.start)
            }
        }
    }

    @Test func nothingDeadlocksWhileTheMainActorWaitsForLoads() async throws {
        try await withRunner { runner, _ in
            var finished = 0
            Task {
                await runner.apply(configuration(instrumentChannel(effects: [[insert()]]), effectChannel(out: out23)))
                finished += 1
            }
            Task {
                _ = await CapabilityProbe.probe(sidechainID)
                finished += 1
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while finished < 2, ContinuousClock.now < deadline { await Task.yield() }
            #expect(finished == 2)
        }
    }

    // MARK: - What a loaded plugin gets

    @Test func unitsReadDeviceInputAndTheEngineTransport() async throws {
        try await withRunner { runner, rig in
            let standalone = effectChannel()
            let tempo = instrumentChannel(tempoID, out: out23)
            await runner.apply(configuration(standalone, tempo))
            pr_engine_set_transport(rig.engine, 124, true)
            let output = rig.render(input: constantInput([0: 0.8, 1: 0.8]))
            expectLevel(output[0], 0.4)
            expectLevel(output[2], 0.124)
        }
    }

    @Test func aMonoUnitPlaysOnBothSides() async throws {
        try await withRunner { runner, rig in
            let channel = effectChannel(monoID)
            await runner.apply(configuration(channel))
            #expect(runner.status == [channel.id: .ready])
            #expect(runner.plugin(channel: channel.id, effect: nil)?.channelCount == 1)
            let output = rig.render(input: constantInput([0: 0.8, 1: 0.4]))
            expectLevel(output[0], 0.3)
            expectLevel(output[1], 0.3)
        }
    }

    @Test func callbacksRunOncePerPluginBeforeItsFirstGraph() async throws {
        try await withRunner { runner, _ in
            var callbacks: [AudioUnit: Int] = [:]
            var inGraph: Set<AudioUnit> = []
            let installCallbacks = runner.seams.installCallbacks
            let installGraph = runner.seams.installGraph
            runner.seams.installCallbacks = { plugin, engine in
                #expect(!inGraph.contains(plugin.audioUnit))
                callbacks[plugin.audioUnit, default: 0] += 1
                try installCallbacks(plugin, engine)
            }
            runner.seams.installGraph = { engine, strips, count in
                for strip in UnsafeBufferPointer(start: strips, count: Int(count)) {
                    #expect(strip.source != nil && callbacks[strip.source] == 1)
                    inGraph.insert(strip.source)
                    for row in UnsafeBufferPointer(start: strip.rows, count: Int(strip.rowCount)) {
                        for effect in UnsafeBufferPointer(start: row.effects, count: Int(row.count)) {
                            #expect(callbacks[effect.unit] == 1)
                            inGraph.insert(effect.unit)
                        }
                    }
                }
                return installGraph(engine, strips, count)
            }

            var channel = instrumentChannel(effects: [[insert()]])
            await runner.apply(configuration(channel))
            channel.audioOut = out23
            await runner.apply(configuration(channel))
            channel.effects.append([insert(sidechainID)])
            await runner.apply(configuration(channel))
            #expect(callbacks.count == 3)
            #expect(callbacks.values.allSatisfy { $0 == 1 })
            #expect(inGraph.count == 3)
        }
    }

    // MARK: - Edits

    @Test func editingKeepsLoadedPlugins() async throws {
        try await withRunner { runner, _ in
            let first = instrumentChannel(effects: [[insert()]])
            await runner.apply(configuration(first))
            let plugin = try #require(runner.plugin(channel: first.id, effect: nil))
            let effect = try #require(runner.plugin(channel: first.id, effect: first.effects[0][0].id))
            let added = instrumentChannel(out: out23)
            await runner.apply(configuration(first, added))
            #expect(runner.plugin(channel: first.id, effect: nil) === plugin)
            #expect(runner.plugin(channel: first.id, effect: first.effects[0][0].id) === effect)
            #expect(runner.status == [first.id: .ready, added.id: .ready])
        }
    }

    @Test func routingAndChainOrderOnlyReinstallTheGraph() async throws {
        try await withRunner { runner, rig in
            let halving = insert()
            let side = insert(sidechainID)
            var channel = instrumentChannel(effects: [[halving], [side]])
            await runner.apply(configuration(channel))
            let plugins = [
                runner.plugin(channel: channel.id, effect: nil),
                runner.plugin(channel: channel.id, effect: halving.id),
                runner.plugin(channel: channel.id, effect: side.id),
            ]

            channel.audioOut = out23
            channel.effects = [[side, halving]]
            await runner.apply(configuration(channel))
            #expect(runner.plugin(channel: channel.id, effect: nil) === plugins[0])
            #expect(runner.plugin(channel: channel.id, effect: halving.id) === plugins[1])
            #expect(runner.plugin(channel: channel.id, effect: side.id) === plugins[2])

            try press(channel, runner, rig)
            let output = rig.render()
            expectLevel(output[0], 0)
            expectLevel(output[2], 0.25)
        }
    }

    @Test func applyingTheSameConfigurationInstallsNothing() async throws {
        try await withRunner { runner, _ in
            var installs = 0
            let install = runner.seams.installGraph
            runner.seams.installGraph = { engine, strips, count in
                installs += 1
                return install(engine, strips, count)
            }
            let channel = instrumentChannel()
            await runner.apply(configuration(channel))
            #expect(installs == 1)
            await runner.apply(configuration(channel))
            #expect(installs == 1)
        }
    }

    @Test func replacingAPluginLoadsTheNewOneAndRetiresTheOld() async throws {
        try await withRunner { runner, rig in
            let effect = insert()
            var channel = instrumentChannel(effects: [[effect]])
            await runner.apply(configuration(channel))
            weak let oldSource = runner.plugin(channel: channel.id, effect: nil)
            weak let oldEffect = runner.plugin(channel: channel.id, effect: effect.id)
            #expect(oldSource != nil && oldEffect != nil)

            channel.slot.plugin = voiceID
            channel.audioIn = in01
            channel.effects[0][0].slot.plugin = sidechainID
            await runner.apply(configuration(channel))
            #expect(runner.plugin(channel: channel.id, effect: nil)?.id == voiceID)
            #expect(runner.plugin(channel: channel.id, effect: effect.id)?.id == sidechainID)
            #expect(runner.status == [channel.id: .ready])
            #expect(oldSource == nil)
            #expect(oldEffect == nil)
            expectLevel(rig.render(input: constantInput([0: 0.8, 1: 0.8]))[0], 0.4)
        }
    }

    @Test func aPluginThatFailsToReplaceLeavesTheChannelFailed() async throws {
        try await withRunner { runner, rig in
            var channel = effectChannel()
            await runner.apply(configuration(channel))
            channel.slot.plugin = brokenID
            await runner.apply(configuration(channel))
            #expect(failureMessage(runner.status[channel.id]) != nil)
            #expect(runner.plugin(channel: channel.id, effect: nil) == nil)
            expectLevel(rig.render(input: constantInput([0: 0.8, 1: 0.8]))[0], 0)
        }
    }

    @Test func aPluginOfARemovedEffectLeavesTheGraph() async throws {
        try await withRunner { runner, rig in
            var channel = instrumentChannel(effects: [[insert()]])
            await runner.apply(configuration(channel))
            channel.effects = []
            await runner.apply(configuration(channel))
            try press(channel, runner, rig)
            expectLevel(rig.render()[0], 0.25)
        }
    }

    // MARK: - State

    @Test func stateIsRestoredOnLoad() async throws {
        let saved = try await HostedPlugin.load(delayID)
        AudioUnitSetParameter(saved.audioUnit, kDelayParam_WetDryMix, kAudioUnitScope_Global, 0, 12, 0)
        let state = try saved.fullState()
        try await withRunner { runner, _ in
            let channel = effectChannel(delayID, state: state)
            await runner.apply(configuration(channel))
            let plugin = try #require(runner.plugin(channel: channel.id, effect: nil))
            var value: AudioUnitParameterValue = 0
            AudioUnitGetParameter(plugin.audioUnit, kDelayParam_WetDryMix, kAudioUnitScope_Global, 0, &value)
            #expect(value == 12)
        }
    }

    @Test func capturingStateFillsSlots() async throws {
        try await withRunner { runner, _ in
            let channel = instrumentChannel(effects: [[insert(delayID)]])
            let config = configuration(channel)
            await runner.apply(config)
            let captured = runner.capturingState(of: config)
            #expect(captured.channels[0].slot.state != nil)
            #expect(captured.channels[0].effects[0][0].slot.state != nil)
            #expect(captured.name == config.name && captured.id == config.id)
            #expect(runner.status == [channel.id: .ready])
        }
    }

    @Test func aPluginThatCannotBeReadKeepsItsStateAndIsReported() async throws {
        let known = try await HostedPlugin.load(delayID).fullState()
        try await withRunner { runner, _ in
            let channel = instrumentChannel(effects: [[InsertEffect(slot: slot(delayID, state: known))]])
            let config = configuration(channel)
            await runner.apply(config)
            runner.readState = { plugin in
                if plugin.id == delayID { throw HostedPluginError.invalidState }
                return try plugin.fullState()
            }

            let capture = runner.captureState(of: config)

            #expect(capture.configuration.channels[0].slot.state != nil)
            #expect(capture.configuration.channels[0].effects[0][0].slot.state == known)
            #expect(capture.unreadable == [channel.effects[0][0].slot.displayName])
        }
    }

    @Test func capturedStateComesBackOnALaterLoad() async throws {
        let channel = effectChannel(delayID)
        var captured: Configuration?
        try await withRunner { runner, _ in
            await runner.apply(configuration(channel))
            let plugin = try #require(runner.plugin(channel: channel.id, effect: nil))
            AudioUnitSetParameter(plugin.audioUnit, kDelayParam_WetDryMix, kAudioUnitScope_Global, 0, 33, 0)
            captured = runner.capturingState(of: configuration(channel))
        }
        try await withRunner { runner, _ in
            await runner.apply(try #require(captured))
            let plugin = try #require(runner.plugin(channel: channel.id, effect: nil))
            var value: AudioUnitParameterValue = 0
            AudioUnitGetParameter(plugin.audioUnit, kDelayParam_WetDryMix, kAudioUnitScope_Global, 0, &value)
            #expect(value == 33)
        }
    }

    @Test func capturingLeavesASlotWithoutItsPluginAlone() async throws {
        try await withRunner { runner, _ in
            let saved = Data("saved".utf8)
            let missing = instrumentChannel(unknownInstrumentID, state: saved)
            var replaced = effectChannel(state: nil, out: out23)
            await runner.apply(configuration(missing, replaced))
            // The configuration names another plugin than the one that runs.
            replaced.slot.plugin = sidechainID
            let captured = runner.capturingState(of: configuration(missing, replaced))
            #expect(captured.channels[0].slot.state == saved)
            #expect(captured.channels[1].slot.state == nil)
        }
    }

    // MARK: - Capabilities

    @Test func capabilitiesAreStoredOnFirstLoad() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
        try await withRunner(cache: CapabilityCache(file: file)) { runner, _ in
            let channel = instrumentChannel(voiceID, effects: [[insert(sidechainID)]])
            #expect(runner.capabilities(channel: channel.id) == nil)
            await runner.apply(configuration(channel))
            #expect(runner.capabilities(channel: channel.id) == PluginCapabilities(acceptsMIDI: true, hasAudioIn: true, hasSidechain: false))
        }
        let reopened = CapabilityCache(file: file)
        #expect(reopened[sidechainID] == PluginCapabilities(acceptsMIDI: false, hasAudioIn: true, hasSidechain: true))
    }

    @Test func capabilitiesComeFromTheCache() async throws {
        let cache = makeCache()
        let remembered = PluginCapabilities(acceptsMIDI: true, hasAudioIn: true, hasSidechain: true)
        cache[gainID] = remembered
        cache[unknownInstrumentID] = remembered
        try await withRunner(cache: cache) { runner, _ in
            let loaded = effectChannel()
            let missing = instrumentChannel(unknownInstrumentID, out: out23)
            await runner.apply(configuration(loaded, missing))
            #expect(runner.capabilities(channel: loaded.id) == remembered)
            #expect(runner.capabilities(channel: missing.id) == remembered)
            #expect(runner.capabilities(channel: UUID()) == nil)
        }
    }

    // MARK: - MIDI slots

    @Test func midiSlotsAreStableAndReused() async throws {
        try await withRunner { runner, _ in
            let first = instrumentChannel(unknownInstrumentID)
            let second = instrumentChannel(unknownInstrumentID)
            await runner.apply(configuration(first, second))
            #expect(runner.midiSlot(channel: first.id) == 0)
            #expect(runner.midiSlot(channel: second.id) == 1)

            await runner.apply(configuration(second))
            #expect(runner.midiSlot(channel: first.id) == nil)
            #expect(runner.midiSlot(channel: second.id) == 1)

            let third = instrumentChannel(unknownInstrumentID)
            await runner.apply(configuration(third, second))
            #expect(runner.midiSlot(channel: third.id) == 0)
            #expect(runner.midiSlot(channel: second.id) == 1)
        }
    }

    // MARK: - Meter strips

    @Test func meterStripFollowsTheChannelsInTheGraph() async throws {
        try await withRunner(deviceOutputs: 4) { runner, rig in
            let first = instrumentChannel(out: out01)
            let beyond = instrumentChannel(out: out45)
            let last = instrumentChannel(out: out23)
            let missing = instrumentChannel(unknownInstrumentID, out: out01)
            await runner.apply(configuration(first, beyond, missing, last))
            #expect(runner.meterStrip(channel: first.id) == 0)
            // Left out of the graph, so the channels after it shift down.
            #expect(runner.meterStrip(channel: beyond.id) == nil)
            #expect(runner.meterStrip(channel: missing.id) == nil)
            #expect(runner.meterStrip(channel: last.id) == 1)
            #expect(runner.meterStrip(channel: UUID()) == nil)

            try press(last, runner, rig)
            _ = rig.render()
            let strip = try #require(runner.meterStrip(channel: last.id))
            #expect(abs(rig.meters(strip: strip).left - 0.25) < tolerance)
            #expect(rig.meters(strip: 0).left == 0)
        }
    }

    @Test func aChannelWithoutMIDIHasNoSlot() async throws {
        try await withRunner { runner, rig in
            let standalone = effectChannel()
            let played = instrumentChannel(out: out23)
            await runner.apply(configuration(standalone, played))
            #expect(runner.midiSlot(channel: standalone.id) == nil)
            #expect(runner.midiSlot(channel: played.id) == 0)
            #expect(runner.midiSlot(channel: UUID()) == nil)
            try press(played, runner, rig)
            expectLevel(rig.render()[2], 0.25)
        }
    }

    @Test func aPluginThatTakesNoMIDIGivesUpItsSlot() async throws {
        try await withRunner { runner, _ in
            var channel = instrumentChannel(unknownInstrumentID)
            await runner.apply(configuration(channel))
            #expect(runner.midiSlot(channel: channel.id) == 0)
            channel.slot.plugin = unknownEffectID
            await runner.apply(configuration(channel))
            #expect(runner.midiSlot(channel: channel.id) == nil)
        }
    }

    @Test func channelsBeyondTheSlotsHaveNone() async throws {
        try await withRunner { runner, _ in
            let channels = (0..<65).map { _ in instrumentChannel(unknownInstrumentID) }
            await runner.apply(Configuration(name: "Test", channels: channels))
            let slots = channels.dropLast().compactMap { runner.midiSlot(channel: $0.id) }
            #expect(slots == Array(0...63))
            #expect(runner.midiSlot(channel: channels[64].id) == nil)

            await runner.apply(Configuration(name: "Test", channels: Array(channels.dropFirst())))
            #expect(runner.midiSlot(channel: channels[64].id) == 0)
        }
    }

    // MARK: - Plugin lifetime

    @Test func aRemovedPluginStaysAliveUntilARenderHasHappened() async throws {
        try await withRunner { runner, rig in
            pr_engine_set_audio_running(rig.engine, true)
            defer { pr_engine_set_audio_running(rig.engine, false) }
            let channel = instrumentChannel()
            await runner.apply(configuration(channel))
            _ = rig.render()
            weak let plugin = runner.plugin(channel: channel.id, effect: nil)
            #expect(plugin != nil)

            await runner.apply(configuration())
            runner.collectRetired()
            #expect(plugin != nil)

            _ = rig.render()
            #expect(plugin != nil, "only collecting releases it")
            runner.collectRetired()
            #expect(plugin == nil)
        }
    }

    @Test func aReplacedPluginStaysAliveUntilARenderHasHappened() async throws {
        try await withRunner { runner, rig in
            pr_engine_set_audio_running(rig.engine, true)
            defer { pr_engine_set_audio_running(rig.engine, false) }
            var channel = instrumentChannel()
            await runner.apply(configuration(channel))
            _ = rig.render()
            weak let plugin = runner.plugin(channel: channel.id, effect: nil)

            channel.slot.plugin = voiceID
            await runner.apply(configuration(channel))
            #expect(runner.plugin(channel: channel.id, effect: nil)?.id == voiceID)
            #expect(plugin != nil)

            _ = rig.render()
            runner.collectRetired()
            #expect(plugin == nil)
        }
    }

    @Test func anAbandonedRunnerKeepsItsPluginsAndDoesNothingMore() async throws {
        try await withRunner { runner, rig in
            pr_engine_set_audio_running(rig.engine, true)
            defer { pr_engine_set_audio_running(rig.engine, false) }
            let channel = instrumentChannel()
            await runner.apply(configuration(channel))
            _ = rig.render()
            let removed = instrumentChannel(out: out23)
            await runner.apply(configuration(channel, removed))
            _ = rig.render()
            weak let plugin = runner.plugin(channel: removed.id, effect: nil)
            await runner.apply(configuration(channel))
            _ = rig.render()

            var installs = 0
            runner.seams.installGraph = { _, _, _ in
                installs += 1
                return 0
            }
            runner.abandon()
            runner.collectRetired()
            #expect(plugin != nil, "a stuck render may still be in it")

            await runner.apply(configuration())
            #expect(installs == 0)
            #expect(plugin != nil)
        }
    }

    @Test func abandoningEndsTheWaitForALoadAndDiscardsIt() async throws {
        try await withRunner { runner, _ in
            let gate = gated(runner)
            var installs = 0
            runner.seams.installGraph = { _, _, _ in
                installs += 1
                return 0
            }
            let channel = instrumentChannel()
            let applying = Task { await runner.apply(configuration(channel)) }
            await gate.waitUntilRequested(1)
            let installsBefore = installs

            runner.abandon()
            await applying.value
            await gate.open(instrumentID)
            await finishLoads(runner)

            #expect(installs == installsBefore)
            #expect(runner.plugin(channel: channel.id, effect: nil) == nil)
        }
    }

    @Test func slotsAreAnnouncedBeforeAPluginHasLoaded() async throws {
        try await withRunner { runner, _ in
            let gate = gated(runner)
            let channel = instrumentChannel()
            var announced: Int32?
            runner.onMIDISlotsAssigned = { announced = runner.midiSlot(channel: channel.id) }

            let applying = Task { await runner.apply(configuration(channel)) }
            await gate.waitUntilRequested(1)
            #expect(announced == 0)
            #expect(runner.plugin(channel: channel.id, effect: nil) == nil)

            await gate.open(instrumentID)
            await applying.value
        }
    }

    @Test func applyCollectsWhatIsSafeAtItsStart() async throws {
        try await withRunner { runner, rig in
            pr_engine_set_audio_running(rig.engine, true)
            defer { pr_engine_set_audio_running(rig.engine, false) }
            let channel = instrumentChannel()
            await runner.apply(configuration(channel))
            weak let plugin = runner.plugin(channel: channel.id, effect: nil)
            await runner.apply(configuration())
            _ = rig.render()
            #expect(plugin != nil)
            await runner.apply(configuration())
            #expect(plugin == nil)
        }
    }

    @Test func pluginsCanBeReplacedWhileAnotherThreadRenders() async throws {
        try await withRunner { runner, rig in
            pr_engine_set_audio_running(rig.engine, true)
            let progress = RenderProgress()
            let renderer = startRendering(rig, progress: progress)
            var channel = effectChannel(effects: [[insert()]])
            var replaced: [() -> HostedPlugin?] = []
            for iteration in 0..<40 {
                channel.slot.plugin = iteration.isMultiple(of: 2) ? sidechainID : gainID
                channel.effects[0][0].slot.plugin = iteration.isMultiple(of: 2) ? gainID : sidechainID
                await runner.apply(configuration(channel))
                #expect(runner.status == [channel.id: .ready])
                weak let plugin = runner.plugin(channel: channel.id, effect: nil)
                replaced.append { plugin }

                // Two renders later the new graph has been taken, so the old plugin can go mid-stream.
                let target = progress.renders.load(ordering: .relaxed) + 2
                while progress.renders.load(ordering: .relaxed) < target { await Task.yield() }
                runner.collectRetired()
                if iteration > 0 { #expect(replaced[iteration - 1]() == nil) }
            }
            await runner.apply(configuration())
            progress.stop.store(true, ordering: .relaxed)
            await renderer.value
            pr_engine_set_audio_running(rig.engine, false)
            runner.collectRetired()
            #expect(replaced.allSatisfy { $0() == nil })
            #expect(progress.renders.load(ordering: .relaxed) > 0)
        }
    }

    // MARK: - A failed graph install

    @Test func aFailedInstallKeepsThePreviousGraphAndEveryUnit() async throws {
        try await withRunner { runner, rig in
            var changed = instrumentChannel()
            let steady = instrumentChannel(out: out23)
            await runner.apply(configuration(changed, steady))
            try press(changed, runner, rig)
            expectLevel(rig.render()[0], 0.25)
            weak let old = runner.plugin(channel: changed.id, effect: nil)

            let install = runner.seams.installGraph
            runner.seams.installGraph = { _, _, _ in .max }
            changed.slot.plugin = voiceID
            let added = instrumentChannel(out: out45)
            await runner.apply(configuration(changed, steady, added))
            #expect(runner.status == [
                changed.id: .loadFailed("Not enough memory"),
                steady.id: .ready,
                added.id: .loadFailed("Not enough memory"),
            ])
            runner.collectRetired()
            #expect(old != nil, "the previous graph still plays it")
            expectLevel(rig.render()[0], 0.25)

            runner.seams.installGraph = install
            await runner.apply(configuration(changed, steady, added))
            #expect(runner.status == [changed.id: .ready, steady.id: .ready, added.id: .ready])
            #expect(old == nil)
            expectLevel(rig.render()[0], 0)
        }
    }

    @Test func aRemovedPluginWaitsForAnInstallThatWorks() async throws {
        try await withRunner { runner, _ in
            let channel = instrumentChannel()
            await runner.apply(configuration(channel))
            weak let plugin = runner.plugin(channel: channel.id, effect: nil)

            let install = runner.seams.installGraph
            runner.seams.installGraph = { _, _, _ in .max }
            await runner.apply(configuration())
            #expect(runner.status.isEmpty)
            #expect(plugin != nil)

            runner.seams.installGraph = install
            await runner.apply(configuration())
            #expect(plugin == nil)
        }
    }

    @Test func aPluginLoadedDuringFailedInstallsPlaysOnceOneWorks() async throws {
        try await withRunner { runner, rig in
            let install = runner.seams.installGraph
            runner.seams.installGraph = { _, _, _ in .max }
            let channel = instrumentChannel()
            await runner.apply(configuration(channel))
            #expect(runner.status == [channel.id: .loadFailed("Not enough memory")])
            let plugin = runner.plugin(channel: channel.id, effect: nil)
            #expect(plugin != nil)

            runner.seams.installGraph = install
            await runner.apply(configuration(channel))
            #expect(runner.plugin(channel: channel.id, effect: nil) === plugin)
            #expect(runner.status == [channel.id: .ready])
            try press(channel, runner, rig)
            expectLevel(rig.render()[0], 0.25)
        }
    }

    // MARK: - Shutting down

    @Test func shutDownReleasesEverything() async throws {
        try await withRunner { runner, rig in
            let kept = instrumentChannel()
            let removed = instrumentChannel(out: out23)
            pr_engine_set_audio_running(rig.engine, true)
            await runner.apply(configuration(kept, removed))
            weak let keptPlugin = runner.plugin(channel: kept.id, effect: nil)
            weak let removedPlugin = runner.plugin(channel: removed.id, effect: nil)
            await runner.apply(configuration(kept))
            #expect(removedPlugin != nil)
            pr_engine_set_audio_running(rig.engine, false)

            try press(kept, runner, rig)
            runner.shutDown()
            #expect(keptPlugin == nil)
            #expect(removedPlugin == nil)
            #expect(runner.status.isEmpty)
            #expect(runner.plugin(channel: kept.id, effect: nil) == nil)
            #expect(runner.midiSlot(channel: kept.id) == nil)
            for channel in rig.render() { expectLevel(channel, 0) }
        }
    }

    @Test func nothingTouchesTheEngineAfterShutDown() async throws {
        registerTestUnits()
        var rig: Rig? = Rig()
        let runner = ConfigurationRunner(
            engine: try #require(rig).engine, sampleRate: sampleRate, maxFrames: unitMaxFrames,
            deviceInputs: 8, deviceOutputs: 8, cache: makeCache()
        )
        let gate = gated(runner)
        let channel = instrumentChannel()
        let pending = Task { await runner.apply(configuration(channel)) }
        await gate.waitUntilRequested(1)

        runner.shutDown()
        rig = nil

        await gate.open(instrumentID)
        await pending.value
        await finishLoads(runner)
        #expect(await gate.alive.isEmpty)
        #expect(runner.plugin(channel: channel.id, effect: nil) == nil)

        runner.collectRetired()
        runner.shutDown()
        await runner.apply(configuration(channel))
        #expect(await gate.requested == [instrumentID])
        #expect(runner.status.isEmpty)
    }

    // MARK: - Racing applies

    @Test func aSlowPluginDoesNotHoldUpAFastOne() async throws {
        try await withRunner { runner, rig in
            let gate = gated(runner)
            let slow = instrumentChannel(out: out23)
            let fast = effectChannel()
            let applying = Task { await runner.apply(configuration(slow, fast)) }
            await gate.waitUntilRequested(2)
            #expect(runner.status == [slow.id: .loading, fast.id: .loading])

            await gate.open(gainID)
            let deadline = ContinuousClock.now + .seconds(5)
            while runner.status[fast.id] != .ready, ContinuousClock.now < deadline { await Task.yield() }
            #expect(runner.status == [slow.id: .loading, fast.id: .ready])
            expectLevel(rig.render(input: constantInput([0: 0.8, 1: 0.8]))[0], 0.4)

            await gate.open(instrumentID)
            await applying.value
            #expect(runner.status == [slow.id: .ready, fast.id: .ready])
            try press(slow, runner, rig)
            expectLevel(rig.render()[2], 0.25)
        }
    }

    @Test func aChannelPlaysWhileItsEffectStillLoads() async throws {
        try await withRunner { runner, rig in
            let gate = gated(runner)
            await gate.open(instrumentID)
            let channel = instrumentChannel(effects: [[insert()]])
            let applying = Task { await runner.apply(configuration(channel)) }
            let deadline = ContinuousClock.now + .seconds(5)
            while runner.plugin(channel: channel.id, effect: nil) == nil, ContinuousClock.now < deadline { await Task.yield() }
            #expect(runner.status == [channel.id: .loading])
            try press(channel, runner, rig)
            expectLevel(rig.render()[0], 0.25)

            await gate.open(gainID)
            await applying.value
            #expect(runner.status == [channel.id: .ready])
            expectLevel(rig.render()[0], 0.125)
        }
    }

    @Test func aPluginForARemovedChannelIsDiscarded() async throws {
        try await withRunner { runner, rig in
            let gate = gated(runner)
            let stale = instrumentChannel()
            let current = effectChannel()
            let first = Task { await runner.apply(configuration(stale)) }
            await gate.waitUntilRequested(1)
            let second = Task { await runner.apply(configuration(current)) }
            await gate.waitUntilRequested(2)

            // The newest configuration settles while the stale plugin is still on its way.
            await gate.open(gainID)
            await second.value
            await first.value
            #expect(runner.status == [current.id: .ready])

            await gate.open(instrumentID)
            await finishLoads(runner)
            #expect(runner.status == [current.id: .ready])
            #expect(runner.plugin(channel: stale.id, effect: nil) == nil)
            #expect(await gate.alive.map(\.id) == [gainID])
            expectLevel(rig.render(input: constantInput([0: 0.8, 1: 0.8]))[0], 0.4)
        }
    }

    @Test func aPluginForARemovedEffectIsDiscarded() async throws {
        try await withRunner { runner, _ in
            let gate = gated(runner)
            await gate.open(instrumentID)
            let effect = insert()
            var channel = instrumentChannel(effects: [[effect]])
            let first = Task { await runner.apply(configuration(channel)) }
            await gate.waitUntilRequested(2)
            channel.effects = []
            await runner.apply(configuration(channel))
            await first.value
            #expect(runner.status == [channel.id: .ready])

            await gate.open(gainID)
            await finishLoads(runner)
            #expect(runner.plugin(channel: channel.id, effect: effect.id) == nil)
            #expect(await gate.alive.map(\.id) == [instrumentID])
        }
    }

    @Test func aPluginRemovedWhileItIsPreparedIsDiscarded() async throws {
        try await withRunner { runner, _ in
            let gate = LoadGate()
            var callbacks = 0
            let prepare = runner.seams.prepare
            let installCallbacks = runner.seams.installCallbacks
            runner.seams.prepare = { plugin, slot, sampleRate, maxFrames in
                await gate.pass(plugin.id)
                try await prepare(plugin, slot, sampleRate, maxFrames)
            }
            runner.seams.installCallbacks = { plugin, engine in
                callbacks += 1
                try installCallbacks(plugin, engine)
            }
            let channel = effectChannel()
            let first = Task { await runner.apply(configuration(channel)) }
            await gate.waitUntilRequested(1)
            await runner.apply(configuration())
            await first.value

            await gate.open(gainID)
            await finishLoads(runner)
            #expect(callbacks == 0)
            #expect(runner.status.isEmpty)
        }
    }

    @Test func applyingAgainDoesNotLoadARunningLoadTwice() async throws {
        try await withRunner { runner, _ in
            let gate = gated(runner)
            let channel = instrumentChannel()
            let added = effectChannel(out: out23)
            let first = Task { await runner.apply(configuration(channel)) }
            await gate.waitUntilRequested(1)
            let second = Task { await runner.apply(configuration(channel, added)) }
            await gate.waitUntilRequested(2)

            await gate.open(gainID)
            await gate.open(instrumentID)
            await first.value
            await second.value
            #expect(await gate.requested.sorted { $0.subtype < $1.subtype } == [gainID, instrumentID])
            #expect(await gate.alive.count == 2)
            #expect(runner.status == [channel.id: .ready, added.id: .ready])
        }
    }

    @Test func aChannelThatLeavesAndReturnsKeepsItsLoad() async throws {
        try await withRunner { runner, _ in
            let gate = gated(runner)
            let channel = instrumentChannel()
            let first = Task { await runner.apply(configuration(channel)) }
            await gate.waitUntilRequested(1)
            await runner.apply(configuration())
            await first.value
            let third = Task { await runner.apply(configuration(channel)) }
            await Task.yield()

            await gate.open(instrumentID)
            await third.value
            #expect(await gate.requested == [instrumentID])
            #expect(runner.status == [channel.id: .ready])
            #expect(runner.plugin(channel: channel.id, effect: nil) != nil)
        }
    }

    @Test func replacingAPluginThatIsStillLoadingDiscardsIt() async throws {
        try await withRunner { runner, _ in
            let gate = gated(runner)
            var channel = effectChannel()
            let first = Task { await runner.apply(configuration(channel)) }
            await gate.waitUntilRequested(1)
            channel.slot.plugin = sidechainID
            let second = Task { await runner.apply(configuration(channel)) }
            await gate.waitUntilRequested(2)

            await gate.open(sidechainID)
            await second.value
            await first.value
            await gate.open(gainID)
            await finishLoads(runner)
            #expect(runner.plugin(channel: channel.id, effect: nil)?.id == sidechainID)
            #expect(await gate.alive.map(\.id) == [sidechainID])
            #expect(runner.status == [channel.id: .ready])
        }
    }

    @Test func goingBackToAPluginStillLoadingKeepsThatLoad() async throws {
        try await withRunner { runner, _ in
            let gate = gated(runner)
            var channel = effectChannel()
            let first = Task { await runner.apply(configuration(channel)) }
            await gate.waitUntilRequested(1)
            channel.slot.plugin = sidechainID
            let second = Task { await runner.apply(configuration(channel)) }
            await gate.waitUntilRequested(2)
            channel.slot.plugin = gainID
            let third = Task { await runner.apply(configuration(channel)) }
            await Task.yield()

            await gate.open(gainID)
            await gate.open(sidechainID)
            for task in [first, second, third] { await task.value }
            await finishLoads(runner)
            #expect(await gate.requested == [gainID, sidechainID])
            #expect(runner.plugin(channel: channel.id, effect: nil)?.id == gainID)
            #expect(await gate.alive.map(\.id) == [gainID])
        }
    }

    @Test func aLoadTakesTheStateOfTheNewestConfiguration() async throws {
        let saved = try await HostedPlugin.load(delayID)
        AudioUnitSetParameter(saved.audioUnit, kDelayParam_WetDryMix, kAudioUnitScope_Global, 0, 21, 0)
        let state = try saved.fullState()
        try await withRunner { runner, _ in
            let gate = gated(runner)
            var channel = effectChannel(delayID)
            let first = Task { await runner.apply(configuration(channel)) }
            await gate.waitUntilRequested(1)
            channel.slot.state = state
            let second = Task { await runner.apply(configuration(channel)) }
            await Task.yield()

            await gate.open(delayID)
            await first.value
            await second.value
            #expect(await gate.requested == [delayID])
            let plugin = try #require(runner.plugin(channel: channel.id, effect: nil))
            var value: AudioUnitParameterValue = 0
            AudioUnitGetParameter(plugin.audioUnit, kDelayParam_WetDryMix, kAudioUnitScope_Global, 0, &value)
            #expect(value == 21)
        }
    }

    @Test func aFailureForAnOldConfigurationLeavesNoStatus() async throws {
        try await withRunner { runner, _ in
            let gate = gated(runner)
            var channel = effectChannel(brokenID)
            let first = Task { await runner.apply(configuration(channel)) }
            await gate.waitUntilRequested(1)
            channel.slot.plugin = gainID
            let second = Task { await runner.apply(configuration(channel)) }
            await gate.waitUntilRequested(2)

            await gate.open(gainID)
            await second.value
            await first.value
            await gate.open(brokenID)
            await finishLoads(runner)
            #expect(runner.status == [channel.id: .ready])
        }
    }

    // MARK: - Presets

    /// What Apple's reverb reports after `preset`, on a unit set up the way the runner sets up its own.
    private func reverbState(on preset: String?) async throws -> Data {
        let plugin = try await loadPlugin(type: "aufx", subtype: "mrev", manufacturer: "appl")
        if let preset { try plugin.selectFactoryPreset(preset) }
        return try plugin.fullState()
    }

    private func lastFactoryPreset() async throws -> String {
        let plugin = try await loadPlugin(type: "aufx", subtype: "mrev", manufacturer: "appl")
        return try #require(plugin.factoryPresets().last)
    }

    @Test func aChannelNamingAFactoryPresetStartsOnIt() async throws {
        try await withRunner { runner, _ in
            let name = try await lastFactoryPreset()
            var channel = effectChannel(reverbID)
            channel.slot.presetName = name
            await runner.apply(configuration(channel))
            let plugin = try #require(runner.plugin(channel: channel.id, effect: nil))
            #expect(try plugin.fullState() == (try await reverbState(on: name)))
        }
    }

    @Test func anEffectNamingAFactoryPresetStartsOnIt() async throws {
        try await withRunner { runner, _ in
            let name = try await lastFactoryPreset()
            var effect = insert(reverbID)
            effect.slot.presetName = name
            let channel = instrumentChannel(effects: [[effect]])
            await runner.apply(configuration(channel))
            let plugin = try #require(runner.plugin(channel: channel.id, effect: effect.id))
            #expect(try plugin.fullState() == (try await reverbState(on: name)))
        }
    }

    @Test func aPresetTheSlotHoldsTheStateOfIsRestoredAndNotLookedUp() async throws {
        try await withRunner { runner, _ in
            let name = try await lastFactoryPreset()
            let state = try await reverbState(on: nil)
            var channel = effectChannel(reverbID, state: state)
            channel.slot.presetName = name
            await runner.apply(configuration(channel))
            let plugin = try #require(runner.plugin(channel: channel.id, effect: nil))
            #expect(try plugin.fullState() == state)
        }
    }

    @Test func aFactoryPresetThatIsGoneStillLoadsThePlugin() async throws {
        try await withRunner { runner, _ in
            var channel = effectChannel(reverbID)
            channel.slot.presetName = "No such preset"
            await runner.apply(configuration(channel))
            let plugin = try #require(runner.plugin(channel: channel.id, effect: nil))
            #expect(runner.status[channel.id] == .ready)
            #expect(try plugin.fullState() == (try await reverbState(on: nil)))
        }
    }

    @Test func aRunningPluginTakesFactoryPresetsAndSavedStates() async throws {
        try await withRunner { runner, _ in
            let name = try await lastFactoryPreset()
            let channel = effectChannel(reverbID)
            await runner.apply(configuration(channel))
            let plugin = try #require(runner.plugin(channel: channel.id, effect: nil))
            let start = try plugin.fullState()

            try plugin.selectFactoryPreset(name)
            let selected = try plugin.fullState()
            #expect(selected != start)
            #expect(selected == (try await reverbState(on: name)))

            try plugin.restore(start)
            #expect(try plugin.fullState() == start)

            try plugin.restore(selected)
            #expect(try plugin.fullState() == selected)
            let captured = runner.capturingState(of: configuration(channel))
            #expect(captured.channels[0].slot.state == selected)
        }
    }

    @Test func aFailedEffectNamesItsOwnFailure() async throws {
        try await withRunner { runner, _ in
            let bad = insert(brokenID)
            let good = insert()
            let missing = insert(unknownEffectID)
            let channel = instrumentChannel(effects: [[bad, good], [missing]])
            await runner.apply(configuration(channel))
            #expect(runner.failure(effect: bad.id) == failureMessage(runner.status[channel.id]))
            #expect(runner.failure(effect: good.id) == nil)
            #expect(runner.failure(effect: missing.id) == "None is not installed on this Mac")
            #expect(runner.plugin(channel: channel.id, effect: nil) != nil)
        }
    }
}
