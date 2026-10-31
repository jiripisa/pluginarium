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
                PlaceholderScreen(title: mixerTitle) {
                    Button("Settings") { model.showSettings() }.buttonStyle(.key)
                }
            case .settings:
                PlaceholderScreen(title: "Settings") {
                    Button("Back") { model.closeSettings() }.buttonStyle(.key)
                }
            }
        }
        .focusEffectDisabled()
        // The window adds the title bar to this, and its minimum is for the whole window.
        .frame(minWidth: 900, minHeight: 600 - titleBarHeight)
        .onGeometryChange(for: CGFloat.self, of: \.safeAreaInsets.top) { titleBarHeight = $0 }
        .preferredColorScheme(.dark)
    }

    private var mixerTitle: String {
        guard let name = model.session?.configuration.name, !name.isEmpty else { return "New configuration" }
        return name
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
