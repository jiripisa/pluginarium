import Foundation
import Testing
@testable import PluginariumCore

struct PluginMenusTests {
    private let plugin = PluginSlot.fixture().plugin

    private func titles<Action>(_ entries: [MenuEntry<Action>]) -> [String] {
        entries.map { entry in
            switch entry {
            case .legend(let text): "legend: \(text)"
            case .hint(let text): "hint: \(text)"
            case .separator: "---"
            case .item(let title, _, _, _): title
            }
        }
    }

    private func effectMenu(
        rowSize: Int = 1, rowIndex: Int = 0, isOpen: Bool = false, isHosted: Bool = true, sidechain: String? = nil
    ) -> [MenuEntry<EffectMenuAction>] {
        PluginMenus.effect(
            rowSize: rowSize, rowIndex: rowIndex, isOpen: isOpen, isHosted: isHosted, presetLabel: "Default sound", sidechain: sidechain
        )
    }

    private func isEnabled<Action>(_ title: String, in entries: [MenuEntry<Action>]) -> Bool? {
        for case .item(let name, _, _, let enabled) in entries where name == title { return enabled }
        return nil
    }

    @Test func anEffectAloneInItsRowCanGoParallelButNotToSeries() {
        #expect(titles(effectMenu()) == ["Open plugin", "Presets: Default sound", "---", "Add parallel effect", "Remove"])
    }

    @Test func anOpenWindowOffersToCloseIt() {
        #expect(titles(effectMenu(isOpen: true)).first == "Close plugin")
    }

    @Test func aRowOfTwoOffersBothWays() {
        #expect(titles(effectMenu(rowSize: 2)) == ["Open plugin", "Presets: Default sound", "---", "Add parallel effect", "Move to series", "Remove"])
    }

    @Test func aFullRowTakesNoMoreEffects() {
        #expect(titles(effectMenu(rowSize: Channel.maxParallel)) == ["Open plugin", "Presets: Default sound", "---", "Move to series", "Remove"])
    }

    @Test func aPluginWithASidechainShowsItsInput() {
        #expect(titles(effectMenu(sidechain: "Off"))[2] == "Sidechain in: Off")
        #expect(titles(effectMenu(sidechain: "In 3–4"))[2] == "Sidechain in: In 3–4")
    }

    @Test func addParallelNamesTheRow() {
        #expect(effectMenu(rowIndex: 4).contains { entry in
            if case .item(_, let action, _, _) = entry { return action == .addParallel(row: 4) }
            return false
        })
    }

    @Test func aPluginThatDoesNotRunCanOnlyBeMovedOrRemoved() {
        let menu = effectMenu(rowSize: 2, isHosted: false, sidechain: "Off")
        #expect(isEnabled("Open plugin", in: menu) == false)
        #expect(isEnabled("Presets: Default sound", in: menu) == false)
        #expect(isEnabled("Sidechain in: Off", in: menu) == true)
        #expect(isEnabled("Add parallel effect", in: menu) == true)
        #expect(isEnabled("Move to series", in: menu) == true)
        #expect(isEnabled("Remove", in: menu) == true)
    }

    @Test func thePresetMenuOfAPluginWithoutFactoryPresetsExplainsWhere() {
        let menu = PluginMenus.presets(saved: [Preset(name: "Lead", plugin: plugin, state: Data())], factory: [], current: "Lead")
        #expect(titles(menu) == [
            "legend: My presets", "Lead", "---",
            "hint: This plugin keeps its factory sounds in its own window. Open it, choose a sound and save it here.",
            "Save as preset",
        ])
    }

    @Test func thePresetMenuListsFactoryPresetsWhenThePluginHasThem() {
        let menu = PluginMenus.presets(saved: [], factory: ["Hall", "Room"], current: "Room")
        #expect(titles(menu) == [
            "legend: My presets", "hint: None saved yet", "---", "legend: Factory presets", "Hall", "Room", "---", "Save as preset",
        ])
    }

    @Test func theCurrentPresetIsMarked() {
        let menu = PluginMenus.presets(saved: [], factory: ["Hall", "Room"], current: "Room")
        let current = menu.compactMap { entry -> String? in
            if case .item(let title, _, true, _) = entry { return title }
            return nil
        }
        #expect(current == ["Room"])
    }

    @Test func picksCarryWhatToApply() {
        let preset = Preset(name: "Lead", plugin: plugin, state: Data([1]))
        let actions = PluginMenus.presets(saved: [preset], factory: ["Hall"], current: nil).compactMap { entry -> PresetMenuAction? in
            if case .item(_, let action, _, _) = entry { return action }
            return nil
        }
        #expect(actions == [.saved(preset), .factory("Hall"), .save])
    }

    @Test func theSidechainMenuHasOffAndTheInputsWithTheCurrentOneMarked() {
        let current = AudioChannels.stereo(left: 2, right: 3)
        let menu = PluginMenus.sidechain(deviceInputs: 4, current: current)
        #expect(titles(menu) == ["legend: Sidechain in", "Off", "In 1", "In 2", "In 3", "In 4", "In 1–2", "In 3–4"])
        #expect(menu.last == .item("In 3–4", action: current, isCurrent: true))
        #expect(menu[1] == .item("Off", action: nil))
    }

    @Test func mappingAMenuKeepsItsShape() {
        let menu = PluginMenus.sidechain(deviceInputs: 1, current: nil).map { entry in entry.map { $0 == nil ? "off" : "on" } }
        #expect(menu == [.legend("Sidechain in"), .item("Off", action: "off", isCurrent: true), .item("In 1", action: "on")])
    }
}
