import AudioToolbox
import AVFoundation
import Synchronization

/// Registers the in-process test Audio Units. Safe to call any number of times, from any thread.
public func registerTestUnits() {
    _ = registration
}

private let registration: Void = {
    func register(_ unitClass: AUAudioUnit.Type, type: OSType, subtype: String, name: String) {
        let description = AudioComponentDescription(
            componentType: type, componentSubType: code(subtype), componentManufacturer: code("Plug"),
            componentFlags: 0, componentFlagsMask: 0
        )
        AUAudioUnit.registerSubclass(unitClass, as: description, name: "Pluginarium: \(name)", version: 1)
    }
    register(TestInstrument.self, type: code("aumu"), subtype: "PlIn", name: "Test Instrument")
    register(TestGain.self, type: code("aufx"), subtype: "PlFx", name: "Test Gain")
    register(TestSidechain.self, type: code("aufx"), subtype: "PlSc", name: "Test Sidechain")
    register(TestVoice.self, type: code("aumf"), subtype: "PlVo", name: "Test Voice")
    register(TestBroken.self, type: code("aufx"), subtype: "PlBd", name: "Test Broken")
}()

private func code(_ string: String) -> OSType {
    string.utf8.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
}

private let defaultFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

/// Shared base: bus layout, scratch input buffers and a pull helper. Subclasses supply the DSP.
private class TestUnit: AUAudioUnit {

    class var inputBusNames: [String] { [] }

    private var inputs: [AUAudioUnitBus] = []
    private var outputs: [AUAudioUnitBus] = []
    private var inputList: AUAudioUnitBusArray!
    private var outputList: AUAudioUnitBusArray!
    /// One scratch buffer list per input bus, allocated in `allocateRenderResources`.
    fileprivate var scratch: [UnsafeMutableAudioBufferListPointer] = []

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        for name in Self.inputBusNames {
            let bus = try AUAudioUnitBus(format: defaultFormat)
            bus.name = name
            inputs.append(bus)
        }
        outputs = [try AUAudioUnitBus(format: defaultFormat)]
        inputList = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: inputs)
        outputList = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: outputs)
        maximumFramesToRender = 4096
    }

    override var inputBusses: AUAudioUnitBusArray { inputList }
    override var outputBusses: AUAudioUnitBusArray { outputList }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let frames = Int(maximumFramesToRender)
        scratch = inputs.map { bus in
            let channels = Int(bus.format.channelCount)
            let list = AudioBufferList.allocate(maximumBuffers: channels)
            for index in 0..<channels {
                list[index] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer.allocate(byteCount: frames * MemoryLayout<Float>.size, alignment: 16)
                )
            }
            return list
        }
    }

    override func deallocateRenderResources() {
        for list in scratch {
            for buffer in list { buffer.mData?.deallocate() }
            list.unsafeMutablePointer.deallocate()
        }
        scratch = []
        super.deallocateRenderResources()
    }
}

/// Pulls input bus `bus` into the unit's scratch buffers and returns them with `frames` valid.
private func pull(
    _ scratch: [UnsafeMutableAudioBufferListPointer], bus: Int, frames: AUAudioFrameCount,
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timestamp: UnsafePointer<AudioTimeStamp>,
    pullBlock: AURenderPullInputBlock?
) -> UnsafeMutableAudioBufferListPointer? {
    guard let pullBlock, bus < scratch.count else { return nil }
    let list = scratch[bus]
    for index in 0..<list.count { list[index].mDataByteSize = frames * UInt32(MemoryLayout<Float>.size) }
    let status = pullBlock(flags, timestamp, frames, bus, list.unsafeMutablePointer)
    return status == noErr ? list : nil
}

