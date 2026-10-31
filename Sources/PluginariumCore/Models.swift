/// Identifies an Audio Unit by its component description, as four-character codes.
public struct PluginID: Hashable, Codable, Sendable {
    public var type: String
    public var subtype: String
    public var manufacturer: String

    public init(type: String, subtype: String, manufacturer: String) {
        self.type = type
        self.subtype = subtype
        self.manufacturer = manufacturer
    }
}

public enum PluginKind: String, Codable, Sendable {
    case instrument
    case effect

    /// `aumu` and `aumf` are instruments, `aufx` is an effect; other types are not hosted.
    public init?(auType: String) {
        switch auType {
        case "aumu", "aumf": self = .instrument
        case "aufx": self = .effect
        default: return nil
        }
    }
}

/// What a plugin needs from its surroundings: MIDI, a main audio input, a sidechain.
public struct PluginCapabilities: Codable, Equatable, Sendable {
    public var acceptsMIDI: Bool
    public var hasAudioIn: Bool
    public var hasSidechain: Bool

    public init(acceptsMIDI: Bool, hasAudioIn: Bool, hasSidechain: Bool) {
        self.acceptsMIDI = acceptsMIDI
        self.hasAudioIn = hasAudioIn
        self.hasSidechain = hasSidechain
    }

    /// A bus is a sidechain when its name contains "side" (case-insensitive) or when it is
    /// the second bus of an effect. Any other bus of an `aumu`/`aumf` is main audio input.
    public static func derive(auType: String, inputBusNames: [String]) -> PluginCapabilities {
        let isEffect = auType == "aufx"
        var hasAudioIn = false
        var hasSidechain = false
        for (index, name) in inputBusNames.enumerated() {
            if name.lowercased().contains("side") || (isEffect && index == 1) {
                hasSidechain = true
            } else {
                hasAudioIn = true
            }
        }
        return PluginCapabilities(
            acceptsMIDI: auType == "aumu" || auType == "aumf",
            hasAudioIn: hasAudioIn,
            hasSidechain: hasSidechain
        )
    }
}

public struct PluginInfo: Codable, Identifiable, Sendable {
    public var id: PluginID
    public var name: String
    public var vendor: String
    public var kind: PluginKind

    public init(id: PluginID, name: String, vendor: String, kind: PluginKind) {
        self.id = id
        self.name = name
        self.vendor = vendor
        self.kind = kind
    }
}
