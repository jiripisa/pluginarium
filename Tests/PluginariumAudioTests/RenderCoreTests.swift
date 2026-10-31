import AudioToolbox
import CRenderCore
import Foundation
import PluginariumCore
import PluginariumTestUnits
import Synchronization
import Testing
@testable import PluginariumAudio

private let sampleRate = 44_100.0
private let unitMaxFrames: UInt32 = 512
private let blockFrames: UInt32 = 128
private let outputChannelCount = 8
private let tolerance: Float = 0.001
private let noteOn: UInt8 = 0x90

private let off = PRChannels(left: -1, right: -1)
private let outs01 = PRChannels(left: 0, right: 1)

private struct EffectSpec {
    var plugin: HostedPlugin
    var sidechain = off
    var channels: UInt32 = 2
}

private struct StripSpec {
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
private final class Rig {
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

private func withPointers(_ arrays: [[Float]], _ body: (UnsafeBufferPointer<UnsafePointer<Float>?>) -> Void) {
    let storage = arrays.map { array in
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(array.count, 1))
        pointer.initialize(from: array, count: array.count)
        return pointer
    }
    defer { storage.forEach { $0.deallocate() } }
    storage.map { UnsafePointer($0) as UnsafePointer<Float>? }.withUnsafeBufferPointer(body)
}

private func withMutablePointers(_ arrays: inout [[Float]], _ body: (UnsafeBufferPointer<UnsafeMutablePointer<Float>?>) -> Void) {
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
private func constantInput(_ levels: [Int: Float], frames: UInt32 = blockFrames) -> [[Float]] {
    (0..<8).map { [Float](repeating: levels[$0] ?? 0, count: Int(frames)) }
}

private func expectLevel(_ channel: [Float], _ level: Float, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!channel.isEmpty, sourceLocation: sourceLocation)
    let worst = channel.map { abs($0 - level) }.max() ?? 0
    #expect(worst < tolerance, "expected \(level), off by \(worst)", sourceLocation: sourceLocation)
}

private func loadPlugin(type: String, subtype: String, manufacturer: String = "Plug", configured: Bool = true) async throws -> HostedPlugin {
    registerTestUnits()
    let plugin = try await HostedPlugin.load(PluginID(type: type, subtype: subtype, manufacturer: manufacturer))
    if configured { try plugin.configure(sampleRate: sampleRate, maxFrames: unitMaxFrames) }
    return plugin
}

private func instrument() async throws -> HostedPlugin { try await loadPlugin(type: "aumu", subtype: "PlIn") }
private func gain(configured: Bool = true) async throws -> HostedPlugin {
    try await loadPlugin(type: "aufx", subtype: "PlFx", configured: configured)
}
private func sidechainUnit() async throws -> HostedPlugin { try await loadPlugin(type: "aufx", subtype: "PlSc") }
private func voice() async throws -> HostedPlugin { try await loadPlugin(type: "aumf", subtype: "PlVo") }

/// Sets a mono format on every bus and initializes, since `HostedPlugin.configure` prefers stereo.
private func configureMono(_ plugin: HostedPlugin) throws {
    let unit = plugin.audioUnit
    var format = AudioStreamBasicDescription(
        mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
    )
    let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    #expect(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, size) == noErr)
    #expect(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, size) == noErr)
    #expect(AudioUnitInitialize(unit) == noErr)
}

@Suite("Render core")
struct RenderCoreTests {

    /// Builds an engine, installs `strips`, renders one block into 8 output channels.
    /// Strips with a MIDI slot get a held note first, unless `notes` names the slots to press.
    private func renderOnce(strips: [StripSpec], input: [[Float]] = [], notes: [Int32]? = nil) -> [[Float]] {
        let rig = Rig()
        rig.install(strips)
        for slot in notes ?? strips.map(\.midiSlot).filter({ $0 >= 0 }) { rig.press(slot: slot) }
        return rig.render(input: input)
    }

    // MARK: - Routing and mixing

    @Test("Two channels sum on a shared output")
    func twoChannelsSumOnSharedOutput() async throws {
        let strips = [
            StripSpec(source: try await instrument(), midiSlot: 0),
            StripSpec(source: try await instrument(), midiSlot: 1),
        ]
        let output = renderOnce(strips: strips)
        expectLevel(output[0], 0.5)
        expectLevel(output[1], 0.5)
    }

