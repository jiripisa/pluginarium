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

    var screen = Screen.start {
        // A dialog belongs to the screen it was opened on.
        didSet { if screen != oldValue { addTarget = nil } }
    }
    var session: EditingSession?
    var settings: AppSettings
    var configurations: [Configuration]
    /// What is waiting behind the save question, once it has been answered.
    var pendingLeave: (() -> Void)?
    /// The question on screen, which `RootView` shows over any screen.
    var dialog: ChoiceDialog?
    /// The Add dialog on screen, which `RootView` shows as a sheet.
    var addTarget: AddTarget?

    private(set) var audio: AudioSession?

    @ObservationIgnored private let configurationStore: ConfigurationStore
    @ObservationIgnored private let cache: CapabilityCache
    @ObservationIgnored private let presetStore: PresetStore
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private var installed: [PluginInfo]?
    /// Probes for the Add dialog: one load at a time, and a plugin that failed is not loaded again.
    @ObservationIgnored private lazy var probes = ProbeScheduler<ProbeResult>(delay: .milliseconds(300)) { [weak self] plugin in
        await self?.probe(plugin)
    }
    @ObservationIgnored private var settingsReturn = Screen.start

    init(base: URL = AppPaths.base()) {
        if ProcessInfo.processInfo.environment["PLUGINARIUM_TEST_UNITS"] == "1" { registerTestUnits() }
        configurationStore = ConfigurationStore(directory: base.appending(path: "configurations", directoryHint: .isDirectory))
        cache = CapabilityCache(file: base.appending(path: "capabilities.json"))
        presetStore = PresetStore(directory: base.appending(path: "presets", directoryHint: .isDirectory))
        settingsStore = SettingsStore(file: base.appending(path: "settings.json"))
        settings = settingsStore.load()
        configurations = configurationStore.loadAll()
    }

    func load(_ configuration: Configuration) {
        addTarget = nil
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
        beginAddChannel()
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

    // MARK: - Add dialog

    /// The Audio Units that can be hosted, by name. Scanned once, when the Add dialog first needs them.
    var installedPlugins: [PluginInfo] {
        if let installed { return installed }
        let found = PluginCatalog.scan().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        installed = found
        return found
    }

    var deviceInputs: Int {
        if case .running(let device)? = audio?.engine.state { device.inputChannels.count } else { 0 }
    }

    var deviceOutputs: Int {
        if case .running(let device)? = audio?.engine.state { device.outputChannels.count } else { 0 }
    }

    func savedPresets(for plugin: PluginID) -> [Preset] {
        presetStore.presets(for: plugin)
    }

    func knownCapabilities(of plugin: PluginID) -> PluginCapabilities? { cache[plugin] }

    func knownFactoryPresets(of plugin: PluginID) -> [String]? { cache.factoryPresets(for: plugin) }

    /// Loads the plugin in the background, remembers what it says and returns it. Nil when it cannot be loaded.
    func probe(_ plugin: PluginID) async -> ProbeResult? {
        guard let result = await CapabilityProbe.probe(plugin) else { return nil }
        cache.store(result.capabilities, factoryPresets: result.factoryPresets, for: plugin)
        return result
    }

    /// Probes `plugin` for the Add dialog once the selection has rested; `deliver` gets nil if it cannot be loaded.
    func requestProbe(_ plugin: PluginID, deliver: @escaping ProbeScheduler<ProbeResult>.Deliver) {
        probes.request(plugin, deliver: deliver)
    }

    /// The Add dialog is gone or has nothing selected.
    func stopProbes() { probes.stop() }

    /// The routing a new channel of `kind` starts with.
    func newRouting(for kind: PluginKind) -> AddRouting {
        let configuration = session?.configuration ?? Configuration(name: "")
        return AddRouting(defaults: defaultRouting(for: kind, in: configuration, settings: settings), kind: kind)
    }

    /// Add column of the mixer, and a new configuration.
    func beginAddChannel() { addTarget = .channel }

    /// Replace plugin button of a channel whose plugin is not installed.
    func beginReplacePlugin(channel: UUID) { addTarget = .replace(channel: channel) }

    /// Add effect slot of a channel.
    func beginAddEffect(channel: UUID) { addTarget = .insert(channel: channel, row: nil) }

    /// Add next to the effects of a row, once the effect menu offers it (Task 15).
    func beginAddParallelEffect(channel: UUID, row: Int) { addTarget = .insert(channel: channel, row: row) }

    /// Puts the picked plugin where `target` says, and moves it to the front of the recent ones.
    func finishAdd(
        _ target: AddTarget, plugin: PluginInfo, preset: AddPreset, routing: AddRouting, capabilities: PluginCapabilities?
    ) {
        switch target {
        case .channel:
            let channel = AddPicker.channel(plugin: plugin, preset: preset, routing: routing, capabilities: capabilities)
            edit { $0.channels.append(channel) }
        case .replace(let id):
            edit { configuration in
                guard let index = configuration.channels.firstIndex(where: { $0.id == id }) else { return }
                configuration.channels[index] = AddPicker.replacing(
                    configuration.channels[index], with: plugin, preset: preset, capabilities: capabilities
                )
            }
        case .insert(let id, let row):
            let effect = InsertEffect(slot: AddPicker.slot(plugin: plugin, preset: preset))
            edit { configuration in
                guard let index = configuration.channels.firstIndex(where: { $0.id == id }) else { return }
                AddPicker.insert(effect, into: &configuration.channels[index], row: row)
            }
        }
        // A factory preset is only named here. Task 15 applies it to the running plugin.
        settings.recentPlugins = AddPicker.recent(adding: plugin.id, to: settings.recentPlugins)
        try? settingsStore.save(settings)
        addTarget = nil
    }

    // MARK: - Stubs: the mixer shows these controls, and the tasks named here give them their actions.

    /// Open plugin button of a channel or an effect (Task 14).
    func togglePluginWindow(channel: UUID, effect: UUID?) {}

    /// Preset selector of a channel or an effect (Task 14).
    func showPresetMenu(channel: UUID, effect: UUID?) {}

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
