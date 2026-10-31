import CRenderCore
import CoreMIDI
import Foundation
import Observation
import PluginariumCore
import Synchronization
import os

private let logger = Logger(subsystem: "io.jp4.pluginarium", category: "midi")

private let clockPollInterval = Duration.milliseconds(250)

/// Where the events of one route go.
public struct MIDIRouteTarget: Equatable, Sendable {
    public var route: MIDIRoute
    public var slot: Int32

    public init(route: MIDIRoute, slot: Int32) {
        self.route = route
        self.slot = slot
    }
}

/// Takes MIDI from every system source to the strips that want it, and follows the clock of one
/// source. Notes go from the CoreMIDI thread straight into the render core and never wait for the
/// main actor. The app only listens: it has no output port and sends MIDI to nothing.
///
/// `clockRunning` and `tempo` follow at 4 Hz, from a poll on the main actor, so the CoreMIDI thread
/// never hops here and a clock that goes silent still shows. `tempo` is what plugins are told, which
/// is the last tempo known, or 120 BPM if there has been none.
///
/// The router does not own the engine, and must go before the engine does.
@MainActor
@Observable
public final class MIDIRouter {

    /// The names of the system's sources in its order. Sources with one name are one name here,
    /// and a route to it hears them all.
    public private(set) var sources: [String] = []

    public private(set) var clockRunning = false
    public private(set) var tempo = ClockTracker.defaultTempo

    private let routing: MIDIRouting
    @ObservationIgnored private var input: MIDIInput?
    @ObservationIgnored private var clockPoll: Task<Void, Never>?

    /// Without a CoreMIDI client, which is not an error, `sources` stays empty and only `handle`
    /// gets events through.
    public init(engine: OpaquePointer) {
        routing = MIDIRouting(engine: engine)
        input = MIDIInput(routing: routing) { [weak self] in
            Task { @MainActor in self?.refreshSources() }
        }
        refreshSources()
        clockPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: clockPollInterval)
                guard let self else { return }
                refreshClock(at: routing.hostSeconds())
            }
        }
    }

    deinit {
        clockPoll?.cancel()
        routing.close()
    }

    /// Past this, nothing reaches the engine, so the engine can go.
    public private(set) var isClosed = false

    /// Lets go of every source and stops the clock poll. The router does nothing after this.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        clockPoll?.cancel()
        input = nil
        routing.close()
        sources = []
    }

    /// Applies at once: the next event goes by these routes.
    public func setRoutes(_ routes: [MIDIRouteTarget]) {
        guard !isClosed else { return }
        routing.setRoutes(routes)
    }

    /// Follows the clock of the source called `name`, and of nothing when it is nil. A new source
    /// starts over: its transport is stopped until it says otherwise, and plugins keep the last
    /// known tempo until it gives one.
    public func setClockSource(_ name: String?) {
        guard !isClosed else { return }
        routing.setClockSource(name)
        refreshClock(at: routing.hostSeconds())
    }

    /// The one path of every event, from CoreMIDI and from tests. Time in `seconds` only has to
    /// keep to one clock.
    public nonisolated func handle(_ event: MIDIEvent, fromSource source: String, at seconds: Double) {
        routing.handle(event, fromSource: source, at: seconds)
    }

    /// What the poll does each time. `seconds` is on the clock of `handle`.
    func refreshClock(at seconds: Double) {
        let clock = routing.clock(at: seconds)
        if clock.running != clockRunning { clockRunning = clock.running }
        if clock.tempo != tempo { tempo = clock.tempo }
    }

    nonisolated func hostSeconds() -> Double {
        routing.hostSeconds()
    }

    nonisolated func makeReceiveBlock() -> MIDIReceiveBlock {
        routing.makeReceiveBlock()
    }

    nonisolated func sourceTag(named name: String) -> SourceTag {
        routing.tag(named: name)
    }

    private func refreshSources() {
        sources = input?.refresh() ?? []
    }
}

/// Names one source in the refCon of its connection, so the CoreMIDI thread gets a name without
/// looking anything up.
final class SourceTag: Sendable {
    let name: String

    init(name: String) {
        self.name = name
    }
}

