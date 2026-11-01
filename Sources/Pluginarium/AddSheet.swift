import PluginariumAudio
import PluginariumCore
import SwiftUI

/// Where the plugin picked in the Add dialog goes.
enum AddTarget: Equatable, Identifiable {
    /// A new channel; the dialog offers instruments and standalone effects.
    case channel
    /// An effect of a channel: in a new row of its chain, or in `row` next to the effects there.
    case insert(channel: UUID, row: Int?)
    /// The plugin of an existing channel, which keeps its routing and effects.
    case replace(channel: UUID)

    var id: String {
        switch self {
        case .channel: "channel"
        case .insert(let channel, let row): "insert-\(channel)-\(row.map(String.init) ?? "new")"
        case .replace(let channel): "replace-\(channel)"
        }
    }
}

/// What the Add dialog is doing: the search, the pick and the routing. It leaves the choosing to
/// `AddPicker` and the editing to `AppModel.finishAdd`.
@MainActor
@Observable
final class AddModel {
    let target: AddTarget
    let title: String
    let plugins: [PluginInfo]

    var query = "" { didSet { refresh() } }
    var kind: PluginKind {
        didSet {
            guard kind != oldValue else { return }
            routing = app.newRouting(for: kind)
            refresh()
        }
    }
    var routing: AddRouting
    private(set) var selected: PluginID?
    private(set) var preset = AddPreset.defaultSound
    private(set) var capabilities: PluginCapabilities?
    /// Nil until the plugin has told.
    private(set) var factoryPresets: [String]?
    private(set) var isProbing = false
    private(set) var savedPresets: [Preset] = []

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var isDone = false

    init(target: AddTarget, app: AppModel) {
        self.target = target
        self.app = app
        plugins = app.installedPlugins
        let channels = app.session?.configuration.channels
        let initialKind: PluginKind
        switch target {
        case .channel:
            initialKind = .instrument
            title = "Add to stack"
        case .insert(let id, _):
            initialKind = .effect
            title = "Add effect to \(channels?.first { $0.id == id }?.slot.displayName ?? "channel")"
        case .replace(let id):
            initialKind = channels?.first { $0.id == id }?.kind ?? .instrument
            title = "Replace plugin"
        }
        kind = initialKind
        routing = app.newRouting(for: initialKind)
        select(AddPicker.selection(keeping: nil, in: listing))
    }

    var listing: AddListing {
        AddPicker.listing(of: plugins, kind: kind, query: query, recent: app.settings.recentPlugins)
    }

    var selectedPlugin: PluginInfo? { plugins.first { $0.id == selected } }

    var showsTabs: Bool { target == .channel }
    var showsRouting: Bool { target == .channel }
    var confirmLabel: String {
        if case .replace = target { "Replace" } else { "Add" }
    }

    var fields: ChannelFields { AddPicker.fields(kind: kind, capabilities: capabilities) }

    // MARK: - Actions

    func choose(_ plugin: PluginID) {
        guard plugin != selected else { return }
        select(plugin)
    }

    func choose(_ preset: AddPreset) {
        self.preset = preset
    }

    func move(by step: Int) {
        select(AddPicker.moved(from: selected, by: step, in: listing))
    }

    func accept() {
        guard !isDone, let plugin = selectedPlugin else { return }
        isDone = true
        app.finishAdd(target, plugin: plugin, preset: preset, routing: routing, capabilities: capabilities)
    }

    func cancel() {
        app.closeAdd()
    }

    /// `AppModel.closeAdd` has taken the dialog away: nothing it was asked to do counts any more.
    func dismissed() {
        isDone = true
    }

    // MARK: - Selection

    private func refresh() {
        let next = AddPicker.selection(keeping: selected, in: listing)
        if next != selected { select(next) }
    }

    private func select(_ plugin: PluginID?) {
        selected = plugin
        preset = .defaultSound
        guard let plugin else {
            app.stopProbes()
            capabilities = nil
            factoryPresets = nil
            savedPresets = []
            isProbing = false
            return
        }
        capabilities = app.knownCapabilities(of: plugin)
        factoryPresets = app.knownFactoryPresets(of: plugin)
        savedPresets = app.savedPresets(for: plugin)
        isProbing = capabilities == nil || factoryPresets == nil
        if isProbing {
            app.requestProbe(plugin) { [weak self] plugin, result in self?.probed(plugin, result) }
        } else {
            app.stopProbes()
        }
    }

    /// What a plugin loaded for this dialog said. If it could not be loaded, what is unknown stays unknown.
    private func probed(_ plugin: PluginID, _ result: ProbeResult?) {
        guard selected == plugin else { return }
        if let result {
            capabilities = result.capabilities
            factoryPresets = result.factoryPresets
        }
        isProbing = false
    }
}

