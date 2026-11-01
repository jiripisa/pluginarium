/// A MIDI message Pluginarium cares about, decoded from a Universal MIDI Packet word.
public enum MIDIEvent: Equatable, Sendable {
    case channelVoice(status: UInt8, data1: UInt8, data2: UInt8)
    case clock
    case start
    case stop
    case resume

    /// Decodes message type 1 (system real time: clock, start, continue, stop) and
    /// type 2 (MIDI 1.0 channel voice). Anything else returns nil.
    public init?(ump word: UInt32) {
        let status = UInt8((word >> 16) & 0xFF)
        switch word >> 28 {
        case 1:
            switch status {
            case 0xF8: self = .clock
            case 0xFA: self = .start
            case 0xFB: self = .resume
            case 0xFC: self = .stop
            default: return nil
            }
        case 2:
            guard (0x80...0xEF).contains(status) else { return nil }
            self = .channelVoice(
                status: status,
                data1: UInt8((word >> 8) & 0xFF),
                data2: UInt8(word & 0xFF))
        default:
            return nil
        }
    }
}

extension MIDIChannelFilter {
    /// Whether a channel voice status byte passes this filter. System statuses
    /// (0xF0 and above) never match, not even `.all`.
    public func matches(status: UInt8) -> Bool {
        guard status < 0xF0 else { return false }
        switch self {
        case .all: return true
        case .channel(let channel): return Int(status & 0x0F) + 1 == channel
        }
    }
}