/// What the CoreMIDI thread and the main actor share. Everything here runs on either. The receive
/// block is made here because a closure formed on the main actor belongs to it, and CoreMIDI calls
/// this one on its own thread.
///
/// One `Mutex`, an `os_unfair_lock` on this platform, guards it, and neither side holds it for long.
/// The main actor builds a new route table or tracker outside the lock, swaps it in, and frees the
/// old one after letting go. The CoreMIDI thread holds it for one event, which is a scan of the
/// routes and some pushes onto rings, with no allocation and nothing that blocks. The route table
/// is never changed in place, only replaced.
///
/// Routing inside the lock, rather than retaining the table and routing after, means a replaced
/// table is never used again and never freed on the CoreMIDI thread, a clock that was just replaced
/// cannot overwrite the transport, and nothing reaches the engine after `close`.
///
/// `pr_engine_push_midi` takes one producer per slot. That producer is the one thread CoreMIDI calls
/// the port's receive block on, whichever source a message came from, or the test's thread for a
/// `handle` in a test. Every push is under the lock, so not even both together can overlap.
private final class MIDIRouting: Sendable {

    private struct State {
        var routes: [MIDIRouteTarget] = []
        var clockSource: String?
        /// Only `handle` calls into it. The main actor replaces it whole with a new one and reads
        /// `reading`, so the CoreMIDI thread owns its tick storage and never copies it.
        var tracker = ClockTracker()
        var reading = ClockTracker().reading
        /// What plugins are told, which outlives any one tracker.
        var tempo = ClockTracker.defaultTempo
    }

    private nonisolated(unsafe) let engine: OpaquePointer
    private let secondsPerHostTick: Double
    private let state = Mutex(State())
    /// One per name and never removed, so that a callback carrying a tag finds it alive even after
    /// its source left. The receive block holds this object, so the tags outlive every callback.
    private let tags = Mutex<[String: SourceTag]>([:])

    init(engine: OpaquePointer) {
        self.engine = engine
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        secondsPerHostTick = Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    func handle(_ event: MIDIEvent, fromSource source: String, at seconds: Double) {
        state.withLock { state in
            if case .channelVoice(let status, let data1, let data2) = event {
                for target in state.routes where isSameName(target.route.sourceName, source) && target.route.channel.matches(status: status) {
                    pr_engine_push_midi(engine, target.slot, status, data1, data2)
                }
            } else if let clockSource = state.clockSource, isSameName(clockSource, source) {
                state.tracker.receive(event, at: seconds)
                state.reading = state.tracker.reading
                state.tempo = state.reading.tempo ?? state.tempo
                if state.reading.justStarted { pr_engine_rewind_transport(engine) }
                pr_engine_set_transport(engine, state.tempo, state.reading.isPlaying)
            }
        }
    }

    func setRoutes(_ routes: [MIDIRouteTarget]) {
        var replaced = routes
        state.withLock { swap(&$0.routes, &replaced) }
    }

    func setClockSource(_ name: String?) {
        var replaced = ClockTracker()
        state.withLock { state in
            guard name != state.clockSource else { return }
            state.clockSource = name
            swap(&state.tracker, &replaced)
            state.reading = state.tracker.reading
            pr_engine_set_transport(engine, state.tempo, false)
        }
    }

    func clock(at seconds: Double) -> (running: Bool, tempo: Double) {
        state.withLock { ($0.reading.isClockRunning(at: seconds), $0.tempo) }
    }

    /// Past this, no event reaches the engine, not even one already on its way.
    func close() {
        var replaced: [MIDIRouteTarget] = []
        state.withLock { state in
            swap(&state.routes, &replaced)
            state.clockSource = nil
        }
    }

    func hostSeconds() -> Double {
        Double(mach_absolute_time()) * secondsPerHostTick
    }

    func tag(named name: String) -> SourceTag {
        tags.withLock { tags in
            if let tag = tags[name] { return tag }
            let tag = SourceTag(name: name)
            tags[name] = tag
            return tag
        }
    }

    func makeReceiveBlock() -> MIDIReceiveBlock {
        { [self] list, refCon in
            guard let refCon else { return }
            let source = Unmanaged<SourceTag>.fromOpaque(refCon).takeUnretainedValue()
            let seconds = hostSeconds()
            forEachEvent(in: list) { handle($0, fromSource: source.name, at: seconds) }
        }
    }
}

/// The CoreMIDI client and its input port. `refresh` runs on the main actor.
private final class MIDIInput {
    private let routing: MIDIRouting
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected: [MIDIEndpointRef: String] = [:]

