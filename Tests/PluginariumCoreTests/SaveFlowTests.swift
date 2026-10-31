import Foundation
import Testing
@testable import PluginariumCore

struct SaveFlowTests {

    @Test func aNameIsTrimmedAndAnEmptyOneIsRefused() {
        #expect(SaveFlow.name(from: "  Night rig \n") == "Night rig")
        #expect(SaveFlow.name(from: "   ") == nil)
        #expect(SaveFlow.name(from: "") == nil)
    }

    @Test func saveAsStartsFromTheNameWithCopyAddedAndFromNothingForANewConfiguration() {
        #expect(SaveFlow.copyName(of: "Night rig") == "Night rig copy")
        #expect(SaveFlow.copyName(of: "") == "")
    }

    @Test func theQuestionNamesTheConfigurationOrCallsItNew() {
        #expect(SaveFlow.question(forConfigurationNamed: "Night rig") == "Do you want to save the changes to Night rig?")
        #expect(SaveFlow.question(forConfigurationNamed: "") == "Do you want to save the changes to this new configuration?")
    }

    @Test func aCopyHasANewIdentityAndKeepsTheChannels() {
        let channel = Channel.fixture()
        let original = Configuration.fixture(name: "Night rig", channels: [channel])
        let copy = SaveFlow.copy(of: original, named: "Night rig copy")
        #expect(copy.id != original.id)
        #expect(copy.name == "Night rig copy")
        #expect(copy.channels == original.channels)
    }

    @Test func unreadablePluginsAreNamedOnce() {
        #expect(SaveFlow.unreadableNotice([]) == nil)
        #expect(SaveFlow.unreadableNotice(["Delay"]) == "Delay could not be read, its last saved sound was kept")
        #expect(SaveFlow.unreadableNotice(["Delay", "Reverb", "Delay"]) == "Delay, Reverb could not be read, their last saved sounds were kept")
    }

    @Test func aFailedWriteNamesTheConfiguration() {
        #expect(SaveFlow.failureNotice(name: "Night rig") == "Night rig could not be saved")
    }

    @Test func aSavedMessageNamesTheConfiguration() {
        #expect(SaveFlow.savedNotice(name: "Night rig") == "Night rig saved")
    }
}

struct SavePreparationTests {
    private let changed = Data([9])

    private func session() -> EditingSession {
        EditingSession(saved: .fixture(name: "Night rig", channels: [.fixture()]))
    }

    @Test func aSoundNotedBeforeTheCaptureSurvivesIntoTheSavedConfiguration() throws {
        var held = session()
        let prepared = try #require(
            SaveFlow.prepare(
                session: { held },
                noteChanges: {
                    // What a plugin window does when it is read: the session takes the changed sound.
                    held.edit { $0.channels[0].slot.takeChangedSound(changed) }
                },
                capture: { ($0, []) }, name: nil, asCopy: false))
        #expect(prepared.configuration.channels[0].slot.state == changed)
        #expect(prepared.configuration.channels[0].slot.isCustomSound)
    }

    @Test func theCaptureSeesWhatWasNoted() throws {
        var held = session()
        var seen: Configuration?
        _ = SaveFlow.prepare(
            session: { held }, noteChanges: { held.edit { $0.name = "Noted" } },
            capture: { seen = $0; return ($0, []) }, name: nil, asCopy: false)
        #expect(seen?.name == "Noted")
    }

    @Test func aNameIsGivenAndACopyGetsANewId() throws {
        let held = session()
        let prepared = try #require(
            SaveFlow.prepare(session: { held }, noteChanges: {}, capture: { ($0, ["Delay"]) }, name: "  Copy  ", asCopy: true))
        #expect(prepared.configuration.name == "Copy")
        #expect(prepared.configuration.id != held.configuration.id)
        #expect(prepared.unreadable == ["Delay"])
    }

    @Test func anEmptyNameOrNoSessionPreparesNothing() {
        let held = session()
        #expect(SaveFlow.prepare(session: { held }, noteChanges: {}, capture: { ($0, []) }, name: " ", asCopy: false) == nil)
        #expect(SaveFlow.prepare(session: { nil }, noteChanges: {}, capture: { ($0, []) }, name: nil, asCopy: false) == nil)
    }
}

struct SettingsOptionsTests {
    private let devices = [
        DeviceChoice(id: "uid-b", name: "Beta"), DeviceChoice(id: "uid-a", name: "alpha"),
    ]

    @Test func systemDefaultComesFirstThenDevicesByName() {
        let options = SettingsOptions.devices(devices, current: nil, knownNames: [:])
        #expect(options.map(\.label) == ["System default", "alpha", "Beta"])
        #expect(options.map(\.value) == [nil, "uid-a", "uid-b"])
    }

    @Test func aPickedDeviceThatIsGoneStaysListedByItsKnownName() {
        let options = SettingsOptions.devices(devices, current: "uid-x", knownNames: ["uid-x": "Interface"])
        #expect(options.last == RouteOption("uid-x", "Interface (not connected)"))
    }

    @Test func aPickedDeviceThatIsGoneAndUnnamedShowsItsUID() {
        let options = SettingsOptions.devices(devices, current: "uid-x", knownNames: [:])
        #expect(options.last == RouteOption("uid-x", "uid-x (not connected)"))
    }

    @Test func aConnectedPickedDeviceIsListedOnce() {
        #expect(SettingsOptions.devices(devices, current: "uid-a", knownNames: [:]).count == 3)
    }

    @Test func rateAndBufferOptionsAreTheSupportedOnes() {
        #expect(SettingsOptions.sampleRates(current: 48000).map(\.label) == ["44.1 kHz", "48 kHz", "96 kHz"])
        #expect(SettingsOptions.bufferSizes(current: 128).map(\.label) == ["64 samples", "128 samples", "256 samples", "512 samples"])
    }

    @Test func aValueFromAFileStaysListed() {
        #expect(SettingsOptions.sampleRates(current: 88200).last == RouteOption(88200, "88.2 kHz"))
        #expect(SettingsOptions.bufferSizes(current: 1024).last == RouteOption(1024, "1024 samples"))
    }

    @Test func clockSourcesStartWithNoneAndKeepAMissingOneListed() {
        let options = SettingsOptions.clockSources(["IAC", "Keys"], current: "Drum machine")
        #expect(options.map(\.label) == ["None", "IAC", "Keys", "Drum machine (not connected)"])
        #expect(SettingsOptions.clockSources(["IAC"], current: "IAC").map(\.label) == ["None", "IAC"])
    }

    @Test func rateAndBufferAreEditableOnlyForAPickedDevice() {
        var settings = AppSettings.defaults
        #expect(!SettingsOptions.editsDeviceValues(in: settings))
        settings.audioDeviceUID = "uid-a"
        #expect(SettingsOptions.editsDeviceValues(in: settings))
    }

    @Test func runningValuesReadAsTheOptionsDo() {
        #expect(SettingsOptions.sampleRateLabel(44100) == "44.1 kHz")
        #expect(SettingsOptions.bufferLabel(256) == "256 samples")
    }
}
