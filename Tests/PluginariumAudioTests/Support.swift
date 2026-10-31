import AudioToolbox
import CRenderCore
import Foundation
import PluginariumCore
import PluginariumTestUnits
import Synchronization
import Testing
@testable import PluginariumAudio

let sampleRate = 44_100.0
let unitMaxFrames: UInt32 = 512
let blockFrames: UInt32 = 128
let outputChannelCount = 8
let tolerance: Float = 0.001
let noteOn: UInt8 = 0x90

let off = PRChannels(left: -1, right: -1)
let outs01 = PRChannels(left: 0, right: 1)

struct EffectSpec {
    var plugin: HostedPlugin
    var sidechain = off
    var channels: UInt32 = 2
}

struct StripSpec {
    var source: HostedPlugin
    var audioIn = off
    var sidechain = off
    var sourceChannels: UInt32 = 2
    var rows: [[EffectSpec]] = []
    var audioOut = outs01
    var midiSlot: Int32 = -1

    var plugins: [HostedPlugin] { [source] + rows.flatMap { $0.map(\.plugin) } }
}

/// An engine, the C arrays for its graphs, and the plugins those graphs point at.
final class Rig {
    let engine: OpaquePointer
    private var plugins: [HostedPlugin] = []

    init(maxFrames: UInt32 = unitMaxFrames) {
        engine = pr_engine_create(maxFrames, sampleRate)
    }

    deinit {
        pr_engine_destroy(engine)
    }

    @discardableResult
    func install(_ strips: [StripSpec], inputCallbacks: Bool = true) -> UInt64 {
        var generation: UInt64 = 0
        plugins += strips.flatMap(\.plugins)
        if inputCallbacks {
            for plugin in strips.flatMap(\.plugins) {
                #expect(pr_install_input_callbacks(plugin.audioUnit, engine) == noErr)
            }
        }
        let effectLists = strips.flatMap(\.rows).map { row in
            row.map { PREffect(unit: $0.plugin.audioUnit, sidechain: $0.sidechain, channels: $0.channels) }
        }
        withEffects(effectLists) { rows in
            var nextRow = 0
            let cStrips = strips.map { strip in
                defer { nextRow += strip.rows.count }
                return PRStrip(
                    source: strip.source.audioUnit, audioIn: strip.audioIn, sidechain: strip.sidechain,
                    sourceChannels: strip.sourceChannels, rows: rows.baseAddress.map { UnsafePointer($0 + nextRow) },
                    rowCount: UInt32(strip.rows.count), audioOut: strip.audioOut, midiSlot: strip.midiSlot
                )
            }
            generation = pr_engine_install_graph(engine, cStrips, UInt32(cStrips.count))
        }
        return generation
    }

    /// Lets go of every other plugin, which disposes it.
    func retainOnly(_ plugin: HostedPlugin) {
        plugins = [plugin]
    }

    func isTaken(_ generation: UInt64) -> Bool {
        pr_engine_is_generation_taken(engine, generation)
    }

    /// Gives up after a few seconds, so a generation that is never taken fails rather than hangs.
    func waitUntilTaken(_ generation: UInt64) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !isTaken(generation), ContinuousClock.now < deadline { await Task.yield() }
        return isTaken(generation)
    }

    /// Calls `body` with one `PRRow` per list; the pointers are valid only during the call.
    private func withEffects(_ lists: [[PREffect]], _ body: (UnsafeBufferPointer<PRRow>) -> Void) {
        let storage = lists.map { list in
            let pointer = UnsafeMutablePointer<PREffect>.allocate(capacity: max(list.count, 1))
            pointer.initialize(from: list, count: list.count)
            return pointer
        }
        defer { storage.forEach { $0.deallocate() } }
        let rows = zip(storage, lists).map { PRRow(effects: UnsafePointer($0), count: UInt32($1.count)) }
        rows.withUnsafeBufferPointer(body)
    }

    func press(slot: Int32) {
        pr_engine_push_midi(engine, slot, noteOn, 60, 100)
    }

    /// Renders `frames` and returns the output channels. `input` holds one array per device channel.
    func render(frames: UInt32 = blockFrames, input: [[Float]] = []) -> [[Float]] {
        var output = [[Float]](repeating: [Float](repeating: 1, count: Int(frames)), count: outputChannelCount)
        withPointers(input) { inputs in
            withMutablePointers(&output) { outputs in
                pr_engine_render(engine, frames, inputs.baseAddress, UInt32(inputs.count), outputs.baseAddress, UInt32(outputs.count))
            }
        }
        return output
    }

    func meters(strip: UInt32) -> (left: Float, right: Float) {
        var left: Float = -1
        var right: Float = -1
        pr_engine_read_meters(engine, strip, &left, &right)
        return (left, right)
    }
}

