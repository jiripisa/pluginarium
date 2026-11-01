import Foundation

/// The sound picked in the Add dialog.
public enum AddPreset: Equatable, Sendable {
    case defaultSound
    case saved(Preset)
    case factory(String)
}

/// The routing the Add dialog offers for a new channel.
public struct AddRouting: Equatable, Sendable {
    public var midiIn: MIDIRoute?
    public var audioIn: AudioChannels?
    public var sidechainIn: AudioChannels?
    public var audioOut: AudioChannels

    public init(midiIn: MIDIRoute? = nil, audioIn: AudioChannels? = nil, sidechainIn: AudioChannels? = nil, audioOut: AudioChannels) {
        self.midiIn = midiIn
        self.audioIn = audioIn
        self.sidechainIn = sidechainIn
        self.audioOut = audioOut
    }

    /// What a new channel of `kind` starts with: the next position, no audio in for an instrument and no sidechain.
    public init(defaults: RoutingDefaults, kind: PluginKind) {
        self.init(
            midiIn: defaults.midiIn,
            audioIn: kind == .effect ? defaults.audioIn : nil,
            sidechainIn: nil,
            audioOut: defaults.audioOut ?? .stereo(left: 0, right: 1)
        )
    }
}

/// The plugins the Add dialog lists, in the order it shows them.
public struct AddListing: Equatable, Sendable {
    public var recent: [PluginInfo]
    public var others: [PluginInfo]

    public var all: [PluginInfo] { recent + others }
}

extension PluginInfo: Equatable {
    public static func == (lhs: PluginInfo, rhs: PluginInfo) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.vendor == rhs.vendor && lhs.kind == rhs.kind
    }
}

/// The logic of the Add dialog; the view only shows it.
public enum AddPicker {
    public static let recentLimit = 5

    /// Installed plugins of `kind` whose name or vendor contains `query`: the recent ones first, in
    /// recent order, then the rest. A recent plugin that is gone is skipped.
    public static func listing(of plugins: [PluginInfo], kind: PluginKind, query: String, recent: [PluginID]) -> AddListing {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        // Foundation's contains is false for an empty needle.
        let matching = plugins.filter {
            $0.kind == kind && (needle.isEmpty || "\($0.name) \($0.vendor)".lowercased().contains(needle))
        }
        let recentInfos = recent.compactMap { id in matching.first { $0.id == id } }
        let others = matching.filter { info in !recentInfos.contains { $0.id == info.id } }
        return AddListing(recent: recentInfos, others: others)
    }

    /// The plugin stays selected while it is listed, otherwise the first one is.
    public static func selection(keeping current: PluginID?, in listing: AddListing) -> PluginID? {
        if let current, listing.all.contains(where: { $0.id == current }) { return current }
        return listing.all.first?.id
    }

    /// The next (`step` 1) or previous (-1) plugin, wrapping around at the ends.
    public static func moved(from current: PluginID?, by step: Int, in listing: AddListing) -> PluginID? {
        let all = listing.all
        guard !all.isEmpty else { return nil }
        guard let current, let index = all.firstIndex(where: { $0.id == current }) else {
            return step > 0 ? all.first?.id : all.last?.id
        }
        return all[((index + step) % all.count + all.count) % all.count].id
    }

    /// `plugin` in front, once, with at most `recentLimit` plugins.
    public static func recent(adding plugin: PluginID, to recent: [PluginID]) -> [PluginID] {
        Array(([plugin] + recent.filter { $0 != plugin }).prefix(recentLimit))
    }

    // MARK: - Fields

    /// The fields shown for a plugin. Until its capabilities are known: MIDI device, channel and out
    /// for an instrument, and audio in and out for an effect.
    public static func fields(kind: PluginKind, capabilities: PluginCapabilities?) -> ChannelFields {
        if let capabilities { return ChannelFields(kind: kind, capabilities: capabilities) }
        return ChannelFields(midiIn: kind == .instrument, audioIn: kind == .effect, sidechainIn: false)
    }

    // MARK: - Results

    public static func slot(plugin: PluginInfo, preset: AddPreset) -> PluginSlot {
        switch preset {
        case .defaultSound: PluginSlot(plugin: plugin.id, displayName: plugin.name)
        case .saved(let saved): PluginSlot(plugin: plugin.id, displayName: plugin.name, presetName: saved.name, state: saved.state)
        case .factory(let name): PluginSlot(plugin: plugin.id, displayName: plugin.name, presetName: name)
        }
    }

    public static func channel(plugin: PluginInfo, preset: AddPreset, routing: AddRouting, capabilities: PluginCapabilities?) -> Channel {
        let fields = fields(kind: plugin.kind, capabilities: capabilities)
        return Channel(
            kind: plugin.kind,
            slot: slot(plugin: plugin, preset: preset),
            midiIn: fields.midiIn ? routing.midiIn : nil,
            audioIn: fields.audioIn ? routing.audioIn : nil,
            sidechainIn: fields.sidechainIn ? routing.sidechainIn : nil,
            audioOut: routing.audioOut
        )
    }

    /// The channel with a new plugin. It keeps its audio in when the plugin has a main input, and
    /// its sidechain in when the plugin has a sidechain.
    public static func replacing(_ channel: Channel, with plugin: PluginInfo, preset: AddPreset, capabilities: PluginCapabilities?) -> Channel {
        var result = channel
        result.slot = slot(plugin: plugin, preset: preset)
        let fields = capabilities.map { ChannelFields(kind: channel.kind, capabilities: $0) }
        let hasInput = fields?.audioIn ?? (channel.kind == .effect)
        if !hasInput { result.audioIn = nil }
        if !(fields?.sidechainIn ?? false) { result.sidechainIn = nil }
        return result
    }

    /// A new row, or next to the effects of row `row`. A row that is gone or full gets a new row instead.
    public static func insert(_ effect: InsertEffect, into channel: inout Channel, row: Int?) {
        if let row, (try? channel.addParallel(effect, toRow: row)) != nil { return }
        channel.addEffect(effect)
    }
}
