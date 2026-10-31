import Testing
@testable import PluginariumAudio

@Suite("PluginariumAudio")
struct PluginariumAudioTests {

    @Test("Render core is linked")
    func renderCoreIsLinked() {
        #expect(PluginariumAudio.renderCoreVersion == 1)
    }
}