func withPointers(_ arrays: [[Float]], _ body: (UnsafeBufferPointer<UnsafePointer<Float>?>) -> Void) {
    let storage = arrays.map { array in
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(array.count, 1))
        pointer.initialize(from: array, count: array.count)
        return pointer
    }
    defer { storage.forEach { $0.deallocate() } }
    storage.map { UnsafePointer($0) as UnsafePointer<Float>? }.withUnsafeBufferPointer(body)
}

func withMutablePointers(_ arrays: inout [[Float]], _ body: (UnsafeBufferPointer<UnsafeMutablePointer<Float>?>) -> Void) {
    let storage = arrays.map { array in
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(array.count, 1))
        pointer.initialize(from: array, count: array.count)
        return pointer
    }
    defer { storage.forEach { $0.deallocate() } }
    storage.map { $0 as UnsafeMutablePointer<Float>? }.withUnsafeBufferPointer(body)
    for index in arrays.indices {
        arrays[index] = Array(UnsafeBufferPointer(start: storage[index], count: arrays[index].count))
    }
}

/// `levels` maps a device input channel to a constant level. Unnamed channels are silent.
func constantInput(_ levels: [Int: Float], frames: UInt32 = blockFrames) -> [[Float]] {
    (0..<8).map { [Float](repeating: levels[$0] ?? 0, count: Int(frames)) }
}

func expectLevel(_ channel: [Float], _ level: Float, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!channel.isEmpty, sourceLocation: sourceLocation)
    let worst = channel.map { abs($0 - level) }.max() ?? 0
    #expect(worst < tolerance, "expected \(level), off by \(worst)", sourceLocation: sourceLocation)
}

func loadPlugin(type: String, subtype: String, manufacturer: String = "Plug", configured: Bool = true) async throws -> HostedPlugin {
    registerTestUnits()
    let plugin = try await HostedPlugin.load(PluginID(type: type, subtype: subtype, manufacturer: manufacturer))
    if configured { try await plugin.configure(sampleRate: sampleRate, maxFrames: unitMaxFrames) }
    return plugin
}

func instrument() async throws -> HostedPlugin { try await loadPlugin(type: "aumu", subtype: "PlIn") }
func gain(configured: Bool = true) async throws -> HostedPlugin {
    try await loadPlugin(type: "aufx", subtype: "PlFx", configured: configured)
}
func sidechainUnit() async throws -> HostedPlugin { try await loadPlugin(type: "aufx", subtype: "PlSc") }
func voice() async throws -> HostedPlugin { try await loadPlugin(type: "aumf", subtype: "PlVo") }

/// The plugin of a unit registered with `registerFollowedUnit`.
func followedUnit(_ subtype: String) -> PluginID {
    registerFollowedUnit(subtype: subtype)
    return PluginID(type: "aufx", subtype: subtype, manufacturer: "Plug")
}

/// The first time a unit of `subtype` went through `step`. Gives up after a few seconds, so a step that
/// never comes fails rather than hangs. Sleeps, so a step queued for the main thread can run.
func lifeEvent(_ step: UnitLifeStep, subtype: String) async -> UnitLifeEvent? {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if let event = unitLifeEvents(subtype: subtype).first(where: { $0.step == step }) { return event }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return nil
}

struct EngineHandle: @unchecked Sendable {
    let engine: OpaquePointer
}

/// Relaxed on purpose: a lock here would order the two threads and hide races from the sanitizer.
final class RenderProgress: Sendable {
    let stop = Atomic<Bool>(false)
    let renders = Atomic<Int>(0)
}

/// Renders blocks of 0.5 in a loop on another thread until `progress.stop` is set.
func startRendering(_ rig: Rig, progress: RenderProgress) -> Task<Void, Never> {
    let handle = EngineHandle(engine: rig.engine)
    return Task.detached {
        let count = Int(blockFrames)
        let input = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { [input, left, right].forEach { $0.deallocate() } }
        input.initialize(repeating: 0.5, count: count)
        let inputs: [UnsafePointer<Float>?] = [UnsafePointer(input), UnsafePointer(input)]
        let outputs: [UnsafeMutablePointer<Float>?] = [left, right]
        while !progress.stop.load(ordering: .relaxed) {
            pr_engine_render(handle.engine, blockFrames, inputs, 2, outputs, 2)
            progress.renders.add(1, ordering: .relaxed)
        }
    }
}
