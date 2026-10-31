import Foundation
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

    @Test func aSlotFromAnOlderFileIsNotACustomSound() throws {
        let json = #"{"plugin":{"type":"aufx","subtype":"test","manufacturer":"Test"},"displayName":"Old","state":"AQ=="}"#
        let slot = try JSONDecoder().decode(PluginSlot.self, from: Data(json.utf8))
        #expect(!slot.isCustomSound && slot.state == Data([1]))
    }

    @Test func aCustomSoundSurvivesTheFile() throws {
        var slot = PluginSlot.fixture()
        slot.isCustomSound = true
        let again = try JSONDecoder().decode(PluginSlot.self, from: JSONEncoder().encode(slot))
        #expect(again == slot)
    }
}
