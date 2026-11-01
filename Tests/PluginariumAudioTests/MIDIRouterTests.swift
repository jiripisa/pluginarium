import CRenderCore
import CoreMIDI
import Foundation
import PluginariumCore
import PluginariumTestUnits
import Synchronization
import Testing
@testable import PluginariumAudio

private let outs23 = PRChannels(left: 2, right: 3)
private let noteOnChannel1 = MIDIEvent.channelVoice(status: 0x90, data1: 60, data2: 100)
private let noteOnUMP: UInt32 = 0x2090_3C64
private let noteOffUMP: UInt32 = 0x2080_3C00
private let clockUMP: UInt32 = 0x10F8_0000
/// At the default 120 BPM.
private let beatsPerBlock = Float(blockFrames) * 2 / Float(sampleRate)

private func target(_ source: String, _ channel: MIDIChannelFilter, slot: Int32) -> MIDIRouteTarget {
    MIDIRouteTarget(route: MIDIRoute(sourceName: source, channel: channel), slot: slot)
}

/// Sends `count` clock ticks and returns the time of the last one.
@MainActor
@discardableResult
private func sendTicks(_ router: MIDIRouter, bpm: Double = 124, count: Int = 48, from source: String = "A", after start: Double = 0) -> Double {
    let interval = 60 / bpm / 24
    var time = start
    for _ in 0..<count {
        time += interval
        router.handle(.clock, fromSource: source, at: time)
    }
    return time
}

/// Runs `body` with a router on a new engine playing `strips`, and lets the router go first.
@MainActor
private func withRouter(_ strips: [StripSpec], _ body: @MainActor (MIDIRouter, Rig) async throws -> Void) async throws {
    let rig = Rig()
    for strip in strips {
        #expect(pr_install_host_callbacks(strip.source.audioUnit, rig.engine) == noErr)
        pr_engine_set_follows_transport(rig.engine, strip.source.audioUnit, true)
    }
    rig.install(strips)
    defer { withExtendedLifetime(rig) {} }
    try await body(MIDIRouter(engine: rig.engine), rig)
}

/// One instrument on outputs 1-2 at slot 0, and one on outputs 3-4 at slot 1.
private func twoInstruments() async throws -> [StripSpec] {
    [
        StripSpec(source: try await instrument(), audioOut: outs01, midiSlot: 0),
        StripSpec(source: try await instrument(), audioOut: outs23, midiSlot: 1),
    ]
}

/// A unit that reports tempo on output 1 and beat, or -1 while stopped, on output 2.
private func tempoReporter() async throws -> [StripSpec] {
    [StripSpec(source: try await loadPlugin(type: "aumu", subtype: "PlTp"))]
}

/// Units reporting the all-off controllers they had: one on outputs 1-2 at slot 0, and one on outputs
/// 3-4 at slot 1. All Sound Off shows on the first output of each, All Notes Off on the second.
private func allOffReporters() async throws -> [StripSpec] {
    [
        StripSpec(source: try await loadPlugin(type: "aumu", subtype: "PlOf"), audioOut: outs01, midiSlot: 0),
        StripSpec(source: try await loadPlugin(type: "aumu", subtype: "PlOf"), audioOut: outs23, midiSlot: 1),
    ]
}

/// What an all-off reporter shows once a controller came on each of the 16 MIDI channels.
private let everyChannel: Float = 0.16

/// `messages` go into one packet each, so a message of several words stays whole.
private func withEventList(_ messages: [[UInt32]], _ body: (UnsafePointer<MIDIEventList>) -> Void) {
    let size = 1024
    let storage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<MIDIEventList>.alignment)
    defer { storage.deallocate() }
    let list = storage.bindMemory(to: MIDIEventList.self, capacity: 1)
    var packet = MIDIEventListInit(list, ._1_0)
    for words in messages {
        packet = MIDIEventListAdd(list, size, packet, 0, words.count, words)
    }
    body(UnsafePointer(list))
}

