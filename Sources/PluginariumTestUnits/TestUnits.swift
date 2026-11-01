// Debug builds only, so no test unit is in a release, whatever links this target.
#if DEBUG

import AudioToolbox
import AVFoundation
import Synchronization

/// Registers every test Audio Unit, for tests. Safe to call any number of times, from any thread.
///
/// Some of these write test signals, not audio: `PlTp` writes full-scale DC. Those must never reach a
/// device, so the app calls `registerSafeTestUnits` instead, and nothing else may call this.
public func registerTestUnits() {
    _ = registration
}

/// Registers only the units in `safeTestUnits`, for the app. Safe to call any number of times, from
/// any thread. A process calls this or `registerTestUnits`, never both.
public func registerSafeTestUnits() {
    _ = safeRegistration
}

/// The units the app can load. Each one scales its input, or fails to start, so with nothing coming
/// in it is silent. A unit goes here only if that holds, whatever notes it gets.
public var safeTestUnits: [(type: String, subtype: String)] {
    safeEntries.map { ($0.type, $0.subtype) }
}

/// Registers an effect that works like Test Gain under `subtype` (type aufx, manufacturer Plug). A test
/// that follows a unit's life takes a subtype of its own, so no other test's units show up in it.
public func registerFollowedUnit(subtype: String) {
    register(TestGain.self, type: "aufx", subtype: subtype, name: "Test \(subtype)")
}

/// A step in the life of a test unit that a host has to keep on the main thread.
public enum UnitLifeStep: Sendable {
    case created
    case renderResourcesAllocated
    case renderResourcesDeallocated
    case destroyed
}

public struct UnitLifeEvent: Sendable, Equatable {
    public let step: UnitLifeStep
    public let onMainThread: Bool
}

/// What has happened so far to the units of `subtype`, oldest first.
public func unitLifeEvents(subtype: String) -> [UnitLifeEvent] {
    lifeEvents.withLock { $0[code(subtype)] ?? [] }
}

private let lifeEvents = Mutex<[OSType: [UnitLifeEvent]]>([:])

private func record(_ step: UnitLifeStep, subtype: OSType) {
    let event = UnitLifeEvent(step: step, onMainThread: Thread.isMainThread)
    lifeEvents.withLock { $0[subtype, default: []].append(event) }
}

private func register(_ unitClass: AUAudioUnit.Type, type: String, subtype: String, name: String) {
    let description = AudioComponentDescription(
        componentType: code(type), componentSubType: code(subtype), componentManufacturer: code("Plug"),
        componentFlags: 0, componentFlagsMask: 0
    )
    AUAudioUnit.registerSubclass(unitClass, as: description, name: "Pluginarium: \(name)", version: 1)
}

private struct Entry {
    var unitClass: AUAudioUnit.Type
    var type: String
    var subtype: String
    var name: String
}

private var safeEntries: [Entry] {
    [
        Entry(unitClass: TestGain.self, type: "aufx", subtype: "PlFx", name: "Test Gain"),
        Entry(unitClass: TestSidechain.self, type: "aufx", subtype: "PlSc", name: "Test Sidechain"),
        Entry(unitClass: TestVoice.self, type: "aumf", subtype: "PlVo", name: "Test Voice"),
        Entry(unitClass: TestBroken.self, type: "aufx", subtype: "PlBd", name: "Test Broken"),
        Entry(unitClass: TestMono.self, type: "aufx", subtype: "PlMo", name: "Test Mono"),
    ]
}

/// Constant levels and marker values that tests measure. On a device these are DC, not sound.
private var signalEntries: [Entry] {
    [
        Entry(unitClass: TestInstrument.self, type: "aumu", subtype: "PlIn", name: "Test Instrument"),
        Entry(unitClass: TestTempo.self, type: "aumu", subtype: "PlTp", name: "Test Tempo"),
        Entry(unitClass: TestNullPull.self, type: "aufx", subtype: "PlNl", name: "Test Null Pull"),
        Entry(unitClass: TestAllOff.self, type: "aumu", subtype: "PlOf", name: "Test All Off"),
    ]
}

private func register(_ entries: [Entry]) {
    for entry in entries { register(entry.unitClass, type: entry.type, subtype: entry.subtype, name: entry.name) }
}

private let safeRegistration: Void = register(safeEntries)

private let registration: Void = {
    _ = safeRegistration
    register(signalEntries)
}()

private func code(_ string: String) -> OSType {
    string.utf8.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
}

/// Shared base: bus layout, scratch input buffers and a pull helper. Subclasses supply the DSP.
private class TestUnit: AUAudioUnit {

    class var inputBusNames: [String] { [] }
    class var busChannels: AVAudioChannelCount { 2 }

