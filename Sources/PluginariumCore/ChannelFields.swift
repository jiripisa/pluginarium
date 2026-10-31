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
}
