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
