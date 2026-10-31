import Testing
@testable import PluginariumCore

@Suite("Models")
struct ModelsTests {

    @Test func summaryNamesThePluginOfEachChannel() {
        var first = Channel.fixture()
        first.slot.displayName = "TB-303"
        var second = Channel.fixture(kind: .effect, effectRows: [[.fixture()]])
        second.slot.displayName = "Valhalla Reverb"
        #expect(Configuration.fixture(channels: [first, second]).summary == "TB-303, Valhalla Reverb")
    }

    @Test func summaryOfNoChannelsSaysEmpty() {
        #expect(Configuration.fixture(channels: []).summary == "Empty")
    }
}