extension View {
    /// Shows the Add dialog over the whole view while `AppModel.addTarget` is set.
    func addDialog(_ model: AppModel) -> some View {
        // The dialog is modal: what is under it can be neither reached with Tab nor read out.
        disabled(model.addModel != nil)
        .accessibilityHidden(model.addModel != nil)
        .overlay {
            if let add = model.addModel {
                ZStack {
                    Color.black.opacity(0.6)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                    AddSheet(model: add)
                        .id(ObjectIdentifier(add))
                        .environment(model)
                }
            }
        }
    }
}

/// `dialog.wide`: 640 pt wide, with the search focused so a few letters and Return are enough.
struct AddSheet: View {
    /// Made by `AppModel` when the dialog opens. The view only shows it, so re-evaluating the view
    /// cannot make another one.
    @Bindable var model: AddModel

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.title)
                .font(.panelDisplay(27))
                .panelSpacing(0.05, size: 27)
                .textCase(.uppercase)
                .foregroundStyle(Color.legend)
                .frame(height: 27)
                .padding(.bottom, 10)
            if model.showsTabs { tabs }
            search
            columns
            if model.showsRouting { RoutingFields(model: model) }
            actions
        }
        .padding(18)
        .frame(width: 640)
        .background(Color.panel)
        .overlay(Rectangle().strokeBorder(Color.lineStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.65), radius: 30, y: 20)
        .accessibilityAddTraits(.isModal)
        // Set after the update that shows the dialog. Set in onAppear, the request is lost and
        // focus lands on the next control, so typed letters never reach the search.
        .task {
            await Task.yield()
            searchFocused = true
        }
    }

    private var tabs: some View {
        HStack(spacing: 16) {
            tab("Instrument", kind: .instrument)
            tab("Standalone effect", kind: .effect)
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 1) }
        .padding(.bottom, 10)
    }

    private func tab(_ title: String, kind: PluginKind) -> some View {
        let isSelected = model.kind == kind
        return Button { model.kind = kind } label: {
            Text(title)
                .font(.panelText(13))
                .panelSpacing(0.06, size: 13)
                .textCase(.uppercase)
                .foregroundStyle(isSelected ? Color.legend : Color.muted)
                .padding(.top, 4)
                .padding(.bottom, 6)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(isSelected ? Color.led : Color.clear).frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var search: some View {
        TextField("", text: $model.query, prompt: Text("Search plugins").foregroundStyle(Color.muted))
            .textFieldStyle(.plain)
            .font(.panelText(14))
            .foregroundStyle(Color.legend)
            .focused($searchFocused)
            .onSubmit { model.accept() }
            .onKeyPress(.downArrow) { model.move(by: 1); return .handled }
            .onKeyPress(.upArrow) { model.move(by: -1); return .handled }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(Color.panelDeep)
            .overlay {
                if searchFocused {
                    Rectangle().strokeBorder(Color.led, lineWidth: 2)
                } else {
                    Rectangle().strokeBorder(Color.line, lineWidth: 1)
                }
            }
            .accessibilityLabel("Search plugins")
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 14) {
            PluginColumn(model: model)
            PresetColumn(model: model)
        }
        .frame(height: 260)
        .padding(.top, 10)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button("Cancel") { model.cancel() }
                .buttonStyle(.key)
                .keyboardShortcut(.cancelAction)
            Button(model.confirmLabel) { model.accept() }
                .buttonStyle(KeyButtonStyle.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(model.selected == nil)
        }
        .padding(.top, 16)
    }
}

/// `.pick`: a row of a list, the chosen one inverted.
private struct PickRow: View {
    let title: String
    var detail: String?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.panelText(14))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if let detail {
                Text(detail)
                    .font(.panelText(12.5))
                    .foregroundStyle(isSelected ? Color(red: 0x4B / 255, green: 0x4A / 255, blue: 0x44 / 255) : Color.muted)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(isSelected ? Color.panelDeep : Color.legend)
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.legend : isHovered ? Color.panelRaised : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// `.add-col .legend`.
private struct ColumnLegend: View {
    let text: String
    var isFirst = false

    var body: some View {
        Legend(text)
            .padding(.top, isFirst ? 0 : 8)
            .padding(.leading, 7)
    }
}

private struct Hint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.panelText(13))
            .foregroundStyle(Color.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
            .padding(.horizontal, 7)
    }
}

/// Recent plugins, then all the others.
private struct PluginColumn: View {
    let model: AddModel