    /// `setupChanged` is called on a thread of CoreMIDI's choosing.
    init?(routing: MIDIRouting, setupChanged: @escaping @Sendable () -> Void) {
        self.routing = routing
        var status = MIDIClientCreateWithBlock("Pluginarium" as CFString, &client) { notification in
            if notification.pointee.messageID == .msgSetupChanged { setupChanged() }
        }
        guard status == noErr else {
            logger.error("Cannot create a MIDI client: \(status)")
            return nil
        }
        status = MIDIInputPortCreateWithProtocol(client, "Pluginarium In" as CFString, ._1_0, &port, routing.makeReceiveBlock())
        guard status == noErr else {
            logger.error("Cannot create a MIDI input port: \(status)")
            return nil
        }
    }

    /// Runs for a failed `init` too, and takes the port with the client.
    deinit {
        if client != 0 { MIDIClientDispose(client) }
    }

    /// Connects what is new, lets go of what is gone, and returns the names of the sources.
    func refresh() -> [String] {
        let endpoints = (0..<MIDIGetNumberOfSources()).map(MIDIGetSource).filter { $0 != 0 }
        let names = endpoints.map(Self.name)
        let present = Dictionary(zip(endpoints, names), uniquingKeysWith: { first, _ in first })
        let changes = connectionChanges(connected: connected, present: present)
        for endpoint in changes.disconnect {
            MIDIPortDisconnectSource(port, endpoint)
            connected[endpoint] = nil
        }
        for endpoint in changes.connect {
            guard let name = present[endpoint] else { continue }
            let tag = Unmanaged.passUnretained(routing.tag(named: name)).toOpaque()
            let status = MIDIPortConnectSource(port, endpoint, tag)
            if status == noErr {
                connected[endpoint] = name
            } else {
                logger.error("Cannot connect \(name, privacy: .public): \(status)")
            }
        }
        return uniqueSourceNames(names)
    }

    private static func name(of endpoint: MIDIEndpointRef) -> String {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &value) == noErr, let value else {
            var uniqueID: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID)
            return "Source \(uniqueID)"
        }
        var name = value.takeRetainedValue() as String
        // A native string, so that comparing it per message never calls back into a bridged one.
        name.makeContiguousUTF8()
        return name
    }
}

/// By bytes, because `==` allocates to compare strings with stacked combining marks, and this runs
/// per message. Every name comes from CoreMIDI, so one source always has the same bytes.
private func isSameName(_ first: String, _ second: String) -> Bool {
    first.utf8.elementsEqual(second.utf8)
}

/// What to do when the sources `present` replace the ones `connected`. A source that was renamed
/// is in both lists, because its name lives in its connection.
func connectionChanges(
    connected: [MIDIEndpointRef: String], present: [MIDIEndpointRef: String]
) -> (disconnect: [MIDIEndpointRef], connect: [MIDIEndpointRef]) {
    (
        disconnect: connected.filter { present[$0.key] != $0.value }.map(\.key),
        connect: present.filter { connected[$0.key] != $0.value }.map(\.key)
    )
}

func uniqueSourceNames(_ names: [String]) -> [String] {
    var seen: Set<String> = []
    return names.filter { seen.insert($0).inserted }
}

/// Calls `body` with each message in `list` that is a `MIDIEvent`.
func forEachEvent(in list: UnsafePointer<MIDIEventList>, _ body: (MIDIEvent) -> Void) {
    for packet in list.unsafeSequence() {
        let words = packet.words()
        var index = words.startIndex
        while index < words.endIndex {
            let word = words[index]
            if let event = MIDIEvent(ump: word) { body(event) }
            index += wordCount(ofMessageStartingWith: word)
        }
    }
}

/// A packet can hold several messages, and a later word of a long one, such as system exclusive
/// data, can look like a note or a clock tick. The message type in the top four bits gives the size.
private func wordCount(ofMessageStartingWith word: UInt32) -> Int {
    switch word >> 28 {
    case 0x0, 0x1, 0x2, 0x6, 0x7: 1
    case 0x3, 0x4, 0x8, 0x9, 0xA: 2
    case 0xB, 0xC: 3
    default: 4
    }
}
