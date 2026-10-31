/// One entry of a channel selector.
public struct RouteOption<Value: Hashable & Sendable>: Hashable, Sendable {
    public var value: Value
    public var label: String

    public init(_ value: Value, _ label: String) {
        self.value = value
        self.label = label
    }
}

/// What the selectors of a channel offer. The device decides which routes exist, but a route the
/// configuration already holds stays listed, so the owner can see what is wrong with it.
public enum ChannelOptions {

    /// Audio in and sidechain in: Off first when `allowsOff`, then each mono channel, then each
    /// stereo pair. A standalone effect has no Off, except while it has no input at all.
    public static func inputs(deviceInputs: Int, allowsOff: Bool, current: AudioChannels?) -> [RouteOption<AudioChannels?>] {
        var options: [RouteOption<AudioChannels?>] = []
        if allowsOff || current == nil { options.append(RouteOption(nil, "Off")) }
        let monos = (0..<max(deviceInputs, 0)).map { AudioChannels.mono($0) }
        options += (monos + pairs(of: deviceInputs)).map { RouteOption($0, $0.label(prefix: "In")) }
        if let current, !options.contains(where: { $0.value == current }) {
            options.append(RouteOption(current, current.label(prefix: "In")))
        }
        return options
    }

    /// Audio out: each stereo pair, then each mono channel.
    public static func outputs(deviceOutputs: Int, current: AudioChannels) -> [RouteOption<AudioChannels>] {
        let monos = (0..<max(deviceOutputs, 0)).map { AudioChannels.mono($0) }
        var options = (pairs(of: deviceOutputs) + monos).map { RouteOption($0, $0.label(prefix: "Out")) }
        if !options.contains(where: { $0.value == current }) {
            options.append(RouteOption(current, current.label(prefix: "Out")))
        }
        return options
    }

    /// MIDI in: No MIDI first, then the system's sources. A source the channel holds that the
    /// system lacks is listed as not connected.
    public static func midiSources(_ sources: [String], current: String?) -> [RouteOption<String?>] {
        var options = [RouteOption<String?>(nil, "No MIDI")] + sources.map { RouteOption($0, $0) }
        if let current, !sources.contains(current) {
            options.append(RouteOption(current, "\(current) (not connected)"))
        }
        return options
    }

    public static let midiChannels: [RouteOption<MIDIChannelFilter>] =
        [RouteOption(.all, "All")] + (1...16).map { RouteOption(.channel($0), String($0)) }

    /// Channels 1–2, 3–4 and so on. A last channel without a partner has no pair.
    private static func pairs(of count: Int) -> [AudioChannels] {
        stride(from: 0, to: max(count - 1, 0), by: 2).map { AudioChannels.stereo(left: $0, right: $0 + 1) }
    }
}