/// Writes `gain × main + sideGain × side` (side optional) to the output buffers.
private func mix(
    out: UnsafeMutableAudioBufferListPointer, frames: Int,
    main: UnsafeMutableAudioBufferListPointer?, mainGain: Float,
    side: UnsafeMutableAudioBufferListPointer?, sideGain: Float
) {
    for channel in 0..<out.count {
        guard let dest = out[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
        let mainData = main.flatMap { channel < $0.count ? $0[channel].mData?.assumingMemoryBound(to: Float.self) : nil }
        let sideData = side.flatMap { channel < $0.count ? $0[channel].mData?.assumingMemoryBound(to: Float.self) : nil }
        for frame in 0..<frames {
            dest[frame] = (mainData?[frame] ?? 0) * mainGain + (sideData?[frame] ?? 0) * sideGain
        }
    }
}

/// Shared count of held notes, written by the MIDI block and read by the render block.
private final class HeldNotes: Sendable {
    private let count = Atomic<Int>(0)
    var isHeld: Bool { count.load(ordering: .relaxed) > 0 }

    func handle(status: UInt8, velocity: UInt8) {
        switch status & 0xF0 {
        case 0x90 where velocity > 0:
            count.add(1, ordering: .relaxed)
        case 0x80, 0x90:
            // Never go below zero.
            var current = count.load(ordering: .relaxed)
            while current > 0 {
                let (exchanged, original) = count.compareExchange(expected: current, desired: current - 1, ordering: .relaxed)
                if exchanged { break }
                current = original
            }
        default:
            break
        }
    }
}

/// aumu/PlIn/Plug: constant 0.25 while a note is held.
private final class TestInstrument: TestUnit {
    private let notes = HeldNotes()

    override var scheduleMIDIEventBlock: AUScheduleMIDIEventBlock? {
        let notes = notes
        return { _, _, length, bytes in
            guard length >= 3 else { return }
            notes.handle(status: bytes[0], velocity: bytes[2])
        }
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let notes = notes
        return { _, _, frames, _, output, _, _ in
            let out = UnsafeMutableAudioBufferListPointer(output)
            let level: Float = notes.isHeld ? 0.25 : 0
            for buffer in out {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<Int(frames) { data[frame] = level }
            }
            return noErr
        }
    }
}

/// aufx/PlFx/Plug: input × 0.5.
private final class TestGain: TestUnit {
    override class var inputBusNames: [String] { ["Input"] }

    override var internalRenderBlock: AUInternalRenderBlock {
        return { [unowned self] flags, timestamp, frames, _, output, _, pullBlock in
            let main = pull(scratch, bus: 0, frames: frames, flags: flags, timestamp: timestamp, pullBlock: pullBlock)
            mix(out: UnsafeMutableAudioBufferListPointer(output), frames: Int(frames), main: main, mainGain: 0.5, side: nil, sideGain: 0)
            return noErr
        }
    }
}

/// aufx/PlSc/Plug: main × 0.5 + sidechain × 0.25.
private final class TestSidechain: TestUnit {
    override class var inputBusNames: [String] { ["Input", "Sidechain"] }

    override var internalRenderBlock: AUInternalRenderBlock {
        return { [unowned self] flags, timestamp, frames, _, output, _, pullBlock in
            let main = pull(scratch, bus: 0, frames: frames, flags: flags, timestamp: timestamp, pullBlock: pullBlock)
            let side = pull(scratch, bus: 1, frames: frames, flags: flags, timestamp: timestamp, pullBlock: pullBlock)
            mix(out: UnsafeMutableAudioBufferListPointer(output), frames: Int(frames), main: main, mainGain: 0.5, side: side, sideGain: 0.25)
            return noErr
        }
    }
}

/// aumf/PlVo/Plug: one input bus, accepts MIDI, passes input through.
private final class TestVoice: TestUnit {
    override class var inputBusNames: [String] { ["Input"] }

    override var scheduleMIDIEventBlock: AUScheduleMIDIEventBlock? {
        return { _, _, _, _ in }
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        return { [unowned self] flags, timestamp, frames, _, output, _, pullBlock in
            let main = pull(scratch, bus: 0, frames: frames, flags: flags, timestamp: timestamp, pullBlock: pullBlock)
            mix(out: UnsafeMutableAudioBufferListPointer(output), frames: Int(frames), main: main, mainGain: 1, side: nil, sideGain: 0)
            return noErr
        }
    }
}

/// aufx/PlBd/Plug: always fails to allocate render resources.
private final class TestBroken: TestUnit {
    override class var inputBusNames: [String] { ["Input"] }

    override func allocateRenderResources() throws {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FailedInitialization))
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        return { _, _, _, _, _, _, _ in noErr }
    }
}
