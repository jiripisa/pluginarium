import Foundation


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

/// Device audio channels, zero-based.
public enum AudioChannels: Codable, Hashable, Sendable {
    case mono(Int)
    case stereo(left: Int, right: Int)
}

/// Which MIDI channel of a source is used: all of them, or one from 1 to 16.
public enum MIDIChannelFilter: Codable, Hashable, Sendable {
    case all
    case channel(Int)
}

public struct MIDIRoute: Codable, Hashable, Sendable {
    public var sourceName: String
    public var channel: MIDIChannelFilter

    public init(sourceName: String, channel: MIDIChannelFilter) {
        self.sourceName = sourceName
        self.channel = channel
    }
}

/// A plugin instance with its display name, preset name and saved state.
public struct PluginSlot: Codable, Equatable, Sendable {
    public var plugin: PluginID
    public var displayName: String
    public var presetName: String?
    public var state: Data?

    public init(plugin: PluginID, displayName: String, presetName: String? = nil, state: Data? = nil) {
        self.plugin = plugin
        self.displayName = displayName
        self.presetName = presetName
        self.state = state
    }
}

public struct InsertEffect: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var slot: PluginSlot
    public var sidechainIn: AudioChannels?

    public init(id: UUID = UUID(), slot: PluginSlot, sidechainIn: AudioChannels? = nil) {
        self.id = id
        self.slot = slot
        self.sidechainIn = sidechainIn
    }
}

public struct Channel: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: PluginKind
    public var slot: PluginSlot
    public var midiIn: MIDIRoute?
    public var audioIn: AudioChannels?
    public var sidechainIn: AudioChannels?
    public var audioOut: AudioChannels
    /// Rows run in series; effects within a row run in parallel.
    public var effects: [[InsertEffect]]

    public init(
        id: UUID = UUID(),
        kind: PluginKind,
        slot: PluginSlot,
        midiIn: MIDIRoute? = nil,
        audioIn: AudioChannels? = nil,
        sidechainIn: AudioChannels? = nil,
        audioOut: AudioChannels,
        effects: [[InsertEffect]] = []
    ) {
        self.id = id
        self.kind = kind
        self.slot = slot
        self.midiIn = midiIn
        self.audioIn = audioIn
        self.sidechainIn = sidechainIn
        self.audioOut = audioOut
        self.effects = effects
    }
}

public struct Configuration: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var channels: [Channel]

    public init(id: UUID = UUID(), name: String, channels: [Channel] = []) {
        self.id = id
        self.name = name
        self.channels = channels
    }
}
