import Testing
@testable import PluginariumCore

private func twoInstrumentRows() -> AppSettings {
    var settings = AppSettings.defaults
    settings.instrumentPositions = [
        .init(midiIn: .init(sourceName: "A", channel: .channel(1)), audioOut: .stereo(left: 4, right: 5)),
        .init(midiIn: .init(sourceName: "B", channel: .channel(2)), audioOut: .stereo(left: 6, right: 7)),
    ]
    return settings
}

@Test func secondInstrumentTakesSecondPosition() {
    let settings = twoInstrumentRows()
    let config = Configuration.fixture(channels: [.fixture(kind: .instrument), .fixture(kind: .effect)])
    #expect(defaultRouting(for: .instrument, in: config, settings: settings).audioOut == .stereo(left: 6, right: 7))
}

@Test func routingBeyondTableReusesLastRow() {
    let settings = twoInstrumentRows()
    let config = Configuration.fixture(channels: [.fixture(), .fixture(), .fixture()])
    let routing = defaultRouting(for: .instrument, in: config, settings: settings)
    #expect(routing.audioOut == .stereo(left: 6, right: 7))
    #expect(routing.midiIn == .init(sourceName: "B", channel: .channel(2)))
}

@Test func effectUsesEffectTable() {
    var settings = AppSettings.defaults
    settings.effectPositions = [
        .init(audioIn: .stereo(left: 8, right: 9), audioOut: .stereo(left: 10, right: 11)),
        .init(audioIn: .stereo(left: 12, right: 13), audioOut: .stereo(left: 14, right: 15)),
    ]
    let config = Configuration.fixture(channels: [.fixture(kind: .instrument), .fixture(kind: .effect)])
    let routing = defaultRouting(for: .effect, in: config, settings: settings)
    #expect(routing.audioIn == .stereo(left: 12, right: 13))
    #expect(routing.audioOut == .stereo(left: 14, right: 15))
    #expect(routing.midiIn == nil)
}

@Test func emptyTablesDoNotCrash() {
    var settings = AppSettings.defaults
    settings.instrumentPositions = []
    settings.effectPositions = []
    let config = Configuration.fixture()
    #expect(defaultRouting(for: .instrument, in: config, settings: settings)
        == RoutingDefaults(midiIn: nil, audioIn: nil, audioOut: .stereo(left: 0, right: 1)))
    #expect(defaultRouting(for: .effect, in: config, settings: settings)
        == RoutingDefaults(midiIn: nil, audioIn: nil, audioOut: nil))
}

@Test func defaultsStayWithinFourteenFifteen() {
    let settings = AppSettings.defaults
    #expect(settings.sampleRate == 48000)
    #expect(settings.bufferFrames == 128)
    #expect(settings.instrumentPositions.first?.audioOut == .stereo(left: 2, right: 3))
    for position in settings.instrumentPositions.map(\.audioOut) + settings.effectPositions.flatMap({ [$0.audioIn, $0.audioOut] }) {
        guard case let .stereo(left, right) = position else { Issue.record("expected stereo"); continue }
        #expect(left >= 0 && right <= 15)
    }
    #expect(!settings.instrumentPositions.isEmpty)
    #expect(!settings.effectPositions.isEmpty)
}

@Test func channelLabelsAreOneBased() {
    #expect(AudioChannels.stereo(left: 14, right: 15).label(prefix: "Out") == "Out 15–16")
    #expect(AudioChannels.stereo(left: 8, right: 9).label(prefix: "In") == "In 9–10")
    #expect(AudioChannels.mono(0).label(prefix: "In") == "In 1")
}
