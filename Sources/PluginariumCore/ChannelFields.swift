/// Which input fields a channel shows for its plugin.
public struct ChannelFields: Equatable, Sendable {
    public var midiIn: Bool
    public var audioIn: Bool
    public var sidechainIn: Bool

    public init(midiIn: Bool, audioIn: Bool, sidechainIn: Bool) {
        self.midiIn = midiIn
        self.audioIn = audioIn
        self.sidechainIn = sidechainIn
    }

    public init(kind: PluginKind, capabilities: PluginCapabilities) {
        switch kind {
        case .instrument:
            self.init(
                midiIn: capabilities.acceptsMIDI,
                audioIn: capabilities.hasAudioIn,
                sidechainIn: capabilities.hasSidechain
            )
        case .effect:
            // A standalone effect always shows Audio in, even if the plugin reports no bus.
            self.init(midiIn: capabilities.acceptsMIDI, audioIn: true, sidechainIn: capabilities.hasSidechain)
        }
    }

    /// Until the plugin's capabilities are known, the fields the channel already has values for.
    public init(channel: Channel, capabilities: PluginCapabilities?) {
        if let capabilities {
            self.init(kind: channel.kind, capabilities: capabilities)
        } else {
            self.init(
                midiIn: channel.midiIn != nil,
                audioIn: channel.kind == .effect || channel.audioIn != nil,
                sidechainIn: channel.sidechainIn != nil
            )
        }
    }
}
