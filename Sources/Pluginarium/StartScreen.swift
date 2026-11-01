import AppKit
import PluginariumCore
import SwiftUI

/// Launching always opens this screen, and the owner picks what to load.
struct StartScreen: View {
    private static let powerFontSize: CGFloat = 12.5
    private static let wordmarkFontSize: CGFloat = 76

    let model: AppModel

    var body: some View {
        HStack(spacing: 48) {
            masthead.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 16) {
                ConfigurationList(model: model)
                actions
            }
            .frame(maxWidth: 480)
            .layoutPriority(1)
        }
        .frame(maxWidth: 1040)
        .padding(.horizontal, 14)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onAppear {
            // Macs with keyboard navigation on focus the first row, which nobody asked for.
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pluginarium")
                .font(.panelDisplay(Self.wordmarkFontSize))
                .panelSpacing(0.04, size: Self.wordmarkFontSize)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(Color.legend)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: 68.4)
            Text("Your plugins as instruments in the studio.")
                .font(.panelText(15))
                .foregroundStyle(Color.muted)
                .frame(height: 19.5)
                .padding(.top, 14)
            HStack(spacing: 8) {
                LED()
                Text("Ready")
                    .font(.panelText(Self.powerFontSize))
                    .panelSpacing(0.08, size: Self.powerFontSize)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.muted)
            }
            .frame(height: 18.2)
            .padding(.top, 26)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("New configuration") { model.newConfiguration() }
                .buttonStyle(KeyButtonStyle.primary)
            Button("Settings") { model.showSettings() }
                .buttonStyle(.key)
        }
    }
}

/// Hugs its rows, and scrolls once they no longer fit.
private struct ConfigurationList: View {
    let model: AppModel

    var body: some View {
        ViewThatFits(in: .vertical) {
            rows
            ScrollView { rows }.scrollIndicators(.never)
        }
        .overlay(alignment: .top) { Rectangle().fill(Color.lineStrong).frame(height: 1) }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            if model.configurations.isEmpty {
                ConfigurationRowText(
                    name: "No configurations yet",
                    detail: "Choose New configuration to set up your first one."
                )
            }
            ForEach(model.configurations) { configuration in
                ConfigurationRow(configuration: configuration) { model.load(configuration) }
            }
        }
    }
}

private struct ConfigurationRow: View {
    let configuration: Configuration
    let open: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            ConfigurationRowText(name: configuration.name, detail: configuration.summary)
                .background(isHovered ? Color.panelRaised : Color.clear)
                .contentShape(Rectangle())
                .panelFocusOutline(outset: 0)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// `.config-row`.
private struct ConfigurationRowText: View {
    private static let nameFontSize: CGFloat = 24

    let name: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name)
                .font(.panelDisplay(Self.nameFontSize))
                .panelSpacing(0.04, size: Self.nameFontSize)
                .textCase(.uppercase)
                .lineLimit(1)
                .foregroundStyle(Color.legend)
                .frame(height: 25.2)
            Text(detail)
                .font(.panelText(13))
                .lineLimit(1)
                .foregroundStyle(Color.muted)
                .frame(height: 18.8)
        }
        .padding(.vertical, 11)
        .padding(.bottom, 1)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 1) }
    }
}