    @Test("Separate outputs stay separate")
    func separateOutputsStaySeparate() async throws {
        let strip = StripSpec(source: try await instrument(), audioOut: PRChannels(left: 2, right: 3), midiSlot: 0)
        let output = renderOnce(strips: [strip])
        expectLevel(output[0], 0)
        expectLevel(output[1], 0)
        expectLevel(output[2], 0.25)
        expectLevel(output[3], 0.25)
    }

    @Test("Series effects multiply")
    func seriesEffectsMultiply() async throws {
        let strip = StripSpec(
            source: try await instrument(),
            rows: [[EffectSpec(plugin: try await gain())], [EffectSpec(plugin: try await gain())]],
            midiSlot: 0
        )
        let output = renderOnce(strips: [strip])
        expectLevel(output[0], 0.0625)
        expectLevel(output[1], 0.0625)
    }

    @Test("Parallel branches sum equally")
    func parallelBranchesSumEqually() async throws {
        let strip = StripSpec(
            source: try await instrument(),
            rows: [[EffectSpec(plugin: try await gain()), EffectSpec(plugin: try await gain())]],
            midiSlot: 0
        )
        let output = renderOnce(strips: [strip])
        expectLevel(output[0], 0.25)
        expectLevel(output[1], 0.25)
    }

    @Test("A parallel row feeds the next row")
    func parallelRowFeedsNextRow() async throws {
        let strip = StripSpec(
            source: try await instrument(),
            rows: [
                [EffectSpec(plugin: try await gain()), EffectSpec(plugin: try await gain()), EffectSpec(plugin: try await gain())],
                [EffectSpec(plugin: try await gain())],
            ],
            midiSlot: 0
        )
        let output = renderOnce(strips: [strip])
        expectLevel(output[0], 0.1875)
        expectLevel(output[1], 0.1875)
    }

    @Test("A standalone effect reads device input")
    func standaloneEffectReadsDeviceInput() async throws {
        let strip = StripSpec(source: try await gain(), audioIn: PRChannels(left: 4, right: 5))
        let output = renderOnce(strips: [strip], input: constantInput([4: 0.8, 5: 0.8]))
        expectLevel(output[0], 0.4)
        expectLevel(output[1], 0.4)
    }

    @Test("A mono input feeds both sides")
    func monoInputFeedsBothSides() async throws {
        let strip = StripSpec(source: try await gain(), audioIn: PRChannels(left: 3, right: -1))
        let output = renderOnce(strips: [strip], input: constantInput([3: 0.6]))
        expectLevel(output[0], 0.3)
        expectLevel(output[1], 0.3)
    }

    @Test("Left and right inputs stay on their sides")
    func stereoInputKeepsSides() async throws {
        let strip = StripSpec(source: try await gain(), audioIn: PRChannels(left: 0, right: 1))
        let output = renderOnce(strips: [strip], input: constantInput([0: 0.8, 1: 0.2]))
        expectLevel(output[0], 0.4)
        expectLevel(output[1], 0.1)
    }

    @Test("An instrument with a main input reads device input")
    func instrumentWithInputReadsDeviceInput() async throws {
        let strip = StripSpec(source: try await voice(), audioIn: PRChannels(left: 2, right: 3))
        let output = renderOnce(strips: [strip], input: constantInput([2: 0.3, 3: 0.3]))
        expectLevel(output[0], 0.3)
        expectLevel(output[1], 0.3)
    }

    @Test("A mono output sums left and right at 0.5 each")
    func monoOutputSumsHalves() async throws {
        let strip = StripSpec(source: try await gain(), audioIn: PRChannels(left: 0, right: 1), audioOut: PRChannels(left: 5, right: -1))
        let output = renderOnce(strips: [strip], input: constantInput([0: 0.8, 1: 0.4]))
        expectLevel(output[5], 0.3)
        expectLevel(output[0], 0)
        expectLevel(output[6], 0)
    }

    @Test("An output that is off stays silent")
    func outputOffIsSilent() async throws {
        let strip = StripSpec(source: try await instrument(), audioOut: off, midiSlot: 0)
        let output = renderOnce(strips: [strip])
        for channel in output { expectLevel(channel, 0) }
    }

