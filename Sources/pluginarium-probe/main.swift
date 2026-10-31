import AppKit
import Foundation
import PluginariumAudio
import PluginariumCore
import PluginariumTestUnits

// Developer probe for the audio layer. Renders no audio.
//   pluginarium-probe recall <type> <subtype> <manufacturer> <file>
// Shows the plugin window; on close writes the plugin state to <file>. When <file> exists,
// the state is restored before the window opens.

func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

let arguments = CommandLine.arguments
guard arguments.count == 6, arguments[1] == "recall", arguments[2...4].allSatisfy({ $0.utf8.count == 4 }) else {
    fail("usage: pluginarium-probe recall <type> <subtype> <manufacturer> <file>  (codes are 4 characters)", status: 2)
}
let id = PluginID(type: arguments[2], subtype: arguments[3], manufacturer: arguments[4])
let stateURL = URL(fileURLWithPath: arguments[5])

@MainActor
final class ProbeDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let plugin: HostedPlugin
    private let window: NSWindow
    private var saved = false

    init(plugin: HostedPlugin, view: NSView) {
        self.plugin = plugin
        let size = view.frame.size
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        super.init()
        window.title = "\(id.type) \(id.subtype) \(id.manufacturer)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = view
        view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewFrameChanged(_:)), name: NSView.frameDidChangeNotification, object: view
        )
        window.center()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func viewFrameChanged(_ notification: Notification) {
        guard let view = notification.object as? NSView, view === window.contentView else { return }
        window.setContentSize(view.frame.size)
    }

    func windowWillClose(_ notification: Notification) {
        guard !saved else { return }
        saved = true
        do {
            try plugin.fullState().write(to: stateURL, options: .atomic)
            print("state written to \(stateURL.path)")
        } catch {
            FileHandle.standardError.write(Data("could not write state: \(error)\n".utf8))
        }
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
func run() async {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    do {
        let plugin = try await HostedPlugin.load(id)
        try plugin.configure(sampleRate: 48_000, maxFrames: 4096)
        if let state = try? Data(contentsOf: stateURL) {
            try plugin.restore(state)
            print("state restored from \(stateURL.path)")
        }
        guard let view = await plugin.makeView() else {
            fail("\(id.type) \(id.subtype) \(id.manufacturer) has no view", status: 1)
        }
        let delegate = ProbeDelegate(plugin: plugin, view: view)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    } catch {
        fail("probe failed: \(error)", status: 1)
    }
}

await run()
