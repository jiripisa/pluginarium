import Foundation
import Testing
@testable import PluginariumCore

struct PluginLocationTests {
    private let effect = InsertEffect.fixture()
    private let other = InsertEffect.fixture()

    private func configuration() -> (Configuration, Channel, Channel) {
        let first = Channel.fixture(effectRows: [[effect]])
        let second = Channel.fixture(effectRows: [[other]])
        return (.fixture(channels: [first, second]), first, second)
    }

    @Test func aChannelsPluginIsFoundByChannelAlone() {
        let (configuration, first, _) = configuration()
        #expect(configuration.slot(at: PluginLocation(channel: first.id)) == first.slot)
    }

    @Test func anEffectIsFoundOnlyOnItsOwnChannel() {
        let (configuration, first, second) = configuration()
        #expect(configuration.slot(at: PluginLocation(channel: first.id, effect: effect.id)) == effect.slot)
        #expect(configuration.slot(at: PluginLocation(channel: second.id, effect: effect.id)) == nil)
    }

    @Test func aRemovedChannelTakesItsEffectsWithIt() {
        var (configuration, first, _) = configuration()
        configuration.channels.removeAll { $0.id == first.id }
        #expect(configuration.slot(at: PluginLocation(channel: first.id)) == nil)
        #expect(configuration.slot(at: PluginLocation(channel: first.id, effect: effect.id)) == nil)
    }

    @Test func updatingASlotChangesOnlyThatSlot() {
        var (configuration, first, second) = configuration()
        configuration.updateSlot(at: PluginLocation(channel: first.id, effect: effect.id)) { $0.presetName = "Hall" }
        configuration.updateSlot(at: PluginLocation(channel: second.id)) { $0.presetName = "Lead" }
        #expect(configuration.channels[0].slot.presetName == nil)
        #expect(configuration.channels[0].effects[0][0].slot.presetName == "Hall")
        #expect(configuration.channels[1].slot.presetName == "Lead")
        #expect(configuration.channels[1].effects[0][0].slot.presetName == nil)
    }

    @Test func updatingAPluginThatIsGoneChangesNothing() {
        var (configuration, first, _) = configuration()
        let before = configuration
        configuration.updateSlot(at: PluginLocation(channel: UUID())) { $0.presetName = "Hall" }
        configuration.updateSlot(at: PluginLocation(channel: first.id, effect: UUID())) { $0.presetName = "Hall" }
        #expect(configuration == before)
    }

    @Test func aPluginStaysWhileItsEffectMovesToSeries() {
        var channel = Channel.fixture(effectRows: [[effect, other]])
        let location = PluginLocation(channel: channel.id, effect: other.id)
        channel.moveToSeries(effectID: other.id)
        let configuration = Configuration.fixture(channels: [channel])
        #expect(configuration.holds(other.slot.plugin, at: location))
    }

    @Test func aReplacedPluginIsNoLongerHeld() {
        var (configuration, first, _) = configuration()
        let location = PluginLocation(channel: first.id)
        configuration.channels[0].slot.plugin = PluginID(type: "aumu", subtype: "new", manufacturer: "Test")
        #expect(!configuration.holds(first.slot.plugin, at: location))
    }

    @Test func aRemovedEffectIsNoLongerHeld() {
        var (configuration, first, _) = configuration()
        configuration.channels[0].removeEffect(effectID: effect.id)
        #expect(!configuration.holds(effect.slot.plugin, at: PluginLocation(channel: first.id, effect: effect.id)))
        #expect(configuration.holds(first.slot.plugin, at: PluginLocation(channel: first.id)))
    }

    @Test func aRowIsFoundByItsEffect() {
        let channel = Channel.fixture(effectRows: [[effect], [other]])
        #expect(channel.row(of: other.id) == 1)
        #expect(channel.row(of: UUID()) == nil)
    }
}
