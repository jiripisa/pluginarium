import Foundation
import Observation
import PluginariumAudio
import PluginariumCore
import PluginariumTestUnits

/// What the screens show and ask for. Audio lives in `AudioSession`, which this creates only when a
/// configuration opens, so the Start screen touches no hardware.
@MainActor
@Observable
final class AppModel {

    enum Screen {
        case start, mixer, settings
    }

    var screen = Screen.start
    var session: EditingSession?
    var settings: AppSettings
    var configurations: [Configuration]
    /// What is waiting behind the save question, once it has been answered.
    var pendingLeave: (() -> Void)?
    /// The question on screen, which `RootView` shows over any screen.
    var dialog: ChoiceDialog?

    private(set) var audio: AudioSession?

    @ObservationIgnored private let configurationStore: ConfigurationStore
    @ObservationIgnored private let cache: CapabilityCache
    @ObservationIgnored private var settingsReturn = Screen.start

    init(base: URL = AppPaths.base()) {
        if ProcessInfo.processInfo.environment["PLUGINARIUM_TEST_UNITS"] == "1" { registerTestUnits() }
        configurationStore = ConfigurationStore(directory: base.appending(path: "configurations", directoryHint: .isDirectory))
        cache = CapabilityCache(file: base.appending(path: "capabilities.json"))
        settings = SettingsStore(file: base.appending(path: "settings.json")).load()
        configurations = configurationStore.loadAll()
    }

    func load(_ configuration: Configuration) {
        session = EditingSession(saved: configuration)
        screen = .mixer
        let audio = audioSession()
        let settings = settings
        Task { await audio.reload(configuration, settings: settings) }
    }

    func newConfiguration() {
        let configuration = Configuration(name: "")
        session = EditingSession(new: configuration)
        screen = .mixer
        let audio = audioSession()
        let settings = settings
        Task { await audio.open(configuration, settings: settings) }
    }

    func edit(_ change: (inout Configuration) -> Void) {
        session?.edit(change)
        guard let audio else { return }
        // Takes the newest configuration when it runs, so edits cannot overtake one another.
        Task { [weak self] in
            guard let configuration = self?.session?.configuration else { return }
            await audio.update(configuration)
        }
    }

    /// Saves under `name`, or the name it has, with the state its plugins are in now.
    func save(name: String? = nil) throws {
        guard var session else { return }
        var configuration = audio?.capturingState(of: session.configuration) ?? session.configuration
        if let name { configuration.name = name }
        try configurationStore.save(configuration)
        session.configuration = configuration
        session.markSaved()
        self.session = session
        configurations = configurationStore.loadAll()
    }

    /// Runs `action` right away unless there are unsaved changes. Then it waits in `pendingLeave` for
    /// the save question.
    func leave(then action: @escaping () -> Void) {
        guard session?.leaveAction == .askToSave else {
            action()
            return
        }
        pendingLeave = action
    }

    /// Asks before taking a channel out of the configuration.
    func askToRemove(_ channel: Channel) {
        let id = channel.id
        dialog = .removeChannel(named: channel.slot.displayName) { [weak self] in
            self?.edit { $0.channels.removeAll { $0.id == id } }
        }
    }

    // MARK: - Stubs: the mixer shows these controls, and the tasks named here give them their actions.

    /// Add column (Task 14).
    func beginAddChannel() {}

    /// Open plugin button of a channel or an effect (Task 14).
    func togglePluginWindow(channel: UUID, effect: UUID?) {}

    /// Preset selector of a channel or an effect (Task 14).
    func showPresetMenu(channel: UUID, effect: UUID?) {}

    /// Replace plugin button of a channel whose plugin is not installed (Task 14).
    func beginReplacePlugin(channel: UUID) {}

    /// Add effect slot of a channel (Task 15).
    func beginAddEffect(channel: UUID) {}

    /// An effect slot of a channel (Task 15).
    func showEffectMenu(channel: UUID, effect: UUID) {}

    /// Save button of the top bar (Task 16).
    func saveCurrent() {}

    /// Save as in the configuration menu (Task 16).
    func beginSaveAs() {}

    func showSettings() {
        settingsReturn = screen
        screen = .settings
    }

    func closeSettings() {
        screen = settingsReturn
    }

    /// For quitting: everything audio goes, in the order `AudioSession.close` keeps.
    func close() {
        audio?.close()
        audio = nil
    }

    private func audioSession() -> AudioSession {
        if let audio { return audio }
        let audio = AudioSession(cache: cache)
        self.audio = audio
        return audio
    }
}
