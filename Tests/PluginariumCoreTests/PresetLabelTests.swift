import Foundation
import Testing
@testable import PluginariumCore

struct PresetLabelTests {
    private let plugin = PluginSlot.fixture().plugin
    private let bright = Data([1])
    private let dark = Data([2])

    private func slot(preset: String? = nil, state: Data? = nil, custom: Bool = false) -> PluginSlot {
        PluginSlot(plugin: plugin, displayName: "Test Plugin", presetName: preset, state: state, isCustomSound: custom)
    }

    @Test func noPresetAndNoChangeIsTheDefaultSound() {
        #expect(PresetLabel.text(for: slot(), isSavedPreset: false) == "Default sound")
        #expect(PresetLabel.text(for: slot(state: bright), isSavedPreset: false) == "Default sound")
    }

    @Test func noPresetWithAChangedSoundIsACustomSound() {
        #expect(PresetLabel.text(for: slot(state: bright, custom: true), isSavedPreset: false) == "Custom sound")
    }

    @Test func aSavedPresetReadsItsNameUntilItsSoundChanges() {
        #expect(PresetLabel.text(for: slot(preset: "Lead", state: bright), isSavedPreset: true) == "Lead")
        #expect(PresetLabel.text(for: slot(preset: "Lead", state: dark, custom: true), isSavedPreset: true) == "Lead (changed)")
    }

    @Test func aFactoryPresetIsNeverMarkedChanged() {
        #expect(PresetLabel.text(for: slot(preset: "Hall", state: dark, custom: true), isSavedPreset: false) == "Hall")
    }

    @Test func aSavedPresetFromAnotherInstanceReadsPlainWhateverItsState() {
        // The label never looks at states, so a plugin that renames itself on load does not matter.
        #expect(PresetLabel.text(for: slot(preset: "Lead", state: dark), isSavedPreset: true) == "Lead")
    }

    @Test func aSlotTakingAChangedSoundIsCustom() {
        var changed = slot(preset: "Lead", state: bright)
        changed.takeChangedSound(dark)
        #expect(changed.state == dark && changed.isCustomSound && changed.presetName == "Lead")
    }

    @Test func pickingAPresetEndsTheCustomSound() {
        var picked = slot(state: dark, custom: true)
        picked.takePreset("Lead", state: bright)
        #expect(picked.state == bright && !picked.isCustomSound && picked.presetName == "Lead")
    }

    @Test func openingAndClosingWithoutAChangeIsClean() {
        var baseline = SoundBaseline(state: bright)
        #expect(baseline.changedState(now: bright) == nil)
    }

    @Test func aLoadedStateThatDiffersFromTheRunningOneStaysCleanWhenNothingChanges() {
        // The slot holds the state from disk, the window opened on the running one: only the second counts.
        let loaded = slot(preset: "Lead", state: dark)
        var baseline = SoundBaseline(state: bright)
        #expect(baseline.changedState(now: bright) == nil)
        #expect(PresetLabel.text(for: loaded, isSavedPreset: true) == "Lead")
    }

    @Test func aRealChangeBetweenOpeningAndClosingSetsTheFlag() {
        var changed = slot(preset: "Lead", state: bright)
        var baseline = SoundBaseline(state: bright)
        if let state = baseline.changedState(now: dark) { changed.takeChangedSound(state) }
        #expect(changed.isCustomSound && changed.state == dark)
    }

    @Test func aChangeIsNotedOnce() {
        var baseline = SoundBaseline(state: bright)
        #expect(baseline.changedState(now: dark) == dark)
        #expect(baseline.changedState(now: dark) == nil)
    }

    @Test func movingTheBaselineMakesAPickNotAChange() {
        var baseline = SoundBaseline(state: bright)
        baseline.move(to: dark)
        #expect(baseline.changedState(now: dark) == nil)
    }

    @Test func aStateThatCannotBeReadChangesNothing() {
        var baseline = SoundBaseline(state: bright)
        #expect(baseline.changedState(now: nil) == nil)
        var unknown = SoundBaseline(state: nil)
        #expect(unknown.changedState(now: dark) == nil)
    }
}
