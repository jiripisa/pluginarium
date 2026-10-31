import AppKit
import AudioToolbox
import PluginariumCore
import PluginariumTestUnits
import Testing
@testable import PluginariumAudio

@Suite("Hosting")
struct HostingTests {

    @Test("State round-trips on Apple's delay")
    func stateRoundTripOnAppleDelay() async throws {
        let id = PluginID(type: "aufx", subtype: "dely", manufacturer: "appl")
        let first = try await HostedPlugin.load(id)
        AudioUnitSetParameter(first.audioUnit, kDelayParam_WetDryMix, kAudioUnitScope_Global, 0, 12, 0)
        let second = try await HostedPlugin.load(id)
        try second.restore(try first.fullState())
        var value: AudioUnitParameterValue = 0
        AudioUnitGetParameter(second.audioUnit, kDelayParam_WetDryMix, kAudioUnitScope_Global, 0, &value)
        #expect(value == 12)
    }

    @Test("Catalog finds the test units with their kinds")
    func catalogFindsTestUnitsAndKinds() {
        registerTestUnits()
        let infos = PluginCatalog.scan()
        #expect(infos.first { $0.id.subtype == "PlVo" }?.kind == .instrument)
        #expect(infos.first { $0.id.subtype == "PlFx" }?.kind == .effect)
    }

    @Test("Test units load in process and report their buses")
    func testUnitsLoad() async throws {
        registerTestUnits()
        let sidechain = try await HostedPlugin.load(PluginID(type: "aufx", subtype: "PlSc", manufacturer: "Plug"))
        #expect(sidechain.inputBusNames == ["Input", "Sidechain"])
        let instrument = try await HostedPlugin.load(PluginID(type: "aumu", subtype: "PlIn", manufacturer: "Plug"))
        #expect(instrument.inputBusNames.isEmpty)
        try instrument.configure(sampleRate: 48_000, maxFrames: 512)
    }

    @Test("A unit that fails to allocate throws from configure")
    func badUnitThrows() async throws {
        registerTestUnits()
        let bad = try await HostedPlugin.load(PluginID(type: "aufx", subtype: "PlBd", manufacturer: "Plug"))
        #expect(throws: (any Error).self) { try bad.configure(sampleRate: 48_000, maxFrames: 512) }
    }

    @Test("Factory presets can be listed and selected")
    func factoryPresets() async throws {
        let plugin = try await HostedPlugin.load(PluginID(type: "aufx", subtype: "dely", manufacturer: "appl"))
        let names = plugin.factoryPresets()
        if let first = names.first { try plugin.selectFactoryPreset(first) }
        #expect(throws: (any Error).self) { try plugin.selectFactoryPreset("No such preset") }
    }

    @Test("Four-character codes round-trip losslessly, including bytes >= 0x80")
    func fourCCRoundTrip() {
        for code: FourCharCode in [0x5061_6C6E, 0x8AB0_FFE9, 0x0000_0080, 0x6162_2020] {
            #expect(fourCC(string(fourCC: code)) == code)
        }
        #expect(string(fourCC: 0x8AB0_FFE9) != string(fourCC: 0x8AB1_FFE9))
        #expect(fourCC("ab") == 0x6162_2020)
        let id = PluginID(type: "aumu", subtype: "ab", manufacturer: string(fourCC: 0x8AB0_FFE9))
        #expect(PluginID(id.componentDescription).manufacturer == id.manufacturer)
    }

    @Test("Asking Apple's delay for a view returns a view or nil without crashing")
    @MainActor
    func makeViewOnAppleDelay() async throws {
        let plugin = try await HostedPlugin.load(PluginID(type: "aufx", subtype: "dely", manufacturer: "appl"))
        try plugin.configure(sampleRate: 48_000, maxFrames: 4096)
        let view = await plugin.makeView()
        if let view { #expect(view.frame.width >= 0) }
    }

    @Test("A view request that is never answered gives up at the timeout")
    @MainActor
    func viewRequestTimesOut() async throws {
        let plugin = try await HostedPlugin.load(PluginID(type: "aufx", subtype: "dely", manufacturer: "appl"))
        try plugin.configure(sampleRate: 48_000, maxFrames: 4096)
        let view = await plugin.requestedControllerView(timeout: .milliseconds(200))
        #expect(view == nil)
    }

    @Test("Closing a plugin's view lets go of what owns it")
    @MainActor
    func releasingTheView() async throws {
        let plugin = try await HostedPlugin.load(PluginID(type: "aufx", subtype: "dely", manufacturer: "appl"))
        try plugin.configure(sampleRate: 48_000, maxFrames: 4096)
        weak var view = await plugin.makeView()
        #expect(view != nil)
        #expect(plugin.viewOwner != nil)
        plugin.releaseView()
        #expect(plugin.viewOwner == nil)
    }

    @Test("A test unit has no view to give")
    @MainActor
    func testUnitHasNoView() async throws {
        registerTestUnits()
        let plugin = try await HostedPlugin.load(PluginID(type: "aufx", subtype: "PlFx", manufacturer: "Plug"))
        try plugin.configure(sampleRate: 48_000, maxFrames: 4096)
        #expect(await plugin.makeView() == nil)
    }

    @Test("State reads the same until the plugin changes", arguments: ["dely", "mrev"])
    func stateIsStable(subtype: String) async throws {
        let id = PluginID(type: "aufx", subtype: subtype, manufacturer: "appl")
        let first = try await HostedPlugin.load(id)
        try first.configure(sampleRate: 48_000, maxFrames: 4096)
        let state = try first.fullState()
        #expect(try first.fullState() == state)
        let second = try await HostedPlugin.load(id)
        try second.configure(sampleRate: 48_000, maxFrames: 4096)
        try second.restore(state)
        #expect(try second.fullState() == state)
    }

    @Test("A test unit's state reads the same until it changes")
    func testUnitStateIsStable() async throws {
        registerTestUnits()
        let plugin = try await HostedPlugin.load(PluginID(type: "aufx", subtype: "PlFx", manufacturer: "Plug"))
        try plugin.configure(sampleRate: 48_000, maxFrames: 4096)
        let state = try plugin.fullState()
        #expect(try plugin.fullState() == state)
        try plugin.restore(state)
        #expect(try plugin.fullState() == state)
    }
}