private func events(in messages: [[UInt32]]) -> [MIDIEvent] {
    var result: [MIDIEvent] = []
    withEventList(messages) { list in
        forEachEvent(in: list) { result.append($0) }
    }
    return result
}

/// Calls `block` the way CoreMIDI does: off the main actor, with a source's refCon.
private func deliver(_ words: [UInt32], source: SourceTag, to block: @escaping MIDIReceiveBlock) async {
    nonisolated(unsafe) let block = block
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global(qos: .userInteractive).async {
            withEventList([words]) { block($0, Unmanaged.passUnretained(source).toOpaque()) }
            continuation.resume()
        }
    }
}

@Suite("MIDI router")
@MainActor
struct MIDIRouterTests {

    // MARK: - Routes

    @Test func noteGoesOnlyToMatchingRoute() async throws {
        try await withRouter(try await twoInstruments()) { router, rig in
            router.setRoutes([target("A", .channel(1), slot: 0), target("A", .channel(2), slot: 1)])
            router.handle(.channelVoice(status: 0x91, data1: 60, data2: 100), fromSource: "A", at: 0)
            let output = rig.render()
            expectLevel(output[0], 0)
            expectLevel(output[2], 0.25)
        }
    }

    @Test func otherSourceIsIgnored() async throws {
        try await withRouter(try await twoInstruments()) { router, rig in
            router.setRoutes([target("A", .channel(1), slot: 0)])
            router.handle(noteOnChannel1, fromSource: "B", at: 0)
            expectLevel(rig.render()[0], 0)
            router.handle(noteOnChannel1, fromSource: "A", at: 0)
            expectLevel(rig.render()[0], 0.25)
        }
    }

    @Test func allChannelsRouteAcceptsAny() async throws {
        try await withRouter(try await twoInstruments()) { router, rig in
            router.setRoutes([target("A", .all, slot: 0)])
            router.handle(.channelVoice(status: 0x9F, data1: 60, data2: 100), fromSource: "A", at: 0)
            expectLevel(rig.render()[0], 0.25)
        }
    }

    @Test func oneEventGoesToEveryMatchingRoute() async throws {
        try await withRouter(try await twoInstruments()) { router, rig in
            router.setRoutes([target("A", .channel(1), slot: 0), target("A", .all, slot: 1)])
            router.handle(noteOnChannel1, fromSource: "A", at: 0)
            let output = rig.render()
            expectLevel(output[0], 0.25)
            expectLevel(output[2], 0.25)
        }
    }

    @Test func newRoutesApplyAtOnce() async throws {
        try await withRouter(try await twoInstruments()) { router, rig in
            router.setRoutes([target("A", .all, slot: 0)])
            router.setRoutes([target("B", .all, slot: 1)])
            router.handle(noteOnChannel1, fromSource: "A", at: 0)
            router.handle(noteOnChannel1, fromSource: "B", at: 0)
            let output = rig.render()
            expectLevel(output[0], 0)
            expectLevel(output[2], 0.25)
        }
    }

    // MARK: - Route changes

    @Test func aHeldNoteStopsWhenItsRouteChanges() async throws {
        try await withRouter(try await twoInstruments()) { router, rig in
            router.setRoutes([target("A", .all, slot: 0), target("A", .all, slot: 1)])
            router.handle(noteOnChannel1, fromSource: "A", at: 0)
            var output = rig.render()
            expectLevel(output[0], 0.25)
            expectLevel(output[2], 0.25)

            // The key comes up on the old source, whose note off no longer reaches slot 0.
            router.setRoutes([target("B", .all, slot: 0), target("A", .all, slot: 1)])
            router.handle(.channelVoice(status: 0x80, data1: 60, data2: 0), fromSource: "A", at: 0)
            output = rig.render()
            expectLevel(output[0], 0)
            expectLevel(output[2], 0)
        }
    }

    @Test func aHeldNoteOnAnUnchangedRoutePlaysThroughAnEditOfAnother() async throws {
        try await withRouter(try await twoInstruments()) { router, rig in
            router.setRoutes([target("A", .all, slot: 0), target("A", .all, slot: 1)])
            router.handle(noteOnChannel1, fromSource: "A", at: 0)
            _ = rig.render()

            router.setRoutes([target("B", .all, slot: 0), target("A", .all, slot: 1)])
            let output = rig.render()
            expectLevel(output[0], 0)
            expectLevel(output[2], 0.25)
        }
    }

