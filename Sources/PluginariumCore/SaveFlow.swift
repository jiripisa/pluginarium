import Foundation

/// The words and rules of saving a configuration, `leaveConfig` and `saveConfig` of
/// `ui-prototype/app.js`.
public enum SaveFlow {

    /// The trimmed name, or nil for one with nothing in it, which cannot be saved.
    public static func name(from text: String) -> String? {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// What Save as starts from; a configuration without a name starts from nothing.
    public static func copyName(of name: String) -> String {
        name.isEmpty ? "" : "\(name) copy"
    }

    public static func question(forConfigurationNamed name: String) -> String {
        "Do you want to save the changes to \(name.isEmpty ? "this new configuration" : name)?"
    }

    /// The channels and effects keep their IDs, since they only have to be unique inside a configuration.
    public static func copy(of configuration: Configuration, named name: String) -> Configuration {
        var copy = configuration
        copy.id = UUID()
        copy.name = name
        return copy
    }

    /// Nil when every plugin could be read.
    public static func unreadableNotice(_ plugins: [String]) -> String? {
        var seen: Set<String> = []
        let names = plugins.filter { seen.insert($0).inserted }
        switch names.count {
        case 0: return nil
        case 1: return "\(names[0]) could not be read, its last saved sound was kept"
        default: return "\(names.joined(separator: ", ")) could not be read, their last saved sounds were kept"
        }
    }

    public static func failureNotice(name: String) -> String { "\(name) could not be saved" }

    public static func savedNotice(name: String) -> String { "\(name) saved" }

    /// What a save writes.
    public struct Prepared {
        public var configuration: Configuration
        /// The plugins whose state could not be read; they keep the state they had.
        public var unreadable: [String]
    }

    /// The configuration to write. `noteChanges` runs before the session is read, because noting a
    /// changed sound edits the session, and the capture has to see that edit. Nil when there is no
    /// session or the name given is empty.
    public static func prepare(
        session: () -> EditingSession?, noteChanges: () -> Void, capture: (Configuration) -> (configuration: Configuration, unreadable: [String]),
        name: String?, asCopy: Bool
    ) -> Prepared? {
        var givenName: String?
        if let name {
            guard let trimmed = Self.name(from: name) else { return nil }
            givenName = trimmed
        }
        noteChanges()
        guard let session = session() else { return nil }
        let captured = capture(session.configuration)
        var configuration = captured.configuration
        if let givenName { configuration.name = givenName }
        if asCopy { configuration = copy(of: configuration, named: configuration.name) }
        return Prepared(configuration: configuration, unreadable: captured.unreadable)
    }
}
