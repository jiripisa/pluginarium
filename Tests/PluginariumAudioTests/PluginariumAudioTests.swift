import CRenderCore
import Testing

@Suite("PluginariumAudio")
struct PluginariumAudioTests {

    @Test("Render core is linked")
    func renderCoreIsLinked() {
        let engine = pr_engine_create(512, 48_000)
        #expect(engine != nil)
        pr_engine_destroy(engine)
    }
}
