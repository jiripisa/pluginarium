import AppKit
import SwiftUI

@main
struct PluginariumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var updates = UpdateService()

    var body: some Scene {
        Window("Pluginarium", id: "main") {
            RootView(model: delegate.model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 760)
        .commands { AppCommands(model: delegate.model, updates: updates) }
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

    /// Unsaved changes are asked about before the app goes. The answer comes through the dialog in the
    /// window, so the window is brought forward for it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.askBeforeQuitting(reply: { NSApp.reply(toApplicationShouldTerminate: $0) }) { return .terminateNow }
        NSApp.activate()
        NSApp.windows.first { $0.title == "Pluginarium" }?.makeKeyAndOrderFront(nil)
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.close()
    }
}

/// New configuration, Save and Save as in the File menu, and Settings in the app menu. They are off
/// while a question is open and where they do not apply. Check for Updates sits next to About.
private struct AppCommands: Commands {
    let model: AppModel
    let updates: UpdateService

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.checkNow() }
                .disabled(!updates.canCheck)
        }
        CommandGroup(replacing: .newItem) {
            Button("New configuration") { model.leave { model.newConfiguration() } }
                .disabled(!model.commandsAvailable)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.saveIfChanged() }
                .keyboardShortcut("s")
                .disabled(!model.commandsAvailable || !(model.session?.isDirty == true || (model.session != nil && model.hasOpenPluginWindows)))
            Button("Save as") { model.beginSaveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!model.commandsAvailable || model.session == nil)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.showSettings() }
                .keyboardShortcut(",")
                .disabled(!model.commandsAvailable)
        }
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
                SettingsScreen(model: model)
            }
        }
        .focusEffectDisabled()
        .panelMenuBackdrop(model)
        .addDialog(model)
        .nameDialog(Binding(get: { model.nameDialog }, set: { model.nameDialog = $0 }))
        .choiceDialog(Binding(get: { model.dialog }, set: { model.dialog = $0 }))
        .toast(model.toast)
        .onChange(of: model.hidesPluginWindows) { _, hidden in model.pluginWindows.setHidden(hidden) }
        // The window adds the title bar to this, and its minimum is for the whole window.
        .frame(minWidth: 900, minHeight: 600 - titleBarHeight)
        .onGeometryChange(for: CGFloat.self, of: \.safeAreaInsets.top) { titleBarHeight = $0 }
        .preferredColorScheme(.dark)
    }
}
