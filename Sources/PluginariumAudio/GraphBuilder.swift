import AudioToolbox
import CRenderCore
import Foundation
import PluginariumCore

/// A loaded unit as a graph uses it.
struct GraphUnit: Equatable {
    var unit: AudioUnit
    /// The unit's channel count, 1 or 2.
    var channels: UInt32

    init(unit: AudioUnit, channels: UInt32) {
        self.unit = unit
        self.channels = channels
    }

    init(_ plugin: HostedPlugin) {
        self.init(unit: plugin.audioUnit, channels: plugin.channelCount)
    }
}

struct GraphEffect: Equatable {
    var unit: GraphUnit
    var sidechain: AudioChannels?
}

/// One channel as the render core plays it. Holds only what exists on the device.
struct GraphStrip: Equatable {
    var channel: UUID
    var source: GraphUnit
    var audioIn: AudioChannels?
    var sidechain: AudioChannels?
    var rows: [[GraphEffect]]
    var audioOut: AudioChannels
    var midiSlot: Int32?
}

/// Maps channels and their loaded units to what the render core plays.
struct GraphBuilder {
    var deviceInputs: Int
    var deviceOutputs: Int

    /// A channel gets a strip when its unit is loaded and its output exists. `units` holds the
    /// loaded units by channel or effect ID. An effect without a unit is left out, so the signal
    /// passes by it, and an input that does not exist is off.
    func strips(for channels: [Channel], units: [UUID: GraphUnit], midiSlots: [UUID: Int32]) -> [GraphStrip] {
        channels.compactMap { channel in
            guard let source = units[channel.id], exists(channel.audioOut, among: deviceOutputs) else { return nil }
            return GraphStrip(
                channel: channel.id,
                source: source,
                audioIn: existingInput(channel.audioIn),
                sidechain: existingInput(channel.sidechainIn),
                rows: channel.effects.compactMap { row in
                    let effects = row.compactMap { effect in
                        units[effect.id].map { GraphEffect(unit: $0, sidechain: existingInput(effect.sidechainIn)) }
                    }
                    return effects.isEmpty ? nil : effects
                },
                audioOut: channel.audioOut,
                midiSlot: midiSlots[channel.id]
            )
        }
    }

    /// The label of the first route of `channel` that does not exist on the device, output first.
    func missingRoute(of channel: Channel) -> String? {
        if !exists(channel.audioOut, among: deviceOutputs) { return channel.audioOut.label(prefix: "Out") }
        let inputs = [channel.audioIn, channel.sidechainIn] + channel.effects.joined().map(\.sidechainIn)
        return inputs.lazy.compactMap { $0 }.first { !exists($0, among: deviceInputs) }?.label(prefix: "In")
    }

    /// Calls `body` with `strips` in C form. Their row and effect pointers are valid only during
    /// the call, which is as long as `pr_engine_install_graph` needs them.
    static func withCStrips<Result>(_ strips: [GraphStrip], _ body: (UnsafeBufferPointer<PRStrip>) -> Result) -> Result {
        let rowCount = strips.reduce(0) { $0 + $1.rows.count }
        let effectCount = strips.reduce(0) { $0 + $1.rows.joined().count }
        let rows = UnsafeMutablePointer<PRRow>.allocate(capacity: max(rowCount, 1))
        let effects = UnsafeMutablePointer<PREffect>.allocate(capacity: max(effectCount, 1))
        defer {
            rows.deallocate()
            effects.deallocate()
        }

        var nextRow = rows
        var nextEffect = effects
        let cStrips = strips.map { strip in
            let firstRow = nextRow
            for row in strip.rows {
                nextRow.initialize(to: PRRow(effects: nextEffect, count: UInt32(row.count)))
                nextRow += 1
                for effect in row {
                    nextEffect.initialize(
                        to: PREffect(unit: effect.unit.unit, sidechain: cChannels(effect.sidechain), channels: effect.unit.channels)
                    )
                    nextEffect += 1
                }
            }
            return PRStrip(
                source: strip.source.unit,
                audioIn: cChannels(strip.audioIn),
                sidechain: cChannels(strip.sidechain),
                sourceChannels: strip.source.channels,
                rows: firstRow,
                rowCount: UInt32(strip.rows.count),
                audioOut: cChannels(strip.audioOut),
                midiSlot: strip.midiSlot ?? -1
            )
        }
        return cStrips.withUnsafeBufferPointer(body)
    }

    private func existingInput(_ channels: AudioChannels?) -> AudioChannels? {
        channels.flatMap { exists($0, among: deviceInputs) ? $0 : nil }
    }

    private func exists(_ channels: AudioChannels, among count: Int) -> Bool {
        switch channels {
        case .mono(let channel): (0..<count).contains(channel)
        case .stereo(let left, let right): (0..<count).contains(left) && (0..<count).contains(right)
        }
    }

    private static func cChannels(_ channels: AudioChannels?) -> PRChannels {
        switch channels {
        case nil: PRChannels(left: -1, right: -1)
        case .mono(let channel): PRChannels(left: Int32(channel), right: -1)
        case .stereo(let left, let right): PRChannels(left: Int32(left), right: Int32(right))
        }
    }
}
