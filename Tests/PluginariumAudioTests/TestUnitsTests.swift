import PluginariumTestUnits
import Testing

@Suite("Test units")
struct TestUnitsTests {

    @Test("The app's units leave out every unit that writes a test signal")
    func appUnitsLeaveOutTestSignals() {
        let subtypes = safeTestUnits.map(\.subtype)
        #expect(!subtypes.isEmpty)
        for signal in ["PlTp", "PlIn", "PlNl", "PlOf"] { #expect(!subtypes.contains(signal)) }
    }

    @Test("A unit the app can load stays silent with no input, even with a note held")
    func appUnitsAreSilentWithoutInput() async throws {
        for unit in safeTestUnits {
            let plugin = try await loadPlugin(type: unit.type, subtype: unit.subtype, configured: false)
            // A unit that refuses to initialize has to stay silent as well.
            try? await plugin.configure(sampleRate: sampleRate, maxFrames: unitMaxFrames)
            let rig = Rig()
            rig.install([StripSpec(source: plugin, midiSlot: 0)])
            rig.press(slot: 0)
            for _ in 0..<3 {
                for channel in rig.render() { expectLevel(channel, 0) }
            }
        }
    }
}
