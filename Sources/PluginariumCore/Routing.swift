import Foundation

/// Where the n-th instrument channel listens and plays by default.
public struct InstrumentPosition: Codable, Equatable, Sendable {
    public var midiIn: MIDIRoute?
    public var audioOut: AudioChannels

    public init(midiIn: MIDIRoute?, audioOut: AudioChannels) {
        self.midiIn = midiIn
        self.audioOut = audioOut
    }
}

/// Where the n-th standalone effect channel takes audio from and sends it to by default.
public struct EffectPosition: Codable, Equatable, Sendable {
    public var audioIn: AudioChannels
    public var audioOut: AudioChannels

    public init(audioIn: AudioChannels, audioOut: AudioChannels) {
        self.audioIn = audioIn
        self.audioOut = audioOut
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var audioDeviceUID: String?
    public var sampleRate: Double
    public var bufferFrames: Int
    public var clockSource: String?
    public var instrumentPositions: [InstrumentPosition]
    public var effectPositions: [EffectPosition]
    public var recentPlugins: [PluginID]

    public init(
        audioDeviceUID: String? = nil,
        sampleRate: Double,
        bufferFrames: Int,
        clockSource: String? = nil,
        instrumentPositions: [InstrumentPosition],
        effectPositions: [EffectPosition],
        recentPlugins: [PluginID] = []
    ) {
        self.audioDeviceUID = audioDeviceUID
        self.sampleRate = sampleRate
        self.bufferFrames = bufferFrames
        self.clockSource = clockSource
        self.instrumentPositions = instrumentPositions
        self.effectPositions = effectPositions
        self.recentPlugins = recentPlugins
    }

    private enum CodingKeys: String, CodingKey {
        case audioDeviceUID, sampleRate, bufferFrames, clockSource, instrumentPositions, effectPositions, recentPlugins
    }

    /// A file from before `recentPlugins` has no such key.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        audioDeviceUID = try values.decodeIfPresent(String.self, forKey: .audioDeviceUID)
        sampleRate = try values.decode(Double.self, forKey: .sampleRate)
        bufferFrames = try values.decode(Int.self, forKey: .bufferFrames)
        clockSource = try values.decodeIfPresent(String.self, forKey: .clockSource)
        instrumentPositions = try values.decode([InstrumentPosition].self, forKey: .instrumentPositions)
        effectPositions = try values.decode([EffectPosition].self, forKey: .effectPositions)
        recentPlugins = try values.decodeIfPresent([PluginID].self, forKey: .recentPlugins) ?? []
    }

    /// Zero-based channels. Instruments play on 2-3 upward (7 positions), effects read from 8-9 and
    /// write to 10-11 upward (3 positions); nothing runs past channels 14-15.
    public static let defaults = AppSettings(
        sampleRate: 48000,
        bufferFrames: 128,
        instrumentPositions: stride(from: 2, through: 14, by: 2).map {
            InstrumentPosition(midiIn: nil, audioOut: .stereo(left: $0, right: $0 + 1))
        },
        effectPositions: (0..<4).compactMap { index -> EffectPosition? in
            let audioIn = 8 + 2 * index
            let audioOut = 10 + 2 * index
            guard audioOut + 1 <= 15 else { return nil }
            return EffectPosition(
                audioIn: .stereo(left: audioIn, right: audioIn + 1),
                audioOut: .stereo(left: audioOut, right: audioOut + 1)
            )
        }
    )
}

public struct RoutingDefaults: Equatable {
    public var midiIn: MIDIRoute?
    public var audioIn: AudioChannels?
    public var audioOut: AudioChannels?

    public init(midiIn: MIDIRoute? = nil, audioIn: AudioChannels? = nil, audioOut: AudioChannels? = nil) {
        self.midiIn = midiIn
        self.audioIn = audioIn
        self.audioOut = audioOut
    }
}

/// Routing for the next channel of `kind`: the position after the channels of that kind already
/// in `configuration`. Beyond the table the last row is reused.
public func defaultRouting(for kind: PluginKind, in configuration: Configuration, settings: AppSettings) -> RoutingDefaults {
    let index = configuration.channels.filter { $0.kind == kind }.count
    switch kind {
    case .instrument:
        guard let position = settings.instrumentPositions[clamped: index] else {
            return RoutingDefaults(audioOut: .stereo(left: 0, right: 1))
        }
        return RoutingDefaults(midiIn: position.midiIn, audioOut: position.audioOut)
    case .effect:
        guard let position = settings.effectPositions[clamped: index] else { return RoutingDefaults() }
        return RoutingDefaults(audioIn: position.audioIn, audioOut: position.audioOut)
    }
}

extension RoutingDefaults {
    /// These defaults made to fit the running device, for a new channel of `kind` in `configuration`.
    /// A route the device has stays as it is. One it lacks becomes the first stereo pair of the device
    /// that no channel uses, or else channels 1-2. With no device running (no outputs) nothing changes,
    /// and with no inputs the audio in stays as defaulted, so the field shows the fault.
    public func fitting(deviceInputs: Int, deviceOutputs: Int, kind: PluginKind, in configuration: Configuration) -> RoutingDefaults {
        guard deviceOutputs > 0 else { return self }
        var fitted = self
        if let audioOut, !audioOut.fits(channels: deviceOutputs) {
            fitted.audioOut = Self.freePair(of: deviceOutputs, used: configuration.channels.map(\.audioOut))
        }
        if kind == .effect, deviceInputs > 0, let audioIn, !audioIn.fits(channels: deviceInputs) {
            fitted.audioIn = Self.freePair(of: deviceInputs, used: configuration.channels.compactMap(\.audioIn))
        }
        return fitted
    }

    private static func freePair(of count: Int, used: [AudioChannels]) -> AudioChannels {
        let taken = Set(used.flatMap(\.channels))
        let free = stride(from: 0, to: max(count - 1, 0), by: 2).first { !taken.contains($0) && !taken.contains($0 + 1) }
        return .stereo(left: free ?? 0, right: (free ?? 0) + 1)
    }
}

private extension AudioChannels {
    var channels: [Int] {
        switch self {
        case .mono(let channel): [channel]
        case .stereo(let left, let right): [left, right]
        }
    }

    /// Whether a device with `count` channels has all of these.
    func fits(channels count: Int) -> Bool { channels.allSatisfy { $0 < count } }
}

private extension Array {
    /// The element at `index`, or the last one when `index` is past the end; nil when empty.
    subscript(clamped index: Int) -> Element? {
        isEmpty ? nil : self[Swift.min(index, count - 1)]
    }
}
