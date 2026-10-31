import Foundation

/// What a plugin's preset selector reads. Plugins give no signal when their sound changes, so the
/// configuration learns of it when the plugin's window closes.
public enum PresetLabel {

    /// Saving fills the state of every slot, so only `isCustomSound` tells a changed sound from a default one.
    public static func text(for slot: PluginSlot, saved: [Preset]) -> String {
        guard let name = slot.presetName else {
            return slot.isCustomSound ? "Custom sound" : "Default sound"
        }
        guard let state = slot.state, let stored = saved.first(where: { $0.name == name }), state != stored.state else {
            return name
        }
        return "\(name) (changed)"
    }

    /// The state `slot` takes now that its plugin's window has closed on `closed`, or nil if it keeps
    /// the one it has. A slot without a state compares with `opened`, the state the window opened on,
    /// because looking at the default sound does not change it.
    public static func stateAfterWindowClosed(slot: PluginSlot, opened: Data?, closed: Data?) -> Data? {
        guard let closed, let reference = slot.state ?? opened, closed != reference else { return nil }
        return closed
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
