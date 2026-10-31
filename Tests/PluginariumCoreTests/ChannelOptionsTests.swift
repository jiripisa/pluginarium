import Testing
@testable import PluginariumCore

struct ChannelOptionsTests {
    private func labels<Value>(_ options: [RouteOption<Value>]) -> [String] { options.map(\.label) }

    @Test func inputsListMonoChannelsThenStereoPairs() {
        let options = ChannelOptions.inputs(deviceInputs: 4, allowsOff: false, current: .stereo(left: 0, right: 1))
        #expect(labels(options) == ["In 1", "In 2", "In 3", "In 4", "In 1–2", "In 3–4"])
        #expect(options.last?.value == .stereo(left: 2, right: 3))
    }

    @Test func anOddChannelCountLeavesTheLastOneWithoutAPair() {
        let options = ChannelOptions.inputs(deviceInputs: 3, allowsOff: false, current: .mono(0))
        #expect(labels(options) == ["In 1", "In 2", "In 3", "In 1–2"])
    }

    @Test func offComesFirstWhenAllowed() {
        let options = ChannelOptions.inputs(deviceInputs: 2, allowsOff: true, current: nil)
        #expect(labels(options) == ["Off", "In 1", "In 2", "In 1–2"])
        #expect(options.first?.value == .some(nil))
    }

    @Test func aDeviceWithoutInputsListsOnlyOffAndTheCurrentValue() {
        let current = AudioChannels.stereo(left: 2, right: 3)
        #expect(labels(ChannelOptions.inputs(deviceInputs: 0, allowsOff: true, current: current)) == ["Off", "In 3–4"])
        #expect(labels(ChannelOptions.inputs(deviceInputs: 0, allowsOff: false, current: current)) == ["In 3–4"])
    }

    @Test func aSavedInputBeyondTheDeviceStaysListed() {
        let options = ChannelOptions.inputs(deviceInputs: 2, allowsOff: true, current: .stereo(left: 8, right: 9))
        #expect(labels(options) == ["Off", "In 1", "In 2", "In 1–2", "In 9–10"])
    }

    @Test func anEffectWithoutInputShowsOffUntilOneIsPicked() {
        #expect(labels(ChannelOptions.inputs(deviceInputs: 2, allowsOff: false, current: nil)).first == "Off")
    }

    @Test func outputsListStereoPairsThenMonoChannels() {
        let options = ChannelOptions.outputs(deviceOutputs: 4, current: .stereo(left: 2, right: 3))
        #expect(labels(options) == ["Out 1–2", "Out 3–4", "Out 1", "Out 2", "Out 3", "Out 4"])
    }

    @Test func aSavedOutputBeyondTheDeviceStaysListed() {
        let options = ChannelOptions.outputs(deviceOutputs: 2, current: .stereo(left: 14, right: 15))
        #expect(labels(options) == ["Out 1–2", "Out 1", "Out 2", "Out 15–16"])
    }

    @Test func midiSourcesStartWithNoMIDI() {
        let options = ChannelOptions.midiSources(["Hapax", "KeyLab"], current: nil)
        #expect(labels(options) == ["No MIDI", "Hapax", "KeyLab"])
        #expect(options.first?.value == .some(nil))
        #expect(options[1].value == "Hapax")
    }

    @Test func aMissingSourceIsListedAsNotConnected() {
        let options = ChannelOptions.midiSources(["KeyLab"], current: "Launchpad")
        #expect(labels(options) == ["No MIDI", "KeyLab", "Launchpad (not connected)"])
        #expect(options.last?.value == "Launchpad")
    }

    @Test func midiChannelsAreAllThenOneToSixteen() {
        let options = ChannelOptions.midiChannels
        #expect(options.count == 17)
        #expect(options.first?.label == "All" && options.first?.value == .all)
        #expect(options.last?.label == "16" && options.last?.value == .channel(16))
    }
}
