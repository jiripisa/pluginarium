import Testing
@testable import PluginariumCore

@Suite struct ClockTrackerTests {
    @Test func tempoFromTicks() {
        var tracker = ClockTracker()
        let interval = 60.0 / 124.0 / 24.0
        for tick in 0..<48 { tracker.receive(.clock, at: Double(tick) * interval) }
        #expect(abs((tracker.reading.tempo ?? 0) - 124) < 0.1)
    }

    @Test func clockStopsAfterOneSecondOfSilence() {
        var tracker = ClockTracker()
        #expect(!tracker.isClockRunning(at: 0))
        tracker.receive(.clock, at: 0)
        #expect(tracker.isClockRunning(at: 0.5))
        #expect(tracker.isClockRunning(at: 1.0))
        #expect(!tracker.isClockRunning(at: 1.1))
    }

    @Test func tempoStartsUnknownAndKeepsItsLastValue() {
        #expect(ClockTracker().reading.tempo == nil)
        var tracker = ClockTracker()
        let interval = 60.0 / 124.0 / 24.0
        for tick in 0..<30 { tracker.receive(.clock, at: Double(tick) * interval) }
        #expect(abs((tracker.reading.tempo ?? 0) - 124) < 0.1)
    }

    @Test func singleTickGivesNoTempo() {
        var tracker = ClockTracker()
        tracker.receive(.clock, at: 0)
        #expect(tracker.reading.tempo == nil)
    }

    @Test func gapDiscardsHistoryButKeepsLastTempo() {
        var tracker = ClockTracker()
        let fast = 60.0 / 120.0 / 24.0
        for tick in 0..<10 { tracker.receive(.clock, at: Double(tick) * fast) }
        // Pause of 5 seconds, then a new tick: the pause must not skew the mean.
        tracker.receive(.clock, at: 5)
        #expect(abs((tracker.reading.tempo ?? 0) - 120) < 0.1)
        let slow = 60.0 / 90.0 / 24.0
        for tick in 1..<10 { tracker.receive(.clock, at: 5 + Double(tick) * slow) }
        #expect(abs((tracker.reading.tempo ?? 0) - 90) < 0.1)
    }

    @Test func tempoUsesOnlyLastTwentyFourIntervals() {
        var tracker = ClockTracker()
        let slow = 60.0 / 60.0 / 24.0
        var time = 0.0
        for _ in 0..<10 { tracker.receive(.clock, at: time); time += slow }
        let fast = 60.0 / 150.0 / 24.0
        for _ in 0..<100 { tracker.receive(.clock, at: time); time += fast }
        #expect(abs((tracker.reading.tempo ?? 0) - 150) < 0.1)
    }

    @Test func transportFollowsStartStopContinue() {
        var tracker = ClockTracker()
        #expect(!tracker.isPlaying)
        tracker.receive(.start, at: 0)
        #expect(tracker.isPlaying)
        tracker.receive(.stop, at: 1)
        #expect(!tracker.isPlaying)
        tracker.receive(.resume, at: 2)
        #expect(tracker.isPlaying)
    }

    @Test func aNewTrackerReadsAsNothingKnown() {
        let reading = ClockTracker().reading
        #expect(reading.tempo == nil)
        #expect(!reading.isPlaying)
        #expect(!reading.isClockRunning(at: 0))
    }

    @Test func aReadingHasNoTempoUntilTwoTicksGiveOne() {
        var tracker = ClockTracker()
        let interval = 60.0 / 124.0 / 24.0
        tracker.receive(.clock, at: 0)
        #expect(tracker.reading.tempo == nil)
        tracker.receive(.clock, at: interval)
        #expect(abs((tracker.reading.tempo ?? 0) - 124) < 0.1)
    }

    @Test func aReadingKeepsTheTempoThroughAGap() {
        var tracker = ClockTracker()
        let interval = 60.0 / 124.0 / 24.0
        for tick in 0..<10 { tracker.receive(.clock, at: Double(tick) * interval) }
        tracker.receive(.clock, at: 5)
        #expect(abs((tracker.reading.tempo ?? 0) - 124) < 0.1)
    }