    var body: some View {
        let listing = model.listing
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !listing.recent.isEmpty {
                        ColumnLegend(text: "Recent", isFirst: true)
                        rows(listing.recent)
                    }
                    if !listing.others.isEmpty {
                        ColumnLegend(text: othersTitle(hasRecent: !listing.recent.isEmpty), isFirst: listing.recent.isEmpty)
                        rows(listing.others)
                    }
                    if listing.all.isEmpty { Hint(text: "No plugin matches this search.") }
                }
            }
            .onChange(of: model.selected) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
        .accessibilityLabel("Plugins")
    }

    private func othersTitle(hasRecent: Bool) -> String {
        if hasRecent { return "All" }
        return model.kind == .instrument ? "Instruments" : "Effects"
    }

    private func rows(_ plugins: [PluginInfo]) -> some View {
        ForEach(plugins, id: \.id) { plugin in
            PickRow(title: plugin.name, detail: plugin.vendor, isSelected: plugin.id == model.selected) {
                model.choose(plugin.id)
            }
            .id(plugin.id)
        }
    }
}

/// Default sound, then the saved presets, then the factory ones or the hint about them.
private struct PresetColumn: View {
    let model: AddModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if model.selected != nil {
                    ColumnLegend(text: "Sound", isFirst: true)
                    PickRow(title: "Default sound", isSelected: model.preset == .defaultSound) { model.choose(.defaultSound) }
                    if !model.savedPresets.isEmpty {
                        ColumnLegend(text: "My presets")
                        ForEach(model.savedPresets, id: \.name) { saved in
                            PickRow(title: saved.name, isSelected: model.preset == .saved(saved)) { model.choose(.saved(saved)) }
                        }
                    }
                    factory
                }
            }
        }
        .accessibilityLabel("Presets")
    }

    @ViewBuilder private var factory: some View {
        if let names = model.factoryPresets, !names.isEmpty {
            ColumnLegend(text: "Factory presets")
            ForEach(names, id: \.self) { name in
                PickRow(title: name, isSelected: model.preset == .factory(name)) { model.choose(.factory(name)) }
            }
        } else if !model.isProbing {
            Hint(text: "Factory sounds stay inside this plugin. Choose one in its window and save it as a preset.")
        }
    }
}

/// `.add-route`: the fields the plugin has, which the new channel starts with.
private struct RoutingFields: View {
    @Bindable var model: AddModel

    @Environment(AppModel.self) private var app

    var body: some View {
        let fields = model.fields
        HStack(alignment: .top, spacing: 8) {
            if model.kind == .instrument {
                if fields.midiIn { midiDevice; midiChannel }
            }
            if fields.audioIn { audioIn }
            if fields.sidechainIn { sidechainIn }
            audioOut
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 1) }
        .padding(.top, 12)
    }

    private var sources: [String] { app.audio?.router.sources ?? [] }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Legend(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var midiDevice: some View {
        let source = model.routing.midiIn?.sourceName
        return field("MIDI device") {
            FieldMenu(title: "MIDI device", options: ChannelOptions.midiSources(sources, current: source), selection: source) { name in
                model.routing.midiIn = name.map { MIDIRoute(sourceName: $0, channel: model.routing.midiIn?.channel ?? .all) }
            }
        }
    }

    private var midiChannel: some View {
        field("Channel") {
            FieldMenu(
                title: "MIDI channel", options: ChannelOptions.midiChannels, selection: model.routing.midiIn?.channel ?? .all
            ) { filter in
                model.routing.midiIn?.channel = filter
            }
            .disabled(model.routing.midiIn == nil)
        }
    }

    private var audioIn: some View {
        field("Audio in") {
            FieldMenu(
                title: "Audio in",
                options: ChannelOptions.inputs(deviceInputs: app.deviceInputs, allowsOff: model.kind == .instrument, current: model.routing.audioIn),
                selection: model.routing.audioIn
            ) { model.routing.audioIn = $0 }
        }
    }

    private var sidechainIn: some View {
        field("Sidechain in") {
            FieldMenu(
                title: "Sidechain in",
                options: ChannelOptions.inputs(deviceInputs: app.deviceInputs, allowsOff: true, current: model.routing.sidechainIn),
                selection: model.routing.sidechainIn
            ) { model.routing.sidechainIn = $0 }
        }
    }

    private var audioOut: some View {
        field("Audio out") {
            FieldMenu(
                title: "Audio out",
                options: ChannelOptions.outputs(deviceOutputs: app.deviceOutputs, current: model.routing.audioOut),
                selection: model.routing.audioOut
            ) { model.routing.audioOut = $0 }
        }
    }
}