    @Test("Channels beyond the device read silence and are not written")
    func channelsBeyondDeviceAreSafe() async throws {
        let beyondInput = StripSpec(source: try await gain(), audioIn: PRChannels(left: 40, right: 41))
        let beyondOutput = StripSpec(
            source: try await instrument(), audioOut: PRChannels(left: 7, right: 100), midiSlot: 0
        )
        let output = renderOnce(strips: [beyondInput, beyondOutput], input: constantInput([0: 1, 1: 1]))
        expectLevel(output[0], 0)
        expectLevel(output[1], 0)
        expectLevel(output[7], 0.25)
    }

    @Test("A block larger than the maximum renders in chunks without losing a sample")
    func largeBlockRendersInChunks() async throws {
        let frames: UInt32 = 1_300
        let rig = Rig()
        rig.install([StripSpec(source: try await gain(), audioIn: PRChannels(left: 0, right: -1))])
        let ramp = (0..<Int(frames)).map { Float($0) / 2_000 }
        let output = rig.render(frames: frames, input: [ramp])
        #expect(output[0].count == Int(frames))
        for index in 0..<Int(frames) {
            #expect(abs(output[0][index] - ramp[index] * 0.5) < tolerance)
        }
        #expect(abs(rig.meters(strip: 0).left - ramp[Int(frames) - 1] * 0.5) < tolerance)
    }

    // MARK: - Sidechain

    @Test("Sidechain reads the chosen input")
    func sidechainReadsChosenInput() async throws {
        let strip = StripSpec(
            source: try await sidechainUnit(), audioIn: PRChannels(left: 0, right: 1), sidechain: PRChannels(left: 2, right: 3)
        )
        let output = renderOnce(strips: [strip], input: constantInput([0: 0.8, 1: 0.8, 2: 0.4, 3: 0.4]))
        expectLevel(output[0], 0.5)
        expectLevel(output[1], 0.5)
    }

    @Test("Sidechain that is off is silence")
    func sidechainOffIsSilence() async throws {
        let strip = StripSpec(source: try await sidechainUnit(), audioIn: PRChannels(left: 0, right: 1))
        let output = renderOnce(strips: [strip], input: constantInput([0: 0.8, 1: 0.8, 2: 0.4, 3: 0.4]))
        expectLevel(output[0], 0.4)
        expectLevel(output[1], 0.4)
    }

    @Test("An insert effect reads its own sidechain input")
    func insertEffectSidechain() async throws {
        let strip = StripSpec(
            source: try await instrument(),
            rows: [[EffectSpec(plugin: try await sidechainUnit(), sidechain: PRChannels(left: 6, right: -1))]],
            midiSlot: 0
        )
        let output = renderOnce(strips: [strip], input: constantInput([6: 0.4]))
        expectLevel(output[0], 0.225)
        expectLevel(output[1], 0.225)
    }

    // MARK: - MIDI

    @Test("MIDI reaches its slot only")
    func midiReachesItsSlotOnly() async throws {
        let strips = [
            StripSpec(source: try await instrument(), audioOut: PRChannels(left: 0, right: 1), midiSlot: 0),
            StripSpec(source: try await instrument(), audioOut: PRChannels(left: 2, right: 3), midiSlot: 1),
        ]
        let output = renderOnce(strips: strips, notes: [0])
        expectLevel(output[0], 0.25)
        expectLevel(output[1], 0.25)
        expectLevel(output[2], 0)
        expectLevel(output[3], 0)
    }

    @Test("A note off stops the note")
    func noteOffStops() async throws {
        let rig = Rig()
        rig.install([StripSpec(source: try await instrument(), midiSlot: 3)])
        rig.press(slot: 3)
        expectLevel(rig.render()[0], 0.25)
        pr_engine_push_midi(rig.engine, 3, 0x80, 60, 0)
        expectLevel(rig.render()[0], 0)
    }

    @Test("Slots out of range and slots with no strip are ignored")
    func strayMIDIIsDropped() async throws {
        let rig = Rig()
        rig.install([StripSpec(source: try await instrument(), midiSlot: 0)])
        rig.press(slot: -1)
        rig.press(slot: 64)
        rig.press(slot: 5)
        expectLevel(rig.render()[0], 0)
    }

