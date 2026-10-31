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
    private var lastTempo: Double?

    public private(set) var isPlaying = false

    public init() {}

    public mutating func receive(_ event: MIDIEvent, at seconds: Double) {
        switch event {
        case .clock: receiveTick(at: seconds)
        case .start, .resume: isPlaying = true
        case .stop: isPlaying = false
        case .channelVoice: break
        }
    }

    /// Mean-interval tempo, or the last known tempo, or 120 BPM if there never was one.
    public func tempo(at seconds: Double) -> Double {
        lastTempo ?? Self.defaultTempo
    }

    public func isClockRunning(at seconds: Double) -> Bool {
        guard let last = lastTickTime else { return false }
        return seconds - last <= Self.clockTimeout
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

        guard tickCount >= 2 else { return }
        let oldest = tickTimes[(nextSlot - tickCount + tickTimes.count) % tickTimes.count]
        let mean = (seconds - oldest) / Double(tickCount - 1)
        guard mean > 0 else { return }
        lastTempo = 60.0 / (mean * Self.ticksPerQuarterNote)
    }
}
