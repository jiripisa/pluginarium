import Testing
@testable import PluginariumCore

@Suite("PluginCapabilities")
struct CapabilitiesTests {

    @Test("Capabilities derive from type and input buses")
    func deriveCapabilities() {
        #expect(PluginCapabilities.derive(auType: "aumu", inputBusNames: []) == PluginCapabilities(acceptsMIDI: true, hasAudioIn: false, hasSidechain: false))
        #expect(PluginCapabilities.derive(auType: "aumf", inputBusNames: ["Input"]) == PluginCapabilities(acceptsMIDI: true, hasAudioIn: true, hasSidechain: false))
        #expect(PluginCapabilities.derive(auType: "aumu", inputBusNames: ["Sidechain"]) == PluginCapabilities(acceptsMIDI: true, hasAudioIn: false, hasSidechain: true))
        #expect(PluginCapabilities.derive(auType: "aufx", inputBusNames: ["Input", "Sidechain"]) == PluginCapabilities(acceptsMIDI: false, hasAudioIn: true, hasSidechain: true))
    }

    @Test("Second bus of an effect is a sidechain whatever its name")
    func secondEffectBusIsSidechain() {
        #expect(PluginCapabilities.derive(auType: "aufx", inputBusNames: ["Main", "Aux"]) == PluginCapabilities(acceptsMIDI: false, hasAudioIn: true, hasSidechain: true))
    }

    @Test("Plugin kind maps from the AU type")
    func kindFromType() {
        #expect(PluginKind(auType: "aumu") == .instrument)
        #expect(PluginKind(auType: "aumf") == .instrument)
        #expect(PluginKind(auType: "aufx") == .effect)
        #expect(PluginKind(auType: "aumi") == nil)
    }
}