    @Test("A full MIDI ring drops the excess and keeps working")
    func midiRingOverflow() async throws {
        let rig = Rig()
        rig.install([StripSpec(source: try await instrument(), midiSlot: 0)])
        for _ in 0..<2_000 { rig.press(slot: 0) }
        expectLevel(rig.render()[0], 0.25)
        // Only 512 note-ons fit, so 512 note-offs end them all.
        for _ in 0..<512 { pr_engine_push_midi(rig.engine, 0, 0x80, 60, 0) }
        expectLevel(rig.render()[0], 0)
    }

    // MARK: - Meters and load

    @Test("Meters report the peak")
    func metersReportPeak() async throws {
        let rig = Rig()
        rig.install([StripSpec(source: try await instrument(), midiSlot: 0)])
        rig.press(slot: 0)
        _ = rig.render()
        let meters = rig.meters(strip: 0)
        #expect(abs(meters.left - 0.25) < tolerance)
        #expect(abs(meters.right - 0.25) < tolerance)
    }

    @Test("Meters follow the last block, not the highest ever")
    func metersFollowLastBlock() async throws {
        let rig = Rig()
        rig.install([StripSpec(source: try await instrument(), midiSlot: 0)])
        rig.press(slot: 0)
        _ = rig.render()
        pr_engine_push_midi(rig.engine, 0, 0x80, 60, 0)
        _ = rig.render()
        #expect(rig.meters(strip: 0).left == 0)
    }

    @Test("Meters of a strip that does not exist read zero")
    func metersOutOfRangeReadZero() async throws {
        let rig = Rig()
        let before = rig.meters(strip: 0)
        #expect(before.left == 0 && before.right == 0)
        rig.install([StripSpec(source: try await instrument(), midiSlot: 0)])
        rig.press(slot: 0)
        _ = rig.render()
        let meters = rig.meters(strip: 1)
        #expect(meters.left == 0 && meters.right == 0)
    }

    @Test("Load is reported after a render")
    func loadIsReported() async throws {
        let rig = Rig()
        #expect(pr_engine_load(rig.engine) == 0)
        rig.install([StripSpec(source: try await instrument(), midiSlot: 0)])
        for _ in 0..<10 { _ = rig.render() }
        #expect(pr_engine_load(rig.engine) > 0)
    }

    // MARK: - Failure and lifecycle

    @Test("A failed source render silences only its strip")
    func failedSourceSilencesOnlyItsStrip() async throws {
        let strips = [
            StripSpec(source: try await gain(configured: false), audioIn: PRChannels(left: 0, right: 1), audioOut: PRChannels(left: 0, right: 1)),
            StripSpec(source: try await instrument(), audioOut: PRChannels(left: 2, right: 3), midiSlot: 0),
        ]
        let output = renderOnce(strips: strips, input: constantInput([0: 0.8, 1: 0.8]))
        expectLevel(output[0], 0)
        expectLevel(output[2], 0.25)
    }

    @Test("A failed effect silences its stage")
    func failedEffectSilencesItsStage() async throws {
        let strip = StripSpec(
            source: try await instrument(),
            rows: [[EffectSpec(plugin: try await gain(configured: false)), EffectSpec(plugin: try await gain())]],
            midiSlot: 0
        )
        let output = renderOnce(strips: [strip])
        expectLevel(output[0], 0.125)
    }

    @Test("A failed effect does not pass on what an earlier stage left in its buffers")
    func failedEffectAfterSeriesIsSilent() async throws {
        let strip = StripSpec(
            source: try await instrument(),
            rows: [[EffectSpec(plugin: try await gain())], [EffectSpec(plugin: try await gain(configured: false))]],
            midiSlot: 0
        )
        expectLevel(renderOnce(strips: [strip])[0], 0)
    }

    @Test("A unit without an input record reads silence")
    func unitWithoutRecordIsSilent() async throws {
        let rig = Rig()
        rig.install([StripSpec(source: try await gain(), audioIn: PRChannels(left: 0, right: 1))], inputCallbacks: false)
        expectLevel(rig.render(input: constantInput([0: 0.8, 1: 0.8]))[0], 0)
    }

