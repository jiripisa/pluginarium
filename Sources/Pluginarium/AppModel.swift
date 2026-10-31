import Foundation
import Observation
import PluginariumAudio
import PluginariumCore
import PluginariumTestUnits
import os

private let logger = Logger(subsystem: "io.jp4.pluginarium", category: "app")

private let toastDuration = Duration.milliseconds(3600)

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
        didSet {
            guard screen != oldValue else { return }
            closeMenu()
            closeAdd()
        }
    }
    var session: EditingSession?
    var settings: AppSettings
    var configurations: [Configuration]
    /// What is waiting behind the save question, once it has been answered.
    var pendingLeave: (() -> Void)?
    /// The question on screen, which `RootView` shows over any screen.
    var dialog: ChoiceDialog?
    /// The name being asked for, which `RootView` shows over any screen.
    var nameDialog: NameDialog?
    /// The menu on screen. Only one is open at a time.
    private(set) var menu: PanelMenu? {
        didSet {
            if let menu { menuWindow.show(menu) } else { menuWindow.hide() }
        }
    }
    /// The line at the bottom of the window.
    private(set) var toast: String?
    /// The Add dialog on screen, which `RootView` shows over any screen. It is made once when the
    /// dialog opens and dropped when it closes, so no view can make a second one.
    private(set) var addModel: AddModel?

    /// Where the dialog on screen adds to; setting nil closes it.
    var addTarget: AddTarget? {
        get { addModel?.target }
        set {
            if let newValue { openAdd(newValue) } else { closeAdd() }
        }
    }

    private(set) var audio: AudioSession?
    /// Goes up each time a preset is saved.
    private var presetChanges = 0

    @ObservationIgnored private(set) lazy var pluginWindows = PluginWindows(app: self)
    @ObservationIgnored private lazy var menuWindow = PanelMenuWindow { [weak self] in self?.closeMenu() }

    @ObservationIgnored private let configurationStore: ConfigurationStore
    @ObservationIgnored private let cache: CapabilityCache
    @ObservationIgnored private let presetStore: PresetStore
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private var installed: [PluginInfo]?
    /// The files of a plugin's presets are read once, because every channel's label asks for them.
    @ObservationIgnored private var presetCache: [PluginID: [Preset]] = [:]
    @ObservationIgnored private var toastTimer: Task<Void, Never>?
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
        closeMenu()
        closeAdd()
        pluginWindows.closeAll()
        session = EditingSession(saved: configuration)
        screen = .mixer
        let audio = audioSession()
        let settings = settings
        Task { await audio.reload(configuration, settings: settings) }
    }

    func newConfiguration() {
        pluginWindows.closeAll()
        let configuration = Configuration(name: "")
        session = EditingSession(new: configuration)
        screen = .mixer
        let audio = audioSession()
        let settings = settings
        Task { await audio.open(configuration, settings: settings) }
        beginAddChannel()
    }

    /// Every edit of a configuration comes through here. A plugin the edit takes away loses its window
    /// now, before audio lets the plugin go. The task ends once the plugins have settled.
    @discardableResult
    func edit(_ change: (inout Configuration) -> Void) -> Task<Void, Never>? {
        session?.edit(change)
        if let configuration = session?.configuration { pluginWindows.closeWindowsOfPluginsGone(from: configuration) }
        guard let audio else { return nil }
        // Takes the newest configuration when it runs, so edits cannot overtake one another.
        return Task { [weak self] in
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
        pluginWindows.noteChanges()
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
        _ = presetChanges  // So a view that asks here looks again when a preset is saved.
        if let presets = presetCache[plugin] { return presets }
        let presets = presetStore.presets(for: plugin)
        presetCache[plugin] = presets
        return presets
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

    /// The Add dialog has nothing to probe: nothing is loaded for it until it selects again.
    func stopProbes() { probes.stop() }

    /// The routing a new channel of `kind` starts with.
    func newRouting(for kind: PluginKind) -> AddRouting {
        let configuration = session?.configuration ?? Configuration(name: "")
        return AddRouting(defaults: defaultRouting(for: kind, in: configuration, settings: settings), kind: kind)
    }

    private func openAdd(_ target: AddTarget) {
        closeAdd()
        addModel = AddModel(target: target, app: self)
    }

    /// Closes the dialog, if one is open, and stops its probes so nothing starts for it later.
    func closeAdd() {
        guard let model = addModel else { return }
        addModel = nil
        model.dismissed()
        probes.stop()
    }

    /// Add column of the mixer, and a new configuration.
    func beginAddChannel() { openAdd(.channel) }

    /// Replace plugin button of a channel whose plugin is not installed.
    func beginReplacePlugin(channel: UUID) { openAdd(.replace(channel: channel)) }

    /// Add effect slot of a channel.
    func beginAddEffect(channel: UUID) { openAdd(.insert(channel: channel, row: nil)) }

    /// Add parallel effect of the effect menu.
    func beginAddParallelEffect(channel: UUID, row: Int) { openAdd(.insert(channel: channel, row: row)) }

    /// Puts the picked plugin where `target` says, and moves it to the front of the recent ones.
    func finishAdd(
        _ target: AddTarget, plugin: PluginInfo, preset: AddPreset, routing: AddRouting, capabilities: PluginCapabilities?
    ) {
        let location: PluginLocation
        let settled: Task<Void, Never>?
        switch target {
        case .channel:
            let channel = AddPicker.channel(plugin: plugin, preset: preset, routing: routing, capabilities: capabilities)
            location = PluginLocation(channel: channel.id)
            settled = edit { $0.channels.append(channel) }
        case .replace(let id):
            location = PluginLocation(channel: id)
            settled = editChannel(id) { channel in
                channel = AddPicker.replacing(channel, with: plugin, preset: preset, capabilities: capabilities)
            }
        case .insert(let id, let row):
            let effect = InsertEffect(slot: AddPicker.slot(plugin: plugin, preset: preset))
            location = PluginLocation(channel: id, effect: effect.id)
            settled = editChannel(id) { AddPicker.insert(effect, into: &$0, row: row) }
        }
        if case .factory(let name) = preset {
            Task {
                await settled?.value
                keepStateOfFactoryPreset(name, at: location)
            }
        }
        settings.recentPlugins = AddPicker.recent(adding: plugin.id, to: settings.recentPlugins)
        try? settingsStore.save(settings)
        closeAdd()
    }

    /// A new plugin starts on the factory preset its slot names, and this is the state that left it in.
    private func keepStateOfFactoryPreset(_ name: String, at location: PluginLocation) {
        guard session?.configuration.slot(at: location)?.presetName == name, let plugin = hostedPlugin(at: location) else { return }
        do {
            let state = try plugin.fullState()
            edit { $0.updateSlot(at: location) { $0.state = state } }
        } catch {
            logger.error("Cannot read the state after \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Plugins

    /// The plugin running at `location`. Loading, failed and missing ones have none.
    func hostedPlugin(at location: PluginLocation) -> HostedPlugin? {
        audio?.runner?.plugin(channel: location.channel, effect: location.effect)
    }

    func presetLabel(for slot: PluginSlot) -> String {
        PresetLabel.text(for: slot, saved: savedPresets(for: slot.plugin))
    }

    /// A plugin window has seen `closed`, after opening on `opened`. Plugins give no signal when their
    /// sound changes, so this is where the configuration hears of it.
    func notePluginState(at location: PluginLocation, opened: Data?, closed: Data?) {
        guard let slot = session?.configuration.slot(at: location),
            let state = PresetLabel.stateAfterWindowClosed(slot: slot, opened: opened, closed: closed)
        else { return }
        edit { $0.updateSlot(at: location) { $0.state = state } }
    }

    /// Goes through `Channel`'s methods and `edit`, like every change of a chain.
    @discardableResult
    private func editChannel(_ id: UUID, _ change: (inout Channel) -> Void) -> Task<Void, Never>? {
        edit { configuration in
            guard let index = configuration.channels.firstIndex(where: { $0.id == id }) else { return }
            change(&configuration.channels[index])
        }
    }

    // MARK: - Menus

    func closeMenu() {
        menu = nil
    }

    /// Preset selector of a channel, and Presets in the menu of an effect.
    func showPresetMenu(channel: UUID, effect: UUID?, anchor: CGRect) {
        let location = PluginLocation(channel: channel, effect: effect)
        guard let plugin = hostedPlugin(at: location), let slot = session?.configuration.slot(at: location) else { return }
        let entries = PluginMenus.presets(saved: savedPresets(for: slot.plugin), factory: plugin.factoryPresets(), current: slot.presetName)
        showMenu(entries, anchor: anchor) { [weak self] action in
            switch action {
            case .saved(let preset): self?.select(preset, at: location)
            case .factory(let name): self?.selectFactoryPreset(name, at: location)
            case .save: self?.beginSavePreset(at: location)
            }
        }
    }

    /// An effect slot of a channel.
    func showEffectMenu(channel id: UUID, effect effectID: UUID, anchor: CGRect) {
        guard let channel = session?.configuration.channels.first(where: { $0.id == id }), let rowIndex = channel.row(of: effectID),
            let effect = channel.effects[rowIndex].first(where: { $0.id == effectID })
        else { return }
        let location = PluginLocation(channel: id, effect: effectID)
        let hasSidechain = knownCapabilities(of: effect.slot.plugin)?.hasSidechain ?? (effect.sidechainIn != nil)
        let entries = PluginMenus.effect(
            rowSize: channel.effects[rowIndex].count, rowIndex: rowIndex, isOpen: pluginWindows.isOpen(channel: id, effect: effectID),
            isHosted: hostedPlugin(at: location) != nil, presetLabel: presetLabel(for: effect.slot),
            sidechain: hasSidechain ? effect.sidechainIn?.label(prefix: "In") ?? "Off" : nil
        )
        showMenu(entries, anchor: anchor) { [weak self] action in
            switch action {
            case .togglePlugin: self?.pluginWindows.toggle(channel: id, effect: effectID)
            case .presets: self?.showPresetMenu(channel: id, effect: effectID, anchor: anchor)
            case .sidechain: self?.showSidechainMenu(channel: id, effect: effectID, anchor: anchor)
            case .addParallel(let row): self?.beginAddParallelEffect(channel: id, row: row)
            case .moveToSeries: self?.editChannel(id) { $0.moveToSeries(effectID: effectID) }
            case .remove: self?.editChannel(id) { $0.removeEffect(effectID: effectID) }
            }
        }
    }

    private func showSidechainMenu(channel: UUID, effect: UUID, anchor: CGRect) {
        let current = session?.configuration.channels.first { $0.id == channel }?.effects.joined().first { $0.id == effect }?.sidechainIn
        showMenu(PluginMenus.sidechain(deviceInputs: deviceInputs, current: current), anchor: anchor) { [weak self] input in
            self?.editChannel(channel) { $0.setSidechain(effectID: effect, to: input) }
        }
    }

    private func showMenu<Action>(_ entries: [MenuEntry<Action>], anchor: CGRect, perform: @escaping (Action) -> Void) {
        menu = PanelMenu(anchor: anchor, entries: entries.map { entry in entry.map { action in { perform(action) } } })
    }

    // MARK: - Presets

    private func select(_ preset: Preset, at location: PluginLocation) {
        guard let plugin = hostedPlugin(at: location) else { return }
        do {
            // A running plugin keeps its own state whatever its slot says, so it is told directly.
            try plugin.restore(preset.state)
            edit {
                $0.updateSlot(at: location) { slot in
                    slot.presetName = preset.name
                    slot.state = preset.state
                }
            }
        } catch {
            report("\(preset.name) could not be loaded", error)
        }
    }

    private func selectFactoryPreset(_ name: String, at location: PluginLocation) {
        guard let plugin = hostedPlugin(at: location) else { return }
        do {
            try plugin.selectFactoryPreset(name)
            let state = try plugin.fullState()
            edit {
                $0.updateSlot(at: location) { slot in
                    slot.presetName = name
                    slot.state = state
                }
            }
        } catch {
            report("\(name) could not be loaded", error)
        }
    }

    private func beginSavePreset(at location: PluginLocation) {
        guard let slot = session?.configuration.slot(at: location) else { return }
        nameDialog = .savePreset(plugin: slot.displayName, current: slot.presetName) { [weak self] name in
            self?.savePreset(named: name, at: location)
        }
    }

    /// The preset is stored for good here, whatever becomes of the configuration.
    private func savePreset(named name: String, at location: PluginLocation) {
        guard let session, let plugin = hostedPlugin(at: location) else { return }
        let state: Data
        do {
            state = try plugin.fullState()
            try presetStore.save(Preset(name: name, plugin: plugin.id, state: state))
        } catch {
            report("\(name) could not be saved", error)
            return
        }
        presetCache[plugin.id] = presetStore.presets(for: plugin.id)
        presetChanges += 1
        edit {
            $0.updateSlot(at: location) { slot in
                slot.presetName = name
                slot.state = state
            }
        }
        switch session.followUpAfterPresetSaved() {
        case .askToSaveConfiguration:
            dialog = .updateConfiguration(preset: name, configuration: session.configuration.name) { [weak self] in
                self?.saveCurrent()
            }
        case .keepWithUnsavedConfiguration:
            show("\(name) saved. It joins this configuration when you save it.")
        }
    }

    private func report(_ text: String, _ error: any Error) {
        logger.error("\(text, privacy: .public): \(error.localizedDescription, privacy: .public)")
        show(text)
    }

    private func show(_ text: String) {
        toast = text
        toastTimer?.cancel()
        toastTimer = Task { [weak self] in
            try? await Task.sleep(for: toastDuration)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: - Stubs: the mixer shows these controls, and the tasks named here give them their actions.

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
        // A plugin's view can call the host at any time, and those calls end up in the render core.
        pluginWindows.closeAll()
        audio?.close()
        audio = nil
    }

    private func audioSession() -> AudioSession {
        if let audio { return audio }
        let audio = AudioSession(cache: cache)
        audio.willReleasePlugins = { [weak self] in self?.pluginWindows.closeAll() }
        self.audio = audio
        return audio
    }
}
