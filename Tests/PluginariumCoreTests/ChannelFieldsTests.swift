import Testing
@testable import PluginariumCore

struct ChannelFieldsTests {
    @Test func fieldsFollowThePlugin() {
        let synth = PluginCapabilities(acceptsMIDI: true, hasAudioIn: false, hasSidechain: false)
        #expect(ChannelFields(kind: .instrument, capabilities: synth) == ChannelFields(midiIn: true, audioIn: false, sidechainIn: false))
        let vocoder = PluginCapabilities(acceptsMIDI: true, hasAudioIn: true, hasSidechain: false)
        #expect(ChannelFields(kind: .instrument, capabilities: vocoder) == ChannelFields(midiIn: true, audioIn: true, sidechainIn: false))
        let compressor = PluginCapabilities(acceptsMIDI: false, hasAudioIn: true, hasSidechain: true)
        #expect(ChannelFields(kind: .effect, capabilities: compressor) == ChannelFields(midiIn: false, audioIn: true, sidechainIn: true))
    }

    @Test func standaloneEffectAlwaysShowsAudioIn() {
        let busless = PluginCapabilities(acceptsMIDI: false, hasAudioIn: false, hasSidechain: false)
        #expect(ChannelFields(kind: .effect, capabilities: busless).audioIn)
    }
}

struct UnknownCapabilitiesTests {
    @Test func whileUnknownAChannelShowsTheFieldsItHasValuesFor() {
        var channel = Channel.fixture(kind: .instrument)
        #expect(ChannelFields(channel: channel, capabilities: nil) == ChannelFields(midiIn: false, audioIn: false, sidechainIn: false))
        channel.midiIn = MIDIRoute(sourceName: "Hapax", channel: .all)
        channel.sidechainIn = .stereo(left: 2, right: 3)
        #expect(ChannelFields(channel: channel, capabilities: nil) == ChannelFields(midiIn: true, audioIn: false, sidechainIn: true))
    }

    @Test func aStandaloneEffectShowsAudioInWhileUnknown() {
        #expect(ChannelFields(channel: .fixture(kind: .effect), capabilities: nil).audioIn)
    }

    @Test func knownCapabilitiesDecide() {
        var channel = Channel.fixture(kind: .instrument)
        channel.audioIn = .mono(0)
        let synth = PluginCapabilities(acceptsMIDI: true, hasAudioIn: false, hasSidechain: false)
        #expect(ChannelFields(channel: channel, capabilities: synth) == ChannelFields(kind: .instrument, capabilities: synth))
    }
}
