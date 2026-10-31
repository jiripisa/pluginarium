import PluginariumCore
import PluginariumTestUnits
import Testing
@testable import PluginariumAudio

@Suite("CapabilityProbe")
struct CapabilityProbeTests {

    @Test("A plugin is loaded once and reports capabilities and factory presets")
    func probesSidechainEffect() async {
        registerTestUnits()
        let result = await CapabilityProbe.probe(PluginID(type: "aufx", subtype: "PlSc", manufacturer: "Plug"))
        #expect(result?.capabilities == PluginCapabilities(acceptsMIDI: false, hasAudioIn: true, hasSidechain: true))
        #expect(result?.factoryPresets != nil)
    }

    @Test("An instrument has MIDI and no audio in")
    func probesInstrument() async {
        registerTestUnits()
        let result = await CapabilityProbe.probe(PluginID(type: "aumu", subtype: "PlIn", manufacturer: "Plug"))
        #expect(result?.capabilities == PluginCapabilities(acceptsMIDI: true, hasAudioIn: false, hasSidechain: false))
    }

    @Test("A plugin that cannot initialize still tells what it is, since the probe never initializes it")
    func probesBrokenUnit() async {
        registerTestUnits()
        let result = await CapabilityProbe.probe(PluginID(type: "aufx", subtype: "PlBd", manufacturer: "Plug"))
        #expect(result?.capabilities.hasAudioIn == true)
    }

    @Test("A plugin that is not installed gives nothing")
    func missingPlugin() async {
        registerTestUnits()
        let result = await CapabilityProbe.probe(PluginID(type: "aumu", subtype: "Nope", manufacturer: "Nope"))
        #expect(result == nil)
    }
}