    @Test(arguments: [
        [target("B", .channel(1), slot: 0)],
        [target("A", .channel(2), slot: 0)],
        [target("A", .channel(1), slot: 1)],
        [],
    ])
    func aRouteThatLeavesItsSlotSendsAllOffOnEveryChannel(routes: [MIDIRouteTarget]) async throws {
        try await withRouter(try await allOffReporters()) { router, rig in
            router.setRoutes([target("A", .channel(1), slot: 0)])
            expectLevel(rig.render()[0], 0)

            router.setRoutes(routes)
            let output = rig.render()
            expectLevel(output[0], everyChannel)
            expectLevel(output[1], everyChannel)
        }
    }

    @Test func aRouteThatStaysSendsNothing() async throws {
        try await withRouter(try await allOffReporters()) { router, rig in
            let first = target("A", .channel(1), slot: 0)
            let second = target("B", .all, slot: 1)
            router.setRoutes([first, second])
            router.setRoutes([second, first])
            for channel in rig.render() { expectLevel(channel, 0) }
        }
    }

    @Test func aFirstRouteOnASlotSendsNothing() async throws {
        try await withRouter(try await allOffReporters()) { router, rig in
            router.setRoutes([target("A", .all, slot: 0)])
            for channel in rig.render() { expectLevel(channel, 0) }
        }
    }

    // MARK: - Clock

    @Test func clockFromOtherSourceIsIgnored() async throws {
        try await withRouter(try await tempoReporter()) { router, rig in
            router.setClockSource("A")
            let last = sendTicks(router, from: "B")
            router.handle(.start, fromSource: "B", at: last)
            router.refreshClock(at: last)
            #expect(router.tempo == 120)
            #expect(!router.clockRunning)
            let output = rig.render()
            expectLevel(output[0], 0.12)
            expectLevel(output[1], -1)
        }
    }

    @Test func clockSetsTempoSeenByPlugin() async throws {
        try await withRouter(try await tempoReporter()) { router, rig in
            router.setClockSource("A")
            let last = sendTicks(router)
            router.refreshClock(at: last)
            #expect(abs(router.tempo - 124) < 0.1)
            #expect(router.clockRunning)
            expectLevel(rig.render()[0], 0.124)
        }
    }

    @Test func stopClearsPlayingForPlugin() async throws {
        try await withRouter(try await tempoReporter()) { router, rig in
            router.setClockSource("A")
            let last = sendTicks(router)
            router.handle(.start, fromSource: "A", at: last)
            expectLevel(rig.render()[1], 0)
            router.handle(.stop, fromSource: "A", at: last)
            let output = rig.render()
            expectLevel(output[1], -1)
            expectLevel(output[0], 0.124)
        }
    }

    @Test func continueResumesPlayingForPlugin() async throws {
        try await withRouter(try await tempoReporter()) { router, rig in
            router.setClockSource("A")
            router.handle(.start, fromSource: "A", at: 0)
            _ = rig.render()
            router.handle(.stop, fromSource: "A", at: 0)
            expectLevel(rig.render()[1], -1)
            router.handle(.resume, fromSource: "A", at: 0)
            #expect(rig.render()[1][0] > 0)
        }
    }

    @Test func startAfterStopPlaysFromTheTop() async throws {
        try await withRouter(try await tempoReporter()) { router, rig in
            router.setClockSource("A")
            router.handle(.start, fromSource: "A", at: 0)
            for _ in 0..<100 { _ = rig.render() }
            router.handle(.stop, fromSource: "A", at: 1)
            expectLevel(rig.render()[1], -1)
            router.handle(.start, fromSource: "A", at: 2)
            expectLevel(rig.render()[1], 0)
            expectLevel(rig.render()[1], beatsPerBlock)
        }
    }