    private var inputs: [AUAudioUnitBus] = []
    private var outputs: [AUAudioUnitBus] = []
    private var inputList: AUAudioUnitBusArray!
    private var outputList: AUAudioUnitBusArray!
    /// One scratch buffer list per input bus, allocated in `allocateRenderResources`.
    fileprivate var scratch: [UnsafeMutableAudioBufferListPointer] = []
    private let subtype: OSType

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        subtype = componentDescription.componentSubType
        record(.created, subtype: subtype)
        try super.init(componentDescription: componentDescription, options: options)
        let defaultFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: Self.busChannels)!
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

    deinit {
        record(.destroyed, subtype: subtype)
    }

    override var inputBusses: AUAudioUnitBusArray { inputList }
    override var outputBusses: AUAudioUnitBusArray { outputList }

    override func allocateRenderResources() throws {
        record(.renderResourcesAllocated, subtype: subtype)
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
        record(.renderResourcesDeallocated, subtype: subtype)
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

private let allSoundOff: UInt8 = 120
private let allNotesOff: UInt8 = 123

/// Shared count of held notes, written by the MIDI block and read by the render block.
private final class HeldNotes: Sendable {
    private let count = Atomic<Int>(0)
    var isHeld: Bool { count.load(ordering: .relaxed) > 0 }

    func handle(status: UInt8, data1: UInt8, data2: UInt8) {
        switch status & 0xF0 {
        case 0xB0 where data1 == allSoundOff || data1 == allNotesOff:
            count.store(0, ordering: .relaxed)
        case 0x90 where data2 > 0:
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

/// Which MIDI channels have sent each all-off controller, written by the MIDI block and read by the
/// render block.
private final class AllOffChannels: Sendable {
    private let sound = Atomic<UInt16>(0)
    private let notes = Atomic<UInt16>(0)

    var soundCount: Int { sound.load(ordering: .relaxed).nonzeroBitCount }
    var notesCount: Int { notes.load(ordering: .relaxed).nonzeroBitCount }

    func handle(status: UInt8, controller: UInt8) {
        guard status & 0xF0 == 0xB0 else { return }
        let channel = UInt16(1) << (status & 0x0F)
        if controller == allSoundOff { sound.bitwiseOr(channel, ordering: .relaxed) }
        if controller == allNotesOff { notes.bitwiseOr(channel, ordering: .relaxed) }
    }
}

/// aumu/PlOf/Plug: reports the all-off controllers it has had. The first output is the number of
/// MIDI channels that sent All Sound Off ÷ 100, the second the same for All Notes Off.
private final class TestAllOff: TestUnit {
    private let channels = AllOffChannels()

    override var scheduleMIDIEventBlock: AUScheduleMIDIEventBlock? {
        let channels = channels
        return { _, _, length, bytes in
            guard length >= 3 else { return }
            channels.handle(status: bytes[0], controller: bytes[1])
        }
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let channels = channels
        return { _, _, frames, _, output, _, _ in
            let values = [Float(channels.soundCount) / 100, Float(channels.notesCount) / 100]
            for (channel, buffer) in UnsafeMutableAudioBufferListPointer(output).enumerated() {
                guard channel < values.count, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<Int(frames) { data[frame] = values[channel] }
            }
            return noErr
        }
    }
}

/// aumu/PlIn/Plug: constant 0.25 while a note is held. All Sound Off and All Notes Off end every note.
private final class TestInstrument: TestUnit {
    private let notes = HeldNotes()

    override var scheduleMIDIEventBlock: AUScheduleMIDIEventBlock? {
        let notes = notes
        return { _, _, length, bytes in
            guard length >= 3 else { return }
            notes.handle(status: bytes[0], data1: bytes[1], data2: bytes[2])
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

/// aumu/PlTp/Plug: reports what the host tells it. The first output is tempo ÷ 1000, the second
/// is the beat position while the transport moves and -1 while it is stopped.
private final class TestTempo: TestUnit {
    override var internalRenderBlock: AUInternalRenderBlock {
        return { [unowned self] _, _, frames, _, output, _, _ in
            var tempo = 0.0
            var beat = 0.0
            _ = musicalContextBlock?(&tempo, nil, nil, &beat, nil, nil)
            var flags = AUHostTransportStateFlags()
            _ = transportStateBlock?(&flags, nil, nil, nil)
            let values = [Float(tempo / 1000), flags.contains(.moving) ? Float(beat) : -1]
            for (channel, buffer) in UnsafeMutableAudioBufferListPointer(output).enumerated() {
                guard channel < values.count, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<Int(frames) { data[frame] = values[channel] }
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

/// aufx/PlNl/Plug: input × 0.5, pulling with null buffers the way many version 2 units do, then
/// overwriting what it was handed the way an in-place unit may.
private final class TestNullPull: TestUnit {
    override class var inputBusNames: [String] { ["Input"] }

    override var internalRenderBlock: AUInternalRenderBlock {
        return { flags, timestamp, frames, _, output, _, pullBlock in
            let input = AudioBufferList.allocate(maximumBuffers: 2)
            defer { input.unsafeMutablePointer.deallocate() }
            for index in 0..<input.count {
                input[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
            }
            guard let pullBlock, pullBlock(flags, timestamp, frames, 0, input.unsafeMutablePointer) == noErr else {
                return kAudioUnitErr_NoConnection
            }
            mix(out: UnsafeMutableAudioBufferListPointer(output), frames: Int(frames), main: input, mainGain: 0.5, side: nil, sideGain: 0)
            for buffer in input {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<Int(frames) { data[frame] = 9 }
            }
            return noErr
        }
    }
}

/// aufx/PlMo/Plug: input × 0.5, and refuses any format that is not mono.
private final class TestMono: TestUnit {
    override class var inputBusNames: [String] { ["Input"] }
    override class var busChannels: AVAudioChannelCount { 1 }

    override func shouldChange(to format: AVAudioFormat, for bus: AUAudioUnitBus) -> Bool {
        format.channelCount == 1
    }

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

#endif
