import PluginariumAudio
import PluginariumCore
import SwiftUI

/// The main screen: the top bar over the channels in a row, then the column that adds one.
struct MixerScreen: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model)
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                        ChannelView(channel: channel, index: index)
                    }
                    AddColumn { model.beginAddChannel() }
                }
                .frame(maxHeight: .infinity)
            }
            .scrollIndicators(.automatic)
        }
        .padding(.horizontal, 14)
        .environment(model)
    }

    private var channels: [Channel] { model.session?.configuration.channels ?? [] }
}

/// `.add-strip`.
private struct AddColumn: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("Add instrument or effect")
                .font(.panelText(12.5))
                .panelSpacing(0.06, size: 12.5)
                .textCase(.uppercase)
                .multilineTextAlignment(.center)
                .foregroundStyle(isHovered ? Color.legend : Color.muted)
                .padding(12)
                .frame(width: 104)
                .frame(maxHeight: .infinity)
                .background(isHovered ? Color.panelRaised : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// `.topbar`.
private struct TopBar: View {
    let model: AppModel

    @State private var anchor = CGRect.zero

    var body: some View {
        HStack(spacing: 12) {
            configurationMenu
            saveState
            Spacer(minLength: 0)
            if let audio = model.audio {
                AudioFaults(audio: audio)
                ClockReadout(router: audio.router, source: model.settings.clockSource)
                CPUReadout(engine: audio.engine)
            }
            Button("Settings") { model.showSettings() }
                .buttonStyle(.key)
        }
        .padding(.top, 12)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.lineStrong).frame(height: 1) }
    }

    private var name: String {
        guard let name = model.session?.configuration.name, !name.isEmpty else { return "New configuration" }
        return name
    }

    private var configurationMenu: some View {
        Button {
            model.showConfigurationMenu(anchor: anchor)
        } label: {
            HStack(spacing: 6) {
                Text(name)
                    .font(.panelDisplay(27))
                    .panelSpacing(0.05, size: 27)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .foregroundStyle(Color.legend)
                Text("▾")
                    .font(.panelText(15))
                    .foregroundStyle(Color.muted)
                    .padding(.top, 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .panelMenuAnchor($anchor)
    }

    @ViewBuilder private var saveState: some View {
        if let session = model.session {
            if session.isDirty {
                Text("Unsaved changes").font(.panelText(13)).foregroundStyle(Color.muted)
                Button("Save") { model.saveCurrent() }.buttonStyle(.key)
            } else if session.isSaved {
                Text("Saved").font(.panelText(13)).foregroundStyle(Color.muted)
            }
        }
    }
}

/// `.readout`.
private struct Readout<Lead: View>: View {
    let text: String
    @ViewBuilder let lead: Lead
    var color = Color.muted

    var body: some View {
        HStack(spacing: 6) {
            lead
            Text(text)
        }
        .font(.panelText(13))
        .monospacedDigit()
        .foregroundStyle(color)
        .lineLimit(1)
        .fixedSize()
    }
}

/// Why nothing is playing, when something is wrong with the audio device.
struct AudioFaults: View {
    let audio: AudioSession

    var body: some View {
        if case .deviceMissing = audio.engine.state {
            Readout(text: "Audio device missing", lead: { LED(tone: .fault) }, color: .fault)
        }
        if audio.startFailure != nil {
            Readout(text: "Audio could not start", lead: { LED(tone: .fault) }, color: .fault)
                .help(audio.startFailure ?? "")
        }
    }
}

private struct ClockReadout: View {
    let router: MIDIRouter
    let source: String?

    var body: some View {
        if router.clockRunning, let source {
            Readout(text: "\(source) clock, \(String(format: "%.1f", router.tempo)) BPM") {
                BeatLED(tempo: router.tempo)
            }
        } else {
            Readout(text: "No MIDI clock") { LED(tone: .off) }
        }
    }
}

/// `.led.beat`: lit for half of each beat.
private struct BeatLED: View {
    let tempo: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let half = 30 / max(tempo, 1)
        TimelineView(.periodic(from: .now, by: half)) { timeline in
            let lit = reduceMotion || Int(timeline.date.timeIntervalSinceReferenceDate / half) % 2 == 0
            LED().opacity(lit ? 1 : 0.15)
        }
    }
}

/// Polls the engine's load itself, so the screen around it does not redraw.
private struct CPUReadout: View {
    let engine: AudioEngine

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Readout(text: "CPU \(Int((engine.dspLoad * 100).rounded())) %") { EmptyView() }
        }
    }
}