    @Test func continueAfterStopKeepsThePosition() async throws {
        try await withRouter(try await tempoReporter()) { router, rig in
            router.setClockSource("A")
            router.handle(.start, fromSource: "A", at: 0)
            for _ in 0..<100 { _ = rig.render() }
            router.handle(.stop, fromSource: "A", at: 1)
            expectLevel(rig.render()[1], -1)
            router.handle(.resume, fromSource: "A", at: 2)
            expectLevel(rig.render()[1], 100 * beatsPerBlock)
        }
    }

    @Test func startWhilePlayingPlaysFromTheTop() async throws {
        try await withRouter(try await tempoReporter()) { router, rig in
            router.setClockSource("A")
            router.handle(.start, fromSource: "A", at: 0)
            for _ in 0..<100 { _ = rig.render() }
            router.handle(.start, fromSource: "A", at: 1)
            expectLevel(rig.render()[1], 0)
        }
    }

    @Test func aTickAfterAStartDoesNotRewindAgain() async throws {
        try await withRouter(try await tempoReporter()) { router, rig in
            router.setClockSource("A")
            router.handle(.start, fromSource: "A", at: 0)
            for _ in 0..<100 { _ = rig.render() }
            router.handle(.clock, fromSource: "A", at: 0.5)
            expectLevel(rig.render()[1], 100 * beatsPerBlock)
        }
    }

    @Test func startFromOtherSourceDoesNotRewind() async throws {
        try await withRouter(try await tempoReporter()) { router, rig in
            router.setClockSource("A")
            router.handle(.start, fromSource: "A", at: 0)
            for _ in 0..<100 { _ = rig.render() }
            router.handle(.start, fromSource: "B", at: 1)
            expectLevel(rig.render()[1], 100 * beatsPerBlock)
        }
    }

    @Test func noClockSourceFollowsNothing() async throws {
        try await withRouter(try await tempoReporter()) { router, rig in
            let last = sendTicks(router)
            router.refreshClock(at: last)
            #expect(router.tempo == 120)
            #expect(!router.clockRunning)
            expectLevel(rig.render()[0], 0.12)
        }
    }

    @Test func aRunningClockFallsWhenTicksStopAndTheTempoStays() async throws {
        try await withRouter(try await tempoReporter()) { router, rig in
            router.setClockSource("A")
            let last = sendTicks(router)
            router.refreshClock(at: last + 0.5)
            #expect(router.clockRunning)
            router.refreshClock(at: last + 1.5)
            #expect(!router.clockRunning)
            #expect(abs(router.tempo - 124) < 0.1)
            expectLevel(rig.render()[0], 0.124)
        }
    }

    @Test func aClockThatDiesStopsTheTransportAndTheTempoStays() async throws {
        try await withRouter(try await tempoReporter()) { router, rig in
            router.setClockSource("A")
            let last = sendTicks(router)
            router.handle(.start, fromSource: "A", at: last)
            expectLevel(rig.render()[1], 0)

            router.refreshClock(at: last + 0.5)
            #expect(rig.render()[1][0] > 0)

            router.refreshClock(at: last + 1.5)
            #expect(!router.clockRunning)
            let output = rig.render()
            expectLevel(output[0], 0.124)
            expectLevel(output[1], -1)
        }
    }

    @Test func aClockThatComesBackDoesNotRestartTheTransport() async throws {
        try await withRouter(try await tempoReporter()) { router, rig in
            router.setClockSource("A")
            var last = sendTicks(router)
            router.handle(.start, fromSource: "A", at: last)
            router.refreshClock(at: last + 1.5)

            last = sendTicks(router, after: last + 2)
            router.refreshClock(at: last)
            #expect(router.clockRunning)
            expectLevel(rig.render()[1], -1)

            router.handle(.resume, fromSource: "A", at: last)
            #expect(rig.render()[1][0] >= 0)
            #expect(rig.render()[1][0] > 0)
        }
    }