    @Test func aReadingAnswersAsTheTrackerDid() {
        var tracker = ClockTracker()
        tracker.receive(.start, at: 0)
        tracker.receive(.clock, at: 0)
        let reading = tracker.reading
        #expect(reading.isPlaying)
        #expect(reading.isClockRunning(at: 1.0))
        #expect(!reading.isClockRunning(at: 1.1))
    }

    @Test func aReadingStaysAsItWasWhenTheTrackerMovesOn() {
        var tracker = ClockTracker()
        tracker.receive(.clock, at: 0)
        let reading = tracker.reading
        tracker.receive(.clock, at: 5)
        tracker.receive(.start, at: 5)
        #expect(!reading.isPlaying)
        #expect(!reading.isClockRunning(at: 5))
    }

    @Test func onlyTheEventRightAfterAStartReadsAsJustStarted() {
        var tracker = ClockTracker()
        #expect(!tracker.reading.justStarted)
        tracker.receive(.start, at: 0)
        #expect(tracker.reading.justStarted)
        tracker.receive(.clock, at: 0.02)
        #expect(!tracker.reading.justStarted)
    }

    @Test func aContinueIsNotAStart() {
        var tracker = ClockTracker()
        tracker.receive(.stop, at: 0)
        tracker.receive(.resume, at: 1)
        #expect(tracker.isPlaying)
        #expect(!tracker.reading.justStarted)
    }

    @Test func aStartWhilePlayingStartsAgain() {
        var tracker = ClockTracker()
        tracker.receive(.start, at: 0)
        tracker.receive(.clock, at: 0.02)
        tracker.receive(.start, at: 0.04)
        #expect(tracker.reading.justStarted)
    }

    @Test func aStopAfterAStartClearsIt() {
        var tracker = ClockTracker()
        tracker.receive(.start, at: 0)
        tracker.receive(.stop, at: 1)
        #expect(!tracker.reading.justStarted)
    }

    @Test func aPlayingTransportIsStrandedASecondAfterTheLastTick() {
        var tracker = ClockTracker()
        tracker.receive(.start, at: 0)
        tracker.receive(.clock, at: 5)
        #expect(!tracker.reading.isStranded(at: 6.0))
        #expect(tracker.reading.isStranded(at: 6.1))
    }

    @Test(arguments: [MIDIEvent.start, .resume])
    func aStartIsHeardEvenWhenTheLastTickIsOld(event: MIDIEvent) {
        var tracker = ClockTracker()
        tracker.receive(.clock, at: 0)
        tracker.receive(event, at: 10)
        #expect(!tracker.reading.isClockRunning(at: 10))
        #expect(!tracker.reading.isStranded(at: 11.0))
        #expect(tracker.reading.isStranded(at: 11.1))
    }

    @Test func aStartThatNeverGetsATickIsStranded() {
        var tracker = ClockTracker()
        tracker.receive(.start, at: 0)
        #expect(!tracker.reading.isStranded(at: 1.0))
        #expect(tracker.reading.isStranded(at: 1.1))
    }

    @Test func aStoppedTransportIsNeverStranded() {
        var tracker = ClockTracker()
        #expect(!tracker.reading.isStranded(at: 100))
        tracker.receive(.start, at: 0)
        tracker.receive(.clock, at: 0)
        tracker.receive(.stop, at: 0.5)
        #expect(!tracker.reading.isStranded(at: 100))
    }

    @Test func aStopLeavesATickThatComesLaterStopped() {
        var tracker = ClockTracker()
        tracker.receive(.start, at: 0)
        tracker.receive(.stop, at: 5)
        tracker.receive(.clock, at: 6)
        #expect(!tracker.isPlaying)
    }

    @Test func channelVoiceEventsAreIgnored() {
        var tracker = ClockTracker()
        tracker.receive(.channelVoice(status: 0x90, data1: 60, data2: 100), at: 0)
        #expect(!tracker.isClockRunning(at: 0))
        #expect(!tracker.isPlaying)
    }
}
