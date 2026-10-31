import PluginariumAudio
import PluginariumCore
import SwiftUI

/// `.strip`: one instrument or standalone effect, 188 pt wide. Its fields come from the plugin's
/// capabilities, and its edits go through `AppModel.edit`.
struct ChannelView: View {
    static let width: CGFloat = 188

    let channel: Channel
    let index: Int

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            if fields.midiIn { midiIn }
            if fields.audioIn { audioIn }
            if fields.sidechainIn { sidechainIn }
            plugin
            if canOpen { openButton }
            effects
            MeterView(channel: channel.id, audio: model.audio)
            audioOut
        }
        .padding(.top, 12)
        .padding(.bottom, 12)
        .padding(.leading, 11)
        .padding(.trailing, 12)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(channel.kind == .effect ? Color.panelEffect : Color.clear)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.line).frame(width: 1) }
    }

    // MARK: - State

    private var audio: AudioSession? { model.audio }
    private var status: ChannelStatus? { audio?.runner?.status[channel.id] }

    private var fields: ChannelFields {
        ChannelFields(channel: channel, capabilities: audio?.runner?.capabilities(channel: channel.id))
    }

    /// Only a plugin that runs has a window and a sound to pick.
    private var canOpen: Bool {
        switch status {
        case .pluginMissing, .loadFailed, .loading: false
        case .ready, .routingUnavailable, nil: true
        }
    }

    private var deviceInputs: Int { model.deviceInputs }
    private var deviceOutputs: Int { model.deviceOutputs }

    private func edit(_ change: @escaping (inout Channel) -> Void) {
        let id = channel.id
        model.edit { configuration in
            guard let position = configuration.channels.firstIndex(where: { $0.id == id }) else { return }
            change(&configuration.channels[position])
        }
    }

    // MARK: - Parts

    private var header: some View {
        HStack {
            Text(String(index + 1))
                .font(.panelText(12.5))
                .foregroundStyle(Color.muted)
            Spacer(minLength: 0)
            Button { model.askToRemove(channel) } label: {
                Text("×")
                    .font(.panelText(15))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RemoveButtonStyle())
            .help("Remove")
            .accessibilityLabel("Remove \(channel.slot.displayName)")
        }
        .frame(height: 22)
    }

    private var midiIn: some View {
        let sources = audio?.router.sources ?? []
        let source = channel.midiIn?.sourceName
        return VStack(alignment: .leading, spacing: 0) {
            Legend("MIDI in")
            HStack(spacing: 4) {
                FieldMenu(
                    title: "MIDI device", options: ChannelOptions.midiSources(sources, current: source), selection: source
                ) { name in
                    edit { target in
                        target.midiIn = name.map { MIDIRoute(sourceName: $0, channel: target.midiIn?.channel ?? .all) }
                    }
                }
                FieldMenu(
                    title: "MIDI channel", options: ChannelOptions.midiChannels, selection: channel.midiIn?.channel ?? .all
                ) { filter in
                    edit { $0.midiIn?.channel = filter }
                }
                .disabled(channel.midiIn == nil)
                .frame(width: 58)
            }
            if let source, !sources.contains(source) {
                warning("\(source) is not connected")
            }
        }
    }

    private var audioIn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Legend("Audio in")
            FieldMenu(
                title: "Audio in",
                options: ChannelOptions.inputs(deviceInputs: deviceInputs, allowsOff: channel.kind == .instrument, current: channel.audioIn),
                selection: channel.audioIn
            ) { selection in
                edit { $0.audioIn = selection }
            }
        }
    }

    private var sidechainIn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Legend("Sidechain in")
            FieldMenu(
                title: "Sidechain in",
                options: ChannelOptions.inputs(deviceInputs: deviceInputs, allowsOff: true, current: channel.sidechainIn),
                selection: channel.sidechainIn
            ) { selection in
                edit { $0.sidechainIn = selection }
            }
        }
    }

    private var plugin: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(channel.slot.displayName)
                .font(.panelDisplay(29))
                .panelSpacing(0.04, size: 29)
                .textCase(.uppercase)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Color.legend)
                .frame(height: 29, alignment: .leading)
                .help(channel.slot.displayName)
            switch status {
            case .pluginMissing:
                faultBox("Plugin not installed on this Mac", help: nil) {
                    Button("Replace plugin") { model.beginReplacePlugin(channel: channel.id) }
                        .buttonStyle(.wideKey)
                }
            case .loadFailed(let message):
                faultBox("Plugin failed to load", help: message)
            case .loading:
                Text("Loading")
                    .font(.panelText(14))
                    .foregroundStyle(Color.muted)
                    .padding(.vertical, 2)
            case .ready, .routingUnavailable, nil:
                presetButton
            }
        }
    }

    private var presetButton: some View {
        Button { model.showPresetMenu(channel: channel.id, effect: nil) } label: {
            HStack(spacing: 6) {
                Text(channel.slot.presetName ?? "Default sound")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Text("▾").foregroundStyle(Color.muted)
            }
            .font(.panelText(14))
            .foregroundStyle(Color.ledSoft)
            .padding(.vertical, 2)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var openButton: some View {
        Button { model.togglePluginWindow(channel: channel.id, effect: nil) } label: {
            HStack(spacing: 7) {
                LED(tone: .off)
                Text("Open plugin")
                    .font(.panelText(12.5))
                    .panelSpacing(0.06, size: 12.5)
                    .textCase(.uppercase)
            }
            .foregroundStyle(Color.legend)
            .frame(maxWidth: .infinity)
            .padding(4)
            .overlay(Rectangle().strokeBorder(Color.lineStrong, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Existing effects take their rows, so the layout is right. Joining the parallel ones with
    /// lines comes with the effect chain.
    private var effects: some View {
        VStack(alignment: .leading, spacing: 5) {
            Legend("Effects")
            ForEach(Array(channel.effects.enumerated()), id: \.offset) { _, row in
                EffectRow(channel: channel, row: row)
            }
            Button { model.beginAddEffect(channel: channel.id) } label: {
                Text("Add effect")
                    .font(.panelText(12.5))
                    .foregroundStyle(Color.muted)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(Rectangle().strokeBorder(Color.line, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if case .routingUnavailable(let label) = status {
                warning("\(label) is not available on this device")
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .frame(minHeight: 96, alignment: .top)
    }

    private var audioOut: some View {
        VStack(alignment: .leading, spacing: 0) {
            Legend("Audio out")
            FieldMenu(
                title: "Audio out",
                options: ChannelOptions.outputs(deviceOutputs: deviceOutputs, current: channel.audioOut),
                selection: channel.audioOut
            ) { selection in
                edit { $0.audioOut = selection }
            }
        }
    }

    private func warning(_ text: String) -> some View {
        HStack(spacing: 6) {
            LED(tone: .fault)
            Text(text)
                .font(.panelText(12.5))
                .foregroundStyle(Color.fault)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private func faultBox(_ text: String, help: String?, @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(text)
                .font(.panelText(13))
                .foregroundStyle(Color.fault)
                .fixedSize(horizontal: false, vertical: true)
            action()
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().strokeBorder(Color.fault, lineWidth: 1))
        .help(help ?? "")
    }
}

/// `.remove`: muted until hovered.
private struct RemoveButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        Hovering { isHovered in
            configuration.label.foregroundStyle(isHovered ? Color.legend : Color.muted)
        }
    }

    private struct Hovering<Content: View>: View {
        @ViewBuilder let content: (Bool) -> Content
        @State private var isHovered = false

        var body: some View {
            content(isHovered).onHover { isHovered = $0 }
        }
    }
}

/// `.fx-row`: the effects of one row side by side.
private struct EffectRow: View {
    let channel: Channel
    let row: [InsertEffect]

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ForEach(row) { effect in
                    EffectSlotButton(name: effect.slot.displayName, help: help(for: effect)) {
                        model.showEffectMenu(channel: channel.id, effect: effect.id)
                    }
                }
            }
            ForEach(row.filter { $0.sidechainIn != nil }) { effect in
                if let source = effect.sidechainIn {
                    Text("Sidechain from \(source.label(prefix: "In"))")
                        .font(.panelText(12))
                        .foregroundStyle(Color.muted)
                }
            }
        }
    }

    private func help(for effect: InsertEffect) -> String {
        guard let source = effect.sidechainIn else { return effect.slot.displayName }
        return "\(effect.slot.displayName), sidechain from \(source.label(prefix: "In"))"
    }
}

/// `.fx`.
private struct EffectSlotButton: View {
    let name: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.panelText(12.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Color.ledSoft)
                .padding(.vertical, 4)
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.panelDeep)
                .overlay {
                    Rectangle().strokeBorder(Color.led.opacity(0.15), lineWidth: 8).blur(radius: 4).clipped()
                }
                .overlay(Rectangle().strokeBorder(isHovered ? Color.led : Color.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}
