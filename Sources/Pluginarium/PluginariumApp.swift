import AppKit
import SwiftUI

@main
struct PluginariumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Pluginarium", id: "main") {
            RootView(model: delegate.model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 760)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        #if DEBUG
        // For looking at the mixer without clicking: --open "<configuration name>".
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--open"), arguments.indices.contains(flag + 1),
           let configuration = model.configurations.first(where: { $0.name == arguments[flag + 1] }) {
            model.load(configuration)
        }
        // For looking at the Add dialog: --add opens a new configuration, and --recent <subtypes>
        // puts test units (manufacturer "Plug") first in the list, so nothing third party is selected.
        if let flag = arguments.firstIndex(of: "--recent"), arguments.indices.contains(flag + 1) {
            let subtypes = arguments[flag + 1].split(separator: ",").map(String.init)
            model.settings.recentPlugins = subtypes.compactMap { subtype in
                model.installedPlugins.first { $0.id.subtype == subtype && $0.id.manufacturer == "Plug" }?.id
            }
        }
        if arguments.contains("--add") { model.newConfiguration() }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.close()
    }
}

private struct RootView: View {
    let model: AppModel

    @State private var titleBarHeight: CGFloat = 0

    var body: some View {
        WalnutFrame {
            switch model.screen {
            case .start:
                StartScreen(model: model)
            case .mixer:
                MixerScreen(model: model)
            case .settings:
                PlaceholderScreen(title: "Settings") {
                    Button("Back") { model.closeSettings() }.buttonStyle(.key)
                }
            }
        }
        .focusEffectDisabled()
        .addDialog(model)
        .choiceDialog(Binding(get: { model.dialog }, set: { model.dialog = $0 }))
        // The window adds the title bar to this, and its minimum is for the whole window.
        .frame(minWidth: 900, minHeight: 600 - titleBarHeight)
        .onGeometryChange(for: CGFloat.self, of: \.safeAreaInsets.top) { titleBarHeight = $0 }
        .preferredColorScheme(.dark)
    }
}

/// Stands in for the screens that come later.
private struct PlaceholderScreen<Action: View>: View {
    let title: String
    @ViewBuilder let action: Action

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.panelDisplay(27))
                .panelSpacing(0.05, size: 27)
                .textCase(.uppercase)
                .foregroundStyle(Color.legend)
            action
        }
    }
}