    @Test func aStartAfterADeadClockPlaysFromTheTop() async throws {
        try await withRouter(try await tempoReporter()) { router, rig in
            router.setClockSource("A")
            let last = sendTicks(router)
            router.handle(.start, fromSource: "A", at: last)
            for _ in 0..<100 { _ = rig.render() }
            router.refreshClock(at: last + 1.5)
            expectLevel(rig.render()[1], -1)

            router.handle(.start, fromSource: "A", at: last + 2)
            expectLevel(rig.render()[1], 0)
        }
    }

    @Test(arguments: [MIDIEvent.start, .resume])
    func aPollRightAfterAStartLeavesItToItsFirstTick(event: MIDIEvent) async throws {
        try await withRouter(try await tempoReporter()) { router, rig in
            router.setClockSource("A")
            let last = sendTicks(router)
            router.refreshClock(at: last + 5)
            router.handle(event, fromSource: "A", at: last + 5)
            router.refreshClock(at: last + 5.01)
            #expect(rig.render()[1][0] >= 0)

            sendTicks(router, after: last + 5.02)
            #expect(rig.render()[1][0] > 0)
        }
    }

    @Test func aStartThatNeverGetsATickStopsToo() async throws {
        try await withRouter(try await tempoReporter()) { router, rig in
            router.setClockSource("A")
            router.handle(.start, fromSource: "A", at: 10)
            router.refreshClock(at: 11.5)
            expectLevel(rig.render()[1], -1)
        }
    }

    @Test func aDeadClockTellsAFollowingUnitThatTheTransportChanged() async throws {
        let strips = try await tempoReporter()
        try await withRouter(strips) { router, rig in
            router.setClockSource("A")
            let last = sendTicks(router)
            router.handle(.start, fromSource: "A", at: last)
            _ = rig.render()
            _ = rig.render()

            router.refreshClock(at: last + 1.5)
            _ = rig.render()
            let unit = strips[0].source.audioUnit
            try #expect(!transport(of: unit, in: rig.engine).playing.boolValue)
            try #expect(changedReadings(of: unit, in: rig.engine).allSatisfy { $0 })
        }
    }

    @Test func aUnitThatDoesNotFollowSeesNothingOfADeadClock() async throws {
        let strips = try await tempoReporter()
        try await withRouter(strips) { router, rig in
            let unit = strips[0].source.audioUnit
            pr_engine_set_follows_transport(rig.engine, unit, false)
            router.setClockSource("A")
            let last = sendTicks(router)
            router.handle(.start, fromSource: "A", at: last)
            _ = rig.render()
            var output = rig.render()
            expectLevel(output[0], 0.124)
            expectLevel(output[1], -1)

            router.refreshClock(at: last + 1.5)
            output = rig.render()
            expectLevel(output[0], 0.124)
            expectLevel(output[1], -1)
            try #expect(!transport(of: unit, in: rig.engine).playing.boolValue)
            try #expect(changedReadings(of: unit, in: rig.engine).allSatisfy { !$0 })
        }
    }

    @Test func theFirstTickOfAClockChangesNoTempo() async throws {
        try await withRouter(try await tempoReporter()) { router, rig in
            router.setClockSource("A")
            router.handle(.clock, fromSource: "A", at: 0)
            router.refreshClock(at: 0)
            #expect(router.clockRunning)
            #expect(router.tempo == 120)
            expectLevel(rig.render()[0], 0.12)
        }
    }