    @Test("A strip with no unit is silent and does not stop the others")
    func stripWithoutUnit() async throws {
        let rig = Rig()
        let plugin = try await instrument()
        rig.install([StripSpec(source: plugin, midiSlot: 0)])
        let strips = [
            PRStrip(source: nil, audioIn: off, sidechain: off, sourceChannels: 2, rows: nil, rowCount: 0, audioOut: outs01, midiSlot: 1),
            PRStrip(source: plugin.audioUnit, audioIn: off, sidechain: off, sourceChannels: 2, rows: nil, rowCount: 0, audioOut: outs01, midiSlot: 0),
        ]
        pr_engine_install_graph(rig.engine, strips, 2)
        rig.press(slot: 0)
        rig.press(slot: 1)
        expectLevel(rig.render()[0], 0.25)
    }

    @Test("Installing input callbacks twice is safe")
    func inputCallbacksTwice() async throws {
        let rig = Rig()
        let strip = StripSpec(source: try await gain(), audioIn: PRChannels(left: 0, right: 1))
        rig.install([strip])
        rig.install([strip])
        expectLevel(rig.render(input: constantInput([0: 0.8, 1: 0.8]))[0], 0.4)
    }

    @Test("An engine with no graph renders silence")
    func noGraphIsSilent() {
        let rig = Rig()
        for channel in rig.render() { expectLevel(channel, 0) }
    }

    @Test("A new graph takes over at the next render and the old one can be collected")
    func graphSwap() async throws {
        let rig = Rig()
        let first = StripSpec(source: try await instrument(), audioOut: PRChannels(left: 0, right: 1), midiSlot: 0)
        let second = StripSpec(source: try await gain(), audioIn: PRChannels(left: 4, right: 5), audioOut: PRChannels(left: 2, right: 3))
        rig.install([first])
        rig.press(slot: 0)
        expectLevel(rig.render()[0], 0.25)
        pr_engine_collect_garbage(rig.engine)

        rig.install([second])
        rig.install([first])
        rig.install([second])
        pr_engine_collect_garbage(rig.engine)
        let output = rig.render(input: constantInput([4: 0.6, 5: 0.6]))
        expectLevel(output[0], 0)
        expectLevel(output[2], 0.3)
        pr_engine_collect_garbage(rig.engine)
        pr_engine_collect_garbage(rig.engine)
        expectLevel(rig.render(input: constantInput([4: 0.6, 5: 0.6]))[2], 0.3)
    }

    @Test("Graphs can be swapped and collected while another thread renders")
    func graphSwapWhileRendering() async throws {
        let rig = Rig()
        let strips = [
            StripSpec(source: try await gain(), audioIn: PRChannels(left: 0, right: 1), audioOut: PRChannels(left: 0, right: 1)),
            StripSpec(source: try await gain(), audioIn: PRChannels(left: 0, right: 1), audioOut: PRChannels(left: 2, right: 3)),
        ]
        let progress = RenderProgress()
        let renderer = startRendering(rig, progress: progress)
        for iteration in 0..<300 {
            rig.install(iteration.isMultiple(of: 2) ? strips : [strips[0]])
            pr_engine_collect_garbage(rig.engine)
            // Two renders later the graph installed above has been taken and the previous one retired.
            let target = progress.renders.load(ordering: .relaxed) + 2
            while progress.renders.load(ordering: .relaxed) < target { await Task.yield() }
        }
        progress.stop.store(true, ordering: .relaxed)
        await renderer.value
        #expect(progress.renders.load(ordering: .relaxed) >= 600)
    }

    // MARK: - Graph generations

    @Test("A generation is taken once a render starts with it")
    func generationTakenByRender() {
        let rig = Rig()
        pr_engine_set_audio_running(rig.engine, true)
        let first = rig.install([])
        #expect(!rig.isTaken(first))
        _ = rig.render(frames: 0)
        #expect(!rig.isTaken(first))
        _ = rig.render()
        #expect(rig.isTaken(first))

        let second = rig.install([])
        #expect(second == first + 1)
        #expect(!rig.isTaken(second))
        #expect(rig.isTaken(first))
        _ = rig.render()
        #expect(rig.isTaken(second))
        #expect(!rig.isTaken(second + 1))
    }

