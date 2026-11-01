import PluginariumAudio
import PluginariumCore
import SwiftUI

/// `settingsScreen` of `ui-prototype/app.js`. Every change is stored and told to audio, which keeps
/// it for later when no configuration plays.
struct SettingsScreen: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    audioSection
                    clockSection
                    instrumentSection
                    effectSection
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .padding(.horizontal, 14)
        // The devices come and go while the screen shows.
        .task {
            while !Task.isCancelled {
                model.refreshDevices()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var settings: AppSettings { model.settings }
    private var sources: [String] { model.audio?.router.sources ?? [] }

    private var topBar: some View {
        HStack(spacing: 12) {
            Text("Settings")
                .font(.panelDisplay(27))
                .panelSpacing(0.05, size: 27)
                .textCase(.uppercase)
                .foregroundStyle(Color.legend)
            Spacer(minLength: 0)
            if let audio = model.audio { AudioFaults(audio: audio) }
            Button("Done") { model.closeSettings() }
                .buttonStyle(.key)
        }
        .padding(.top, 12)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.lineStrong).frame(height: 1) }
    }

    // MARK: - Sections

    private var audioSection: some View {
        let editable = SettingsOptions.editsDeviceValues(in: settings)
        return SettingsSection(title: "Audio", text: "Plugins play and listen through this device.") {
            HStack(alignment: .top, spacing: 12) {
                labelled("Device") {
                    FieldMenu(
                        title: "Device",
                        options: SettingsOptions.devices(
                            model.devices.map { DeviceChoice(id: $0.id, name: $0.name) }, current: settings.audioDeviceUID,
                            knownNames: knownNames),
                        selection: settings.audioDeviceUID
                    ) { uid in model.changeSettings { $0.audioDeviceUID = uid } }
                }
                labelled("Sample rate") {
                    if editable {
                        FieldMenu(
                            title: "Sample rate", options: SettingsOptions.sampleRates(current: settings.sampleRate),
                            selection: settings.sampleRate
                        ) { rate in model.changeSettings { $0.sampleRate = rate } }
                    } else {
                        runningValue(model.audio?.engine.runningSampleRate, label: SettingsOptions.sampleRateLabel, title: "Sample rate")
                    }
                }
                labelled("Buffer size") {
                    if editable {
                        FieldMenu(
                            title: "Buffer size", options: SettingsOptions.bufferSizes(current: settings.bufferFrames),
                            selection: settings.bufferFrames
                        ) { frames in model.changeSettings { $0.bufferFrames = frames } }
                    } else {
                        runningValue(model.audio?.engine.runningBufferFrames, label: SettingsOptions.bufferLabel, title: "Buffer size")
                    }
                }
            }
            if !editable {
                Text(SettingsOptions.systemDefaultNote)
                    .font(.panelText(13))
                    .foregroundStyle(Color.muted)
                    .padding(.top, 8)
            }
        }
    }

    private var knownNames: [String: String] {
        guard let uid = settings.audioDeviceUID, let name = model.name(ofDevice: uid) else { return [:] }
        return [uid: name]
    }

    /// The values a device keeps when nothing is asked of it, which cannot be changed from here.
    private func runningValue<Value: Hashable & Sendable>(_ value: Value?, label: (Value) -> String, title: String) -> some View {
        FieldMenu(
            title: title, options: [RouteOption(value, value.map(label) ?? "–")], selection: value
        ) { _ in }
        .disabled(true)
    }

    private var clockSection: some View {
        SettingsSection(title: "MIDI clock", text: "Plugins with tempo sync follow this device.") {
            HStack(alignment: .top, spacing: 12) {
                labelled("Clock source") {
                    FieldMenu(
                        title: "Clock source", options: SettingsOptions.clockSources(sources, current: settings.clockSource),
                        selection: settings.clockSource
                    ) { source in model.changeSettings { $0.clockSource = source } }
                }
            }
        }
    }

    private var instrumentSection: some View {
        SettingsSection(
            title: "Instrument positions",
            text: "A new instrument takes the routing of its position in the stack. You can change it on the channel afterwards."
        ) {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    heading("Position")
                    heading("MIDI device")
                    heading("Channel")
                    heading("Audio out")
                }
                ForEach(Array(settings.instrumentPositions.enumerated()), id: \.offset) { index, position in
                    GridRow {
                        positionNumber(index)
                        let source = position.midiIn?.sourceName
                        FieldMenu(
                            title: "MIDI device for position \(index + 1)",
                            options: ChannelOptions.midiSources(sources, current: source), selection: source
                        ) { name in
                            model.changeSettings { settings in
                                let channel = settings.instrumentPositions[index].midiIn?.channel ?? .all
                                settings.instrumentPositions[index].midiIn = name.map { MIDIRoute(sourceName: $0, channel: channel) }
                            }
                        }
                        FieldMenu(
                            title: "Channel for position \(index + 1)", options: ChannelOptions.midiChannels,
                            selection: position.midiIn?.channel ?? .all
                        ) { filter in model.changeSettings { $0.instrumentPositions[index].midiIn?.channel = filter } }
                        .disabled(position.midiIn == nil)
                        .frame(width: 113)
                        FieldMenu(
                            title: "Audio out for position \(index + 1)",
                            options: ChannelOptions.outputs(deviceOutputs: model.settingsOutputs, current: position.audioOut),
                            selection: position.audioOut
                        ) { out in model.changeSettings { $0.instrumentPositions[index].audioOut = out } }
                        .frame(width: 182)
                    }
                }
            }
        }
    }

    private var effectSection: some View {
        SettingsSection(title: "Effect positions", text: "A new standalone effect takes these audio channels.", isLast: true) {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    heading("Position")
                    heading("Audio in")
                    heading("Audio out")
                }
                ForEach(Array(settings.effectPositions.enumerated()), id: \.offset) { index, position in
                    GridRow {
                        positionNumber(index)
                        FieldMenu(
                            title: "Audio in for position \(index + 1)",
                            options: ChannelOptions.inputs(deviceInputs: model.settingsInputs, allowsOff: false, current: position.audioIn),
                            selection: position.audioIn
                        ) { selection in
                            guard let selection else { return }
                            model.changeSettings { $0.effectPositions[index].audioIn = selection }
                        }
                        FieldMenu(
                            title: "Audio out for position \(index + 1)",
                            options: ChannelOptions.outputs(deviceOutputs: model.settingsOutputs, current: position.audioOut),
                            selection: position.audioOut
                        ) { out in model.changeSettings { $0.effectPositions[index].audioOut = out } }
                    }
                }
            }
        }
    }

    // MARK: - Parts

    private func labelled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Legend(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `.settings th`.
    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.panelText(11.5))
            .panelSpacing(0.08, size: 11.5)
            .textCase(.uppercase)
            .foregroundStyle(Color.muted)
            .padding(.bottom, 2)
            .gridColumnAlignment(.leading)
    }

    /// `.settings td:first-child`.
    private func positionNumber(_ index: Int) -> some View {
        Text("\(index + 1)")
            .font(.panelText(14))
            .foregroundStyle(Color.muted)
            .frame(width: 72, alignment: .leading)
    }
}

/// `.settings section`: a heading and a line under it, then the controls.
private struct SettingsSection<Content: View>: View {
    let title: String
    let text: String
    var isLast = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.panelDisplay(23))
                .panelSpacing(0.05, size: 23)
                .textCase(.uppercase)
                .foregroundStyle(Color.legend)
                .padding(.bottom, 4)
            Text(text)
                .font(.panelText(14))
                .foregroundStyle(Color.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480, alignment: .leading)
                .padding(.bottom, 12)
            content
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(Color.line).frame(height: 1) }
        }
    }
}
