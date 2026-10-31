import Foundation
import Testing
@testable import PluginariumCore

struct EffectChainTests {
    @Test func parallelRowIsCappedAtThree() throws {
        var channel = Channel.fixture(effectRows: [[.fixture()]])
        try channel.addParallel(.fixture(), toRow: 0)
        try channel.addParallel(.fixture(), toRow: 0)
        #expect(throws: ChainError.rowFull) { try channel.addParallel(.fixture(), toRow: 0) }
    }

    @Test func addParallelToMissingRowThrows() {
        var channel = Channel.fixture()
        #expect(throws: ChainError.noSuchRow) { try channel.addParallel(.fixture(), toRow: 0) }
    }

    @Test func addEffectAppendsNewRow() {
        var channel = Channel.fixture(effectRows: [[.fixture()]])
        channel.addEffect(.fixture())
        #expect(channel.effects.map(\.count) == [1, 1])
    }

    @Test func moveToSeriesPlacesEffectInRowBelow() {
        let a = InsertEffect.fixture(), b = InsertEffect.fixture()
        var channel = Channel.fixture(effectRows: [[a, b], [.fixture()]])
        channel.moveToSeries(effectID: b.id)
        #expect(channel.effects.map(\.count) == [1, 1, 1])
        #expect(channel.effects[1][0].id == b.id)
    }

    @Test func moveToSeriesOfLoneEffectOrUnknownIDIsNoOp() {
        let a = InsertEffect.fixture()
        var channel = Channel.fixture(effectRows: [[a]])
        let before = channel
        channel.moveToSeries(effectID: a.id)
        channel.moveToSeries(effectID: UUID())
        #expect(channel == before)
    }

    @Test func removingLastEffectDropsTheRow() {
        let a = InsertEffect.fixture()
        var channel = Channel.fixture(effectRows: [[a]])
        channel.removeEffect(effectID: a.id)
        #expect(channel.effects.isEmpty)
    }

    @Test func removingKeepsOtherRowsInOrder() {
        let a = InsertEffect.fixture(), b = InsertEffect.fixture(), c = InsertEffect.fixture()
        var channel = Channel.fixture(effectRows: [[a], [b], [c]])
        channel.removeEffect(effectID: b.id)
        #expect(channel.effects.map { $0.map(\.id) } == [[a.id], [c.id]])
        channel.removeEffect(effectID: UUID())
        #expect(channel.effects.count == 2)
    }

    @Test func configurationRoundTripsThroughJSON() throws {
        var channel = Channel.fixture(effectRows: [[.fixture()]])
        channel.midiIn = MIDIRoute(sourceName: "Keys", channel: .channel(3))
        channel.audioIn = .mono(2)
        channel.sidechainIn = .stereo(left: 4, right: 5)
        let other = Channel.fixture(kind: .effect)
        let config = Configuration.fixture(channels: [channel, other])
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(Configuration.self, from: data) == config)
    }
}