    @Test("Taking a generation covers every older one")
    func olderGenerationsAreTaken() {
        let rig = Rig()
        pr_engine_set_audio_running(rig.engine, true)
        let generations = (0..<3).map { _ in rig.install([]) }
        #expect(generations.allSatisfy { !rig.isTaken($0) })
        _ = rig.render()
        #expect(generations.allSatisfy { rig.isTaken($0) })
        #expect(!rig.isTaken(rig.install([])))
    }

    @Test("Every generation counts as taken while audio is not running")
    func allTakenWhileNotRunning() {
        let rig = Rig()
        let generation = rig.install([])
        #expect(rig.isTaken(generation))
        #expect(rig.isTaken(generation + 100))

        pr_engine_set_audio_running(rig.engine, true)
        #expect(!rig.isTaken(generation))
        pr_engine_set_audio_running(rig.engine, false)
        #expect(rig.isTaken(generation))
    }

    @Test("A replaced unit can be disposed once its replacement is taken")
    func replacedUnitDisposedOnceTaken() async throws {
        let strip = { (plugin: HostedPlugin) in StripSpec(source: plugin, audioIn: PRChannels(left: 0, right: 1)) }
        let rig = Rig()
        pr_engine_set_audio_running(rig.engine, true)
        rig.install([strip(try await gain())])
        let progress = RenderProgress()
        let renderer = startRendering(rig, progress: progress)
        for _ in 0..<100 {
            let next = try await gain()
            let generation = rig.install([strip(next)])
            let taken = await rig.waitUntilTaken(generation)
            #expect(taken)
            guard taken else { break }
            rig.retainOnly(next)
            pr_engine_collect_garbage(rig.engine)
        }
        progress.stop.store(true, ordering: .relaxed)
        await renderer.value
        pr_engine_set_audio_running(rig.engine, false)
    }

    // MARK: - Real Audio Units

    @Test("A version 2 effect gets its input and advances each block")
    func appleEffectRenders() async throws {
        // Version 2 units cache a render by sample time, so a frozen time would repeat the first block.
        let delay = try await loadPlugin(type: "aufx", subtype: "dely", manufacturer: "appl")
        AudioUnitSetParameter(delay.audioUnit, kDelayParam_WetDryMix, kAudioUnitScope_Global, 0, 0, 0)
        let rig = Rig()
        rig.install([StripSpec(source: delay, audioIn: PRChannels(left: 0, right: 1))])
        expectLevel(rig.render(input: constantInput([0: 0.8, 1: 0.8]))[0], 0.8)
        expectLevel(rig.render(input: constantInput([0: 0.4, 1: 0.4]))[0], 0.4)
    }

    @Test("A unit that pulls with null buffers gets private copies of its input")
    func nullBufferPull() async throws {
        let pull = { try await loadPlugin(type: "aufx", subtype: "PlNl") }
        let strip = StripSpec(
            source: try await pull(), audioIn: PRChannels(left: 0, right: 1),
            rows: [[EffectSpec(plugin: try await pull()), EffectSpec(plugin: try await pull())]]
        )
        let rig = Rig()
        rig.install([strip])
        let input = constantInput([0: 0.8, 1: 0.4])
        for _ in 0..<2 {
            let output = rig.render(input: input)
            expectLevel(output[0], 0.4)
            expectLevel(output[1], 0.2)
        }
    }

    // MARK: - Mono units

    @Test("A mono unit takes a stereo signal mixed down and feeds both sides")
    func monoUnit() async throws {
        let plugin = try await gain(configured: false)
        try configureMono(plugin)
        let strip = StripSpec(source: plugin, audioIn: PRChannels(left: 0, right: 1), sourceChannels: 1)
        let output = renderOnce(strips: [strip], input: constantInput([0: 0.8, 1: 0.4]))
        expectLevel(output[0], 0.3)
        expectLevel(output[1], 0.3)
    }

    @Test("A mono insert effect keeps both sides of the strip")
    func monoInsert() async throws {
        let plugin = try await gain(configured: false)
        try configureMono(plugin)
        let strip = StripSpec(
            source: try await instrument(), rows: [[EffectSpec(plugin: plugin, channels: 1)]], midiSlot: 0
        )
        let output = renderOnce(strips: [strip])
        expectLevel(output[0], 0.125)
        expectLevel(output[1], 0.125)
    }

