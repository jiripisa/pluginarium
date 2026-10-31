import Testing
@testable import PluginariumCore

@Suite struct MIDIEventTests {
    @Test func parsesNoteOnAndClock() {
        #expect(MIDIEvent(ump: 0x2091_3C64) == .channelVoice(status: 0x91, data1: 0x3C, data2: 0x64))
        #expect(MIDIEvent(ump: 0x10F8_0000) == .clock)
    }

    @Test func parsesTransportMessages() {
        #expect(MIDIEvent(ump: 0x10FA_0000) == .start)
        #expect(MIDIEvent(ump: 0x10FB_0000) == .resume)
        #expect(MIDIEvent(ump: 0x10FC_0000) == .stop)
    }

    @Test func ignoresOtherMessages() {
        #expect(MIDIEvent(ump: 0x10FE_0000) == nil)  // active sensing
        #expect(MIDIEvent(ump: 0x3000_0000) == nil)  // SysEx7 message type
        #expect(MIDIEvent(ump: 0x4091_0000) == nil)  // MIDI 2.0 channel voice
        #expect(MIDIEvent(ump: 0x20F8_0000) == nil)  // system status in a type 2 packet
        #expect(MIDIEvent(ump: 0x2010_3C64) == nil)  // status below 0x80
    }

    @Test func filterMatchesOneBasedChannel() {
        #expect(MIDIChannelFilter.channel(2).matches(status: 0x91))
        #expect(!MIDIChannelFilter.channel(1).matches(status: 0x91))
        #expect(MIDIChannelFilter.all.matches(status: 0x9F))
    }

    @Test func filterNeverMatchesSystemStatus() {
        #expect(!MIDIChannelFilter.all.matches(status: 0xF8))
        #expect(!MIDIChannelFilter.channel(9).matches(status: 0xF8))
    }
}
