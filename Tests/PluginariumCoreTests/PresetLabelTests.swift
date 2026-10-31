import Foundation
import Testing
@testable import PluginariumCore

struct PresetLabelTests {
    private let plugin = PluginSlot.fixture().plugin
    private let bright = Data([1])
    private let dark = Data([2])

    private func slot(preset: String? = nil, state: Data? = nil) -> PluginSlot {
        PluginSlot(plugin: plugin, displayName: "Test Plugin", presetName: preset, state: state)
    }

    private func stored(_ name: String, state: Data) -> [Preset] {
        [Preset(name: name, plugin: plugin, state: state)]
    }

    @Test func noPresetAndNoStateIsTheDefaultSound() {
        #expect(PresetLabel.text(for: slot(), saved: []) == "Default sound")
    }

    @Test func noPresetWithStateIsACustomSound() {
        #expect(PresetLabel.text(for: slot(state: bright), saved: []) == "Custom sound")
    }

    @Test func aPresetThatMatchesItsStoredStateReadsItsName() {
        #expect(PresetLabel.text(for: slot(preset: "Lead", state: bright), saved: stored("Lead", state: bright)) == "Lead")
    }

    @Test func aPresetThatDiffersFromItsStoredStateIsMarkedChanged() {
        #expect(PresetLabel.text(for: slot(preset: "Lead", state: dark), saved: stored("Lead", state: bright)) == "Lead (changed)")
    }

    @Test func aFactoryPresetIsNeverMarkedChanged() {
        #expect(PresetLabel.text(for: slot(preset: "Hall", state: dark), saved: stored("Lead", state: bright)) == "Hall")
    }

    @Test func aFactoryPresetWaitingForItsPluginIsNotMarkedChanged() {
        #expect(PresetLabel.text(for: slot(preset: "Lead"), saved: stored("Lead", state: bright)) == "Lead")
    }

    @Test func aWindowThatChangedNothingLeavesTheSlotAlone() {
        #expect(PresetLabel.stateAfterWindowClosed(slot: slot(state: bright), opened: bright, closed: bright) == nil)
    }

    @Test func aWindowThatChangedTheSoundGivesTheSlotTheNewState() {
        #expect(PresetLabel.stateAfterWindowClosed(slot: slot(state: bright), opened: bright, closed: dark) == dark)
    }

    @Test func theComparisonIsWithTheSlotNotWithWhatTheWindowOpenedOn() {
        // A preset picked while the window was open changed the slot and the plugin together.
        #expect(PresetLabel.stateAfterWindowClosed(slot: slot(preset: "Lead", state: dark), opened: bright, closed: dark) == nil)
        #expect(PresetLabel.stateAfterWindowClosed(slot: slot(state: dark), opened: bright, closed: bright) == bright)
    }

    @Test func aSlotWithoutStateComparesWithWhatTheWindowOpenedOn() {
        // A plugin always has a state, so a look at the default sound must not read as a new sound.
        #expect(PresetLabel.stateAfterWindowClosed(slot: slot(), opened: bright, closed: bright) == nil)
        #expect(PresetLabel.stateAfterWindowClosed(slot: slot(), opened: bright, closed: dark) == dark)
    }

    @Test func aStateThatCannotBeReadChangesNothing() {
        #expect(PresetLabel.stateAfterWindowClosed(slot: slot(state: bright), opened: bright, closed: nil) == nil)
        #expect(PresetLabel.stateAfterWindowClosed(slot: slot(), opened: nil, closed: dark) == nil)
    }
}