    @Test func changingTheClockSourceStartsOverAndKeepsTheTempoUntilANewOneIsKnown() async throws {
        try await withRouter(try await tempoReporter()) { router, rig in
            router.setClockSource("A")
            var last = sendTicks(router)
            router.handle(.start, fromSource: "A", at: last)
            expectLevel(rig.render()[1], 0)

            router.setClockSource("B")
            #expect(!router.clockRunning)
            #expect(abs(router.tempo - 124) < 0.1)
            var output = rig.render()
            expectLevel(output[0], 0.124)
            expectLevel(output[1], -1)

            // The old source no longer counts.
            last = sendTicks(router, bpm: 60, count: 10, from: "A", after: last)
            router.handle(.start, fromSource: "A", at: last)
            router.refreshClock(at: last)
            #expect(!router.clockRunning)
            #expect(abs(router.tempo - 124) < 0.1)
            output = rig.render()
            expectLevel(output[0], 0.124)
            expectLevel(output[1], -1)

            // One tick from the new source gives no tempo, so plugins keep what they have.
            last = sendTicks(router, count: 1, from: "B", after: last)
            router.handle(.start, fromSource: "B", at: last)
            router.refreshClock(at: last)
            #expect(router.clockRunning)
            #expect(abs(router.tempo - 124) < 0.1)
            expectLevel(rig.render()[0], 0.124)

            // A few ticks make a tempo free of the old source's history.
            last = sendTicks(router, bpm: 90, count: 10, from: "B", after: last)
            router.refreshClock(at: last)
            #expect(abs(router.tempo - 90) < 0.1)
            expectLevel(rig.render()[0], 0.09)
        }
    }

    @Test func settingTheSameClockSourceChangesNothing() async throws {
        try await withRouter(try await tempoReporter()) { router, rig in
            router.setClockSource("A")
            // `setClockSource` reads the host clock, so the events keep to it too.
            let last = sendTicks(router, after: router.hostSeconds())
            router.handle(.start, fromSource: "A", at: last)
            router.setClockSource("A")
            router.refreshClock(at: last)
            #expect(router.clockRunning)
            #expect(rig.render()[1][0] >= 0)
        }
    }

    @Test func thePollFollowsTheClockWithoutAnyHelp() async throws {
        try await withRouter(try await tempoReporter()) { router, _ in
            router.setClockSource("A")
            router.handle(.clock, fromSource: "A", at: router.hostSeconds())
            let rises = ContinuousClock.now + .seconds(1)
            while !router.clockRunning, ContinuousClock.now < rises { try await Task.sleep(for: .milliseconds(10)) }
            #expect(router.clockRunning)
            let falls = ContinuousClock.now + .seconds(3)
            while router.clockRunning, ContinuousClock.now < falls { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!router.clockRunning)
        }
    }

    // MARK: - Event lists

    @Test func eventListsDecodeEveryMessage() {
        #expect(events(in: [[noteOnUMP], [clockUMP]]) == [noteOnChannel1, .clock])
        #expect(events(in: [[clockUMP, noteOnUMP]]) == [.clock, noteOnChannel1])
    }

    @Test func aWordInsideALongerMessageIsNotAMessage() {
        let sysEx: [UInt32] = [0x3006_4142, noteOnUMP]
        let sysEx8: [UInt32] = [0x5000_0000, clockUMP, noteOnUMP, clockUMP]
        let flexData: [UInt32] = [0xD000_0000, clockUMP, noteOnUMP, clockUMP]
        let reserved3: [UInt32] = [0xB000_0000, clockUMP, noteOnUMP]
        let midi2Note: [UInt32] = [0x4090_3C00, noteOnUMP]
        for message in [sysEx, sysEx8, flexData, reserved3, midi2Note] {
            #expect(events(in: [message + [clockUMP]]) == [.clock])
        }
    }

    @Test func anEventListFromAnotherThreadReachesItsRoute() async throws {
        try await withRouter(try await twoInstruments()) { router, rig in
            router.setRoutes([target("A", .channel(1), slot: 0), target("B", .all, slot: 1)])
            await deliver([noteOnUMP], source: router.sourceTag(named: "A"), to: router.makeReceiveBlock())
            let output = rig.render()
            expectLevel(output[0], 0.25)
            expectLevel(output[2], 0)
        }
    }

    @Test func clockFromAnEventListCarriesTheHostTime() async throws {
        try await withRouter(try await tempoReporter()) { router, _ in
            router.setClockSource("A")
            await deliver([clockUMP], source: router.sourceTag(named: "A"), to: router.makeReceiveBlock())
            router.refreshClock(at: router.hostSeconds())
            #expect(router.clockRunning)
        }
    }

