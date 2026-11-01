/// Derives tempo, clock presence and transport state from incoming MIDI events.
/// Value type with fixed storage: it runs for hours and must not grow.
public struct ClockTracker: Sendable {
    public static let defaultTempo = 120.0

    private static let ticksPerQuarterNote = 24.0
    private static let maxIntervals = 24
    private static let clockTimeout = 1.0

    /// Ring of the most recent tick times (24 intervals need 25 ticks).
    private var tickTimes = [Double](repeating: 0, count: ClockTracker.maxIntervals + 1)
    private var tickCount = 0
    private var nextSlot = 0
    private var lastTickTime: Double?
    /// The last tick, start or continue.
    private var lastHeardTime: Double?
    private var lastTempo: Double?
    private var justStarted = false

    public private(set) var isPlaying = false

    public init() {}

    public mutating func receive(_ event: MIDIEvent, at seconds: Double) {
        justStarted = event == .start
        switch event {
        case .clock:
            receiveTick(at: seconds)
        case .start, .resume:
            isPlaying = true
            lastHeardTime = seconds
        case .stop:
            isPlaying = false
        case .channelVoice:
            break
        }
    }

    public func isClockRunning(at seconds: Double) -> Bool {
        reading.isClockRunning(at: seconds)
    }

    /// A copy of what the tracker knows, for a thread that does not own it.
    public var reading: Reading {
        Reading(tempo: lastTempo, isPlaying: isPlaying, justStarted: justStarted, lastTickTime: lastTickTime, lastHeardTime: lastHeardTime)
    }

    /// Plain values, so taking one shares nothing with the tracker and its next tick still does not
    /// allocate. A copy of the tracker itself shares the tick storage until that tick.
    public struct Reading: Equatable, Sendable {
        /// Nil until two ticks have given a tempo.
        public let tempo: Double?
        public let isPlaying: Bool
        /// True when the last event was a start, which plays from the top, even while playing. A
        /// continue plays on from where it stopped.
        public let justStarted: Bool
        private let lastTickTime: Double?
        private let lastHeardTime: Double?

        fileprivate init(tempo: Double?, isPlaying: Bool, justStarted: Bool, lastTickTime: Double?, lastHeardTime: Double?) {
            self.tempo = tempo
            self.isPlaying = isPlaying
            self.justStarted = justStarted
            self.lastTickTime = lastTickTime
            self.lastHeardTime = lastHeardTime
        }

        public func isClockRunning(at seconds: Double) -> Bool {
            guard let last = lastTickTime else { return false }
            return seconds - last <= ClockTracker.clockTimeout
        }

        /// True when the transport plays and the source has gone silent, so no Stop is coming. A start
        /// or continue counts as hearing from it: a source that only clocks while it plays has no
        /// recent tick at that moment, and its first one is still on the way.
        public func isStranded(at seconds: Double) -> Bool {
            guard isPlaying, let last = lastHeardTime else { return false }
            return seconds - last > ClockTracker.clockTimeout
        }
    }

    private mutating func receiveTick(at seconds: Double) {
        if let last = lastTickTime, seconds - last > Self.clockTimeout {
            tickCount = 0
            nextSlot = 0
        }
        tickTimes[nextSlot] = seconds
        nextSlot = (nextSlot + 1) % tickTimes.count
        tickCount = min(tickCount + 1, tickTimes.count)
        lastTickTime = seconds
        lastHeardTime = seconds

        guard tickCount >= 2 else { return }
        let oldest = tickTimes[(nextSlot - tickCount + tickTimes.count) % tickTimes.count]
        let mean = (seconds - oldest) / Double(tickCount - 1)
        guard mean > 0 else { return }
        lastTempo = 60.0 / (mean * Self.ticksPerQuarterNote)
    }
}
