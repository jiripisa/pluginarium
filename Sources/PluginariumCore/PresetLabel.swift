import Foundation

/// What a plugin's preset selector reads. Plugins give no signal when their sound changes, so a
/// plugin window compares the state it opened on with the state it closes on, and the slot keeps
/// the verdict in `isCustomSound`. States are never compared across plugin instances, because a
/// plugin may give itself new identifiers on every load.
public enum PresetLabel {

    /// `isSavedPreset` tells a preset of the user's from a factory preset of the plugin, which is
    /// never marked.
    public static func text(for slot: PluginSlot, isSavedPreset: Bool) -> String {
        guard let name = slot.presetName else {
            return slot.isCustomSound ? "Custom sound" : "Default sound"
        }
        return isSavedPreset && slot.isCustomSound ? "\(name) (changed)" : name
    }
}

/// The state one plugin instance had when its window last opened or was last looked at.
public struct SoundBaseline: Sendable {
    public private(set) var state: Data?

    public init(state: Data?) {
        self.state = state
    }

    /// The state to record if the sound is not the one of the baseline, which then moves to `now`
    /// so a change is noted once. Nil when nothing changed or a state could not be read.
    public mutating func changedState(now: Data?) -> Data? {
        guard let now, let state, !PluginStateComparison.isSameSound(now, state) else { return nil }
        self.state = now
        return now
    }

    /// The plugin was set to a preset, or its view is ready: this is the sound to compare with from now
    /// on. A state that could not be read leaves the baseline where it was.
    public mutating func move(to state: Data?) {
        guard let state else { return }
        self.state = state
    }
}

extension PluginSlot {
    /// The plugin's window showed that the owner changed its sound.
    public mutating func takeChangedSound(_ state: Data) {
        self.state = state
        isCustomSound = true
    }

    /// A preset of the plugin was picked, which ends any custom sound.
    public mutating func takePreset(_ name: String, state: Data) {
        presetName = name
        self.state = state
        isCustomSound = false
    }
}