    @Test func sourcesOfOneNameShareOneTag() async throws {
        try await withRouter([]) { router, _ in
            #expect(router.sourceTag(named: "A") === router.sourceTag(named: "A"))
            #expect(router.sourceTag(named: "A") !== router.sourceTag(named: "B"))
            #expect(router.sourceTag(named: "A").name == "A")
        }
    }

    // MARK: - Threads

    @Test func routesAndClockChangeWhileEventsArriveAndAudioRenders() async throws {
        try await withRouter(try await twoInstruments()) { router, rig in
            let rendering = RenderProgress()
            let renderer = startRendering(rig, progress: rendering)
            let sending = RenderProgress()
            let sender = Task.detached {
                var time = 0.0
                while !sending.stop.load(ordering: .relaxed) {
                    time += 0.02
                    router.handle(noteOnChannel1, fromSource: "A", at: time)
                    router.handle(.channelVoice(status: 0x80, data1: 60, data2: 0), fromSource: "A", at: time)
                    router.handle(.clock, fromSource: "A", at: time)
                    router.handle(.start, fromSource: "A", at: time)
                    sending.renders.add(1, ordering: .relaxed)
                }
            }
            for round in 0..<2000 {
                router.setRoutes([target("A", .all, slot: Int32(round % 2))])
                router.setClockSource(round % 3 == 0 ? nil : "A")
                router.refreshClock(at: Double(round))
                await Task.yield()
            }
            sending.stop.store(true, ordering: .relaxed)
            rendering.stop.store(true, ordering: .relaxed)
            await sender.value
            await renderer.value
            #expect(sending.renders.load(ordering: .relaxed) > 0)
            #expect(rendering.renders.load(ordering: .relaxed) > 0)
        }
    }

    @Test func noEventReachesTheEngineOnceTheRouterHasGone() async throws {
        let strips = try await twoInstruments()
        let rig = Rig()
        rig.install(strips)
        var router: MIDIRouter? = MIDIRouter(engine: rig.engine)
        router?.setRoutes([target("A", .all, slot: 0)])
        let tag = try #require(router).sourceTag(named: "A")
        let block = try #require(router).makeReceiveBlock()
        await deliver([noteOnUMP], source: tag, to: block)
        expectLevel(rig.render()[0], 0.25)

        router = nil
        await deliver([noteOffUMP], source: tag, to: block)
        expectLevel(rig.render()[0], 0.25)
    }

    @Test func closingCutsTheRouterOffFromTheEngine() async throws {
        try await withRouter(try await twoInstruments()) { router, rig in
            router.setRoutes([target("A", .all, slot: 0)])
            router.setClockSource("A")
            router.close()
            #expect(router.isClosed)

            router.handle(noteOnChannel1, fromSource: "A", at: 0)
            expectLevel(rig.render()[0], 0)

            router.setRoutes([target("A", .all, slot: 0)])
            router.setClockSource("A")
            router.handle(noteOnChannel1, fromSource: "A", at: 0)
            sendTicks(router)
            router.refreshClock(at: 2)
            expectLevel(rig.render()[0], 0)
            #expect(!router.clockRunning)
            #expect(router.sources.isEmpty)
        }
    }

    // MARK: - Sources

    @Test func connectionsFollowTheSystemsSources() {
        let connected: [MIDIEndpointRef: String] = [1: "Stays", 2: "Leaves", 3: "Old name"]
        let present: [MIDIEndpointRef: String] = [1: "Stays", 3: "New name", 4: "Arrives"]
        let changes = connectionChanges(connected: connected, present: present)
        #expect(Set(changes.disconnect) == [2, 3])
        #expect(Set(changes.connect) == [3, 4])
    }

    @Test func nothingChangesWhenTheSourcesAreTheSame() {
        let sources: [MIDIEndpointRef: String] = [1: "A", 2: "A"]
        let changes = connectionChanges(connected: sources, present: sources)
        #expect(changes.disconnect.isEmpty)
        #expect(changes.connect.isEmpty)
    }

    @Test func sourcesOfOneNameListOnce() {
        #expect(uniqueSourceNames(["B", "A", "B", "C", "A"]) == ["B", "A", "C"])
    }
}
