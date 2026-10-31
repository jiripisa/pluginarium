import AudioToolbox
import CRenderCore
import PluginariumCore
import Testing
@testable import PluginariumAudio

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
        // Reading takes the peak, so the next read starts over.
        let next = rig.meters(strip: 0)
        #expect(next.left == 0 && next.right == 0)
    }

    @Test("Meters hold the peak until it is read")
    func metersHoldPeakUntilRead() async throws {
        let rig = Rig()
        rig.install([StripSpec(source: try await instrument(), midiSlot: 0)])
        rig.press(slot: 0)
        _ = rig.render()
        pr_engine_push_midi(rig.engine, 0, 0x80, 60, 0)
        _ = rig.render()
        let held = rig.meters(strip: 0)
        #expect(abs(held.left - 0.25) < tolerance)
        #expect(abs(held.right - 0.25) < tolerance)
        let again = rig.meters(strip: 0)
        #expect(again.left == 0 && again.right == 0)
        _ = rig.render()
        #expect(rig.meters(strip: 0).left == 0)
    }

    @Test("Meters hold the peak of an earlier chunk of a block")
    func metersHoldPeakAcrossChunks() async throws {
        let frames: UInt32 = 256
        let rig = Rig(maxFrames: 64)
        rig.install([StripSpec(source: try await gain(), audioIn: PRChannels(left: 0, right: -1))])
        let ramp = (0..<Int(frames)).map { 0.8 * (1 - Float($0) / Float(frames)) }
        _ = rig.render(frames: frames, input: [ramp])
        let meters = rig.meters(strip: 0)
        // The first sample is the highest: 0.8 through a gain of 0.5.
        #expect(abs(meters.left - 0.4) < tolerance)
        #expect(abs(meters.right - 0.4) < tolerance)
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

    @Test("The failed install value is never taken, running or not")
    func failedInstallIsNeverTaken() {
        let rig = Rig()
        rig.install([])
        #expect(!rig.isTaken(UInt64.max))

        pr_engine_set_audio_running(rig.engine, true)
        #expect(!rig.isTaken(UInt64.max))
        _ = rig.render()
        #expect(!rig.isTaken(UInt64.max))

        pr_engine_set_audio_running(rig.engine, false)
        #expect(!rig.isTaken(UInt64.max))
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

    @Test("A rewind waits for the render thread, and the next block starts from zero")
    func rewindTakesEffectAtTheNextBlock() async throws {
        let plugin = try await loadPlugin(type: "aumu", subtype: "PlTp")
        let rig = Rig()
        #expect(pr_install_host_callbacks(plugin.audioUnit, rig.engine) == noErr)
        rig.install([StripSpec(source: plugin)])
        pr_engine_set_transport(rig.engine, 120, true)
        for _ in 0..<100 { _ = rig.render() }

        pr_engine_rewind_transport(rig.engine)
        #expect(try transport(of: rig).sample == Double(blockFrames) * 100)

        expectLevel(rig.render()[1], 0)
        let rewound = try transport(of: rig)
        #expect(rewound.sample == Double(blockFrames))
        #expect(rewound.changed == true)

        expectLevel(rig.render()[1], Float(blockFrames) * 2 / Float(sampleRate))
        #expect(try transport(of: rig).changed == false)
    }

    @Test("A rewind while stopped leaves the next start at zero")
    func rewindWhileStopped() async throws {
        let plugin = try await loadPlugin(type: "aumu", subtype: "PlTp")
        let rig = Rig()
        #expect(pr_install_host_callbacks(plugin.audioUnit, rig.engine) == noErr)
        rig.install([StripSpec(source: plugin)])
        pr_engine_set_transport(rig.engine, 120, true)
        for _ in 0..<100 { _ = rig.render() }
        pr_engine_set_transport(rig.engine, 120, false)
        _ = rig.render()

        pr_engine_rewind_transport(rig.engine)
        expectLevel(rig.render()[1], -1)
        #expect(try transport(of: rig).sample == 0)

        pr_engine_set_transport(rig.engine, 120, true)
        expectLevel(rig.render()[1], 0)
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

/// What a unit reads between blocks. Rendering nothing, it cannot move the transport itself.
private func transport(of rig: Rig) throws -> TransportReading {
    let info = pr_host_callback_info(rig.engine)
    let read = try #require(info.transportStateProc)
    var state = TransportReading()
    #expect(read(info.hostUserData, &state.playing, &state.changed, &state.sample, &state.cycling, &state.cycleStart, &state.cycleEnd) == noErr)
    return state
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

