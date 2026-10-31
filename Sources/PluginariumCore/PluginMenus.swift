import Foundation

/// One line of a menu on the panel, `.menu` of `ui-prototype/styles.css`.
public enum MenuEntry<Action> {
    case legend(String)
    case hint(String)
    case separator
    case item(String, action: Action, isCurrent: Bool = false, isEnabled: Bool = true)

    public func map<Other>(_ transform: (Action) -> Other) -> MenuEntry<Other> {
        switch self {
        case .legend(let text): .legend(text)
        case .hint(let text): .hint(text)
        case .separator: .separator
        case .item(let title, let action, let isCurrent, let isEnabled):
            .item(title, action: transform(action), isCurrent: isCurrent, isEnabled: isEnabled)
        }
    }
}

extension MenuEntry: Equatable where Action: Equatable {}
extension MenuEntry: Sendable where Action: Sendable {}


public enum ConfigurationMenuAction: Equatable, Sendable {
    case load(UUID)
    case new
    case saveAs
}

public enum EffectMenuAction: Equatable, Sendable {
    case togglePlugin
    case presets
    case sidechain
    case addParallel(row: Int)
    case moveToSeries
    case remove
}

public enum PresetMenuAction: Equatable, Sendable {
    case saved(Preset)
    case factory(String)
    case save
}

/// What the menus of a plugin hold, `fxMenuHtml`, `presetMenuHtml` and `sidechainMenuHtml` of
/// `ui-prototype/app.js`.
public enum PluginMenus {

    /// `sidechain` is what the plugin's sidechain input reads, nil when it has none. A plugin that
    /// does not run has no window and no sound to pick, but its place in the chain can still change.
    public static func effect(
        rowSize: Int, rowIndex: Int, isOpen: Bool, isHosted: Bool, presetLabel: String, sidechain: String?
    ) -> [MenuEntry<EffectMenuAction>] {
        var entries: [MenuEntry<EffectMenuAction>] = [
            .item(isOpen ? "Close plugin" : "Open plugin", action: .togglePlugin, isEnabled: isHosted),
            .item("Presets: \(presetLabel)", action: .presets, isEnabled: isHosted),
        ]
        if let sidechain { entries.append(.item("Sidechain in: \(sidechain)", action: .sidechain)) }
        entries.append(.separator)
        if rowSize < Channel.maxParallel { entries.append(.item("Add parallel effect", action: .addParallel(row: rowIndex))) }
        if rowSize > 1 { entries.append(.item("Move to series", action: .moveToSeries)) }
        entries.append(.item("Remove", action: .remove))
        return entries
    }

    /// The Default sound is only offered when adding. `current` is the name of the slot's preset.
    public static func presets(saved: [Preset], factory: [String], current: String?) -> [MenuEntry<PresetMenuAction>] {
        var entries: [MenuEntry<PresetMenuAction>] = [.legend("My presets")]
        if saved.isEmpty {
            entries.append(.hint("None saved yet"))
        } else {
            entries += saved.map { .item($0.name, action: .saved($0), isCurrent: $0.name == current) }
        }
        entries.append(.separator)
        if factory.isEmpty {
            entries.append(.hint("This plugin keeps its factory sounds in its own window. Open it, choose a sound and save it here."))
        } else {
            entries.append(.legend("Factory presets"))
            entries += factory.map { .item($0, action: .factory($0), isCurrent: $0 == current) }
            entries.append(.separator)
        }
        entries.append(.item("Save as preset", action: .save))
        return entries
    }

    /// The configurations to load, the current one marked, then New configuration and Save as.
    public static func configurations(_ configurations: [Configuration], current: UUID?) -> [MenuEntry<ConfigurationMenuAction>] {
        [.legend("Load configuration")]
            + configurations.map { .item($0.name, action: .load($0.id), isCurrent: $0.id == current) }
            + [.separator, .item("New configuration", action: .new), .item("Save as", action: .saveAs)]
    }

    /// Off, then the device's inputs. A sidechain the configuration holds stays listed.
    public static func sidechain(deviceInputs: Int, current: AudioChannels?) -> [MenuEntry<AudioChannels?>] {
        let options = ChannelOptions.inputs(deviceInputs: deviceInputs, allowsOff: true, current: current)
        return [.legend("Sidechain in")] + options.map { .item($0.label, action: $0.value, isCurrent: $0.value == current) }
    }
}
