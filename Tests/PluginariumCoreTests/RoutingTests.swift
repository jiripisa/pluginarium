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

// MARK: - Defaults that fit the device

private func channel(kind: PluginKind = .instrument, audioIn: AudioChannels? = nil, audioOut: AudioChannels) -> Channel {
    var channel = Channel.fixture(kind: kind)
    channel.audioIn = audioIn
    channel.audioOut = audioOut
    return channel
}

@Test func outputBeyondTheDeviceFallsBackToTheFirstFreePair() {
    let config = Configuration.fixture(channels: [channel(audioOut: .stereo(left: 0, right: 1))])
    let defaults = RoutingDefaults(midiIn: .init(sourceName: "A", channel: .all), audioOut: .stereo(left: 6, right: 7))
    let fitted = defaults.fitting(deviceInputs: 2, deviceOutputs: 4, kind: .instrument, in: config)
    #expect(fitted.audioOut == .stereo(left: 2, right: 3))
    #expect(fitted.midiIn == defaults.midiIn)
}

@Test func twoOutputSpeakersGiveOutOneTwoEvenWhenTaken() {
    let config = Configuration.fixture(channels: [channel(audioOut: .stereo(left: 0, right: 1))])
    let fitted = RoutingDefaults(audioOut: .stereo(left: 2, right: 3)).fitting(deviceInputs: 0, deviceOutputs: 2, kind: .instrument, in: config)
    #expect(fitted.audioOut == .stereo(left: 0, right: 1))
}

@Test func allPairsUsedFallsBackToOutOneTwo() {
    let config = Configuration.fixture(channels: [
        channel(audioOut: .stereo(left: 0, right: 1)), channel(audioOut: .stereo(left: 2, right: 3)),
    ])
    let fitted = RoutingDefaults(audioOut: .stereo(left: 4, right: 5)).fitting(deviceInputs: 0, deviceOutputs: 4, kind: .instrument, in: config)
    #expect(fitted.audioOut == .stereo(left: 0, right: 1))
}

@Test func aMonoOutputOverlappingAPairCountsAsUsed() {
    let config = Configuration.fixture(channels: [channel(audioOut: .mono(1))])
    let fitted = RoutingDefaults(audioOut: .stereo(left: 6, right: 7)).fitting(deviceInputs: 0, deviceOutputs: 4, kind: .instrument, in: config)
    #expect(fitted.audioOut == .stereo(left: 2, right: 3))
}

@Test func inputBeyondTheDeviceFallsBackLikeOutputs() {
    let config = Configuration.fixture(channels: [channel(kind: .effect, audioIn: .stereo(left: 0, right: 1), audioOut: .stereo(left: 0, right: 1))])
    let defaults = RoutingDefaults(audioIn: .stereo(left: 8, right: 9), audioOut: .stereo(left: 10, right: 11))
    let fitted = defaults.fitting(deviceInputs: 4, deviceOutputs: 4, kind: .effect, in: config)
    #expect(fitted.audioIn == .stereo(left: 2, right: 3))
    #expect(fitted.audioOut == .stereo(left: 2, right: 3))
}

@Test func noInputsOnTheDeviceLeavesTheInputAsDefaulted() {
    let defaults = RoutingDefaults(audioIn: .stereo(left: 8, right: 9), audioOut: .stereo(left: 2, right: 3))
    let fitted = defaults.fitting(deviceInputs: 0, deviceOutputs: 4, kind: .effect, in: .fixture())
    #expect(fitted.audioIn == .stereo(left: 8, right: 9))
}

@Test func noDeviceRunningLeavesDefaultsUnchanged() {
    let defaults = RoutingDefaults(audioIn: .stereo(left: 8, right: 9), audioOut: .stereo(left: 10, right: 11))
    #expect(defaults.fitting(deviceInputs: 0, deviceOutputs: 0, kind: .effect, in: .fixture()) == defaults)
}

@Test func aDefaultThatExistsStaysEvenWhenAnotherChannelUsesIt() {
    let config = Configuration.fixture(channels: [channel(audioOut: .stereo(left: 2, right: 3))])
    let defaults = RoutingDefaults(audioOut: .stereo(left: 2, right: 3))
    #expect(defaults.fitting(deviceInputs: 2, deviceOutputs: 8, kind: .instrument, in: config) == defaults)
}

@Test func anInstrumentsAudioInIsLeftAlone() {
    let defaults = RoutingDefaults(audioIn: .stereo(left: 8, right: 9), audioOut: .stereo(left: 2, right: 3))
    #expect(defaults.fitting(deviceInputs: 2, deviceOutputs: 8, kind: .instrument, in: .fixture()).audioIn == defaults.audioIn)
}
