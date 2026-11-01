import Foundation

/// What to do when the user leaves the configuration being edited.
public enum LeaveAction: Equatable, Sendable {
    case proceed
    case askToSave
}

/// What happens to the configuration after a preset was saved from one of its plugins.
public enum PresetFollowUp: Equatable, Sendable {
    case askToSaveConfiguration
    case keepWithUnsavedConfiguration
}

/// A configuration being edited, with the rules for unsaved changes.
public struct EditingSession: Sendable {
    public var configuration: Configuration
    public private(set) var isSaved: Bool
    public private(set) var isDirty: Bool

    /// A configuration that was never saved. Nothing is dirty until it is edited.
    public init(new configuration: Configuration) {
        self.configuration = configuration
        isSaved = false
        isDirty = false
    }

    public init(saved configuration: Configuration) {
        self.configuration = configuration
        isSaved = true
        isDirty = false
    }

    /// Applies `change`; the session becomes dirty only when the configuration actually changed.
    public mutating func edit(_ change: (inout Configuration) -> Void) {
        let before = configuration
        change(&configuration)
        if configuration != before {
            isDirty = true
        }
    }

    public mutating func markSaved() {
        isSaved = true
        isDirty = false
    }

    /// A configuration that was never saved must be asked for its name, even if it has one.
    public var needsName: Bool { !isSaved }

    public var leaveAction: LeaveAction { isDirty ? .askToSave : .proceed }

    /// Presets are stored the moment they are saved; only the configuration may still be unsaved.
    public func followUpAfterPresetSaved() -> PresetFollowUp {
        isSaved ? .askToSaveConfiguration : .keepWithUnsavedConfiguration
    }
}
