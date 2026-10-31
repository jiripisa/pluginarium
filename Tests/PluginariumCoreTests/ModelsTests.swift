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

    @Test func followStartStopStartsOffOnAnInstrument() {
        #expect(!Channel.fixture(kind: .instrument).followsTransport)
        #expect(!Channel.fixture(kind: PluginKind(auType: "aumf")!).followsTransport)
    }

    @Test func followStartStopStartsOnOnAnEffect() {
        #expect(Channel.fixture(kind: .effect).followsTransport)
        #expect(Channel.fixture(kind: PluginKind(auType: "aufx")!).followsTransport)
        #expect(InsertEffect.fixture().followsTransport)
    }

    @Test func theSwitchOverridesTheDefault() {
        var instrument = Channel.fixture(kind: .instrument)
        instrument.slot.followsTransport = true
        #expect(instrument.followsTransport)

        var standalone = Channel.fixture(kind: .effect)
        standalone.slot.followsTransport = false
        #expect(!standalone.followsTransport)

        var effect = InsertEffect.fixture()
        effect.slot.followsTransport = false
        #expect(!effect.followsTransport)
    }

    @Test func aSlotFromAnOlderFileTakesTheDefault() throws {
        let json = #"{"plugin":{"type":"aufx","subtype":"test","manufacturer":"Test"},"displayName":"Old"}"#
        let slot = try JSONDecoder().decode(PluginSlot.self, from: Data(json.utf8))
        #expect(slot.followsTransport == nil)
    }

    @Test(arguments: [true, false])
    func theSwitchSurvivesTheFile(follows: Bool) throws {
        var slot = PluginSlot.fixture()
        slot.followsTransport = follows
        let again = try JSONDecoder().decode(PluginSlot.self, from: JSONEncoder().encode(slot))
        #expect(again == slot)
    }

    @Test func aSlotOnTheDefaultWritesNoSwitch() throws {
        let file = String(decoding: try JSONEncoder().encode(PluginSlot.fixture()), as: UTF8.self)
        #expect(!file.contains("followsTransport"))
    }
}