    // MARK: - Transport

    @Test("A unit sees the tempo set on the engine")
    func unitSeesTempo() async throws {
        let plugin = try await loadPlugin(type: "aumu", subtype: "PlTp")
        let rig = Rig()
        #expect(pr_install_host_callbacks(plugin.audioUnit, rig.engine) == noErr)
        rig.install([StripSpec(source: plugin)])
        pr_engine_set_transport(rig.engine, 124, true)
        expectLevel(rig.render()[0], 0.124)
    }

    @Test("A unit sees the beat advance while playing and hold while stopped")
    func unitSeesBeatAndTransport() async throws {
        let plugin = try await loadPlugin(type: "aumu", subtype: "PlTp")
        let rig = Rig()
        #expect(pr_install_host_callbacks(plugin.audioUnit, rig.engine) == noErr)
        rig.install([StripSpec(source: plugin)])
        expectLevel(rig.render()[0], 0.12)
        expectLevel(rig.render()[1], -1)

        pr_engine_set_transport(rig.engine, 120, true)
        let beatsPerBlock = Float(blockFrames) * 2 / Float(sampleRate)
        for _ in 0..<500 { _ = rig.render() }
        expectLevel(rig.render()[1], 500 * beatsPerBlock)

        pr_engine_set_transport(rig.engine, 120, false)
        expectLevel(rig.render()[1], -1)
        pr_engine_set_transport(rig.engine, 0, true)
        expectLevel(rig.render()[1], 501 * beatsPerBlock)
        expectLevel(rig.render()[0], 0.12)
    }

    @Test("The legacy transport callback reports the same state as the current one")
    func legacyTransportCallback() throws {
        let rig = Rig()
        let info = pr_host_callback_info(rig.engine)
        let legacy = try #require(info.transportStateProc)
        let current = try #require(info.transportStateProc2)

        func read() -> (legacy: TransportReading, current: TransportReading) {
            var viaLegacy = TransportReading()
            var viaCurrent = TransportReading()
            var recording: DarwinBoolean = true
            #expect(legacy(info.hostUserData, &viaLegacy.playing, &viaLegacy.changed, &viaLegacy.sample, &viaLegacy.cycling, &viaLegacy.cycleStart, &viaLegacy.cycleEnd) == noErr)
            #expect(current(info.hostUserData, &viaCurrent.playing, &recording, &viaCurrent.changed, &viaCurrent.sample, &viaCurrent.cycling, &viaCurrent.cycleStart, &viaCurrent.cycleEnd) == noErr)
            #expect(recording == false)
            return (viaLegacy, viaCurrent)
        }

        pr_engine_set_transport(rig.engine, 120, true)
        _ = rig.render()
        var state = read()
        #expect(state.legacy == state.current)
        #expect(state.legacy == TransportReading(playing: true, changed: true, sample: Double(blockFrames), cycling: false, cycleStart: 0, cycleEnd: 0))

        _ = rig.render()
        state = read()
        #expect(state.legacy == state.current)
        #expect(state.legacy.changed == false)

        pr_engine_set_transport(rig.engine, 120, false)
        _ = rig.render()
        state = read()
        #expect(state.legacy == state.current)
        #expect(state.legacy == TransportReading(playing: false, changed: true, sample: Double(blockFrames) * 2, cycling: false, cycleStart: 0, cycleEnd: 0))
    }
}

/// Starts from values the expected states contradict, so a field left unwritten fails the test.
private struct TransportReading: Equatable {
    var playing: DarwinBoolean = true
    var changed: DarwinBoolean = true
    var sample: Float64 = -1
    var cycling: DarwinBoolean = true
    var cycleStart: Float64 = -1
    var cycleEnd: Float64 = -1
}

private struct EngineHandle: @unchecked Sendable {
    let engine: OpaquePointer
}

/// Relaxed on purpose: a lock here would order the two threads and hide races from the sanitizer.
private final class RenderProgress: Sendable {
    let stop = Atomic<Bool>(false)
    let renders = Atomic<Int>(0)
}

/// Renders blocks of 0.5 in a loop on another thread until `progress.stop` is set.
private func startRendering(_ rig: Rig, progress: RenderProgress) -> Task<Void, Never> {
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
