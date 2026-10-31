import AppKit
import CRenderCore
import Foundation
import PluginariumAudio
import PluginariumCore
import PluginariumTestUnits

// Developer probe for the audio layer.
//   pluginarium-probe recall <type> <subtype> <manufacturer> <file>
// Shows the plugin window; on close writes the plugin state to <file>. When <file> exists,
// the state is restored before the window opens. Renders no audio.
//   pluginarium-probe play <type> <subtype> <manufacturer>
// Holds a C for 4 seconds on the default output, which has to be the MacBook's own. Sets nothing
// on the device: it plays at the device's current sample rate and buffer size.

let noteOn: UInt8 = 0x90
let noteOff: UInt8 = 0x80
let middleC: UInt8 = 60
let noteVelocity: UInt8 = 100
let noteSeconds = 4

func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

let usage = """
    usage: pluginarium-probe recall <type> <subtype> <manufacturer> <file>
           pluginarium-probe play <type> <subtype> <manufacturer>
           (codes are 4 characters)
    """

let arguments = CommandLine.arguments
let isRecall = arguments.count == 6 && arguments[1] == "recall"
let isPlay = arguments.count == 5 && arguments[1] == "play"
guard isRecall || isPlay, arguments[2...4].allSatisfy({ $0.utf8.count == 4 }) else {
    fail(usage, status: 2)
}
let id = PluginID(type: arguments[2], subtype: arguments[3], manufacturer: arguments[4])

@MainActor
final class ProbeDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let plugin: HostedPlugin
    private let window: NSWindow
    private let stateURL: URL
    private var saved = false

    init(plugin: HostedPlugin, view: NSView, stateURL: URL) {
        self.plugin = plugin
        self.stateURL = stateURL
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
func recall(stateURL: URL) async {
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
        let delegate = ProbeDelegate(plugin: plugin, view: view, stateURL: stateURL)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    } catch {
        fail("probe failed: \(error)", status: 1)
    }
}

@MainActor
func play() async {
    guard let device = DeviceCatalog.defaultOutput() else { fail("no default output device", status: 1) }
    print("device: \(device.name)")
    guard device.name.contains("MacBook") else {
        fail("refusing to play on \(device.name): the default output has to be the MacBook's own", status: 1)
    }
    guard let current = DeviceCatalog.currentSettings(of: device) else {
        fail("cannot read the settings of \(device.name)", status: 1)
    }

    let engine = AudioEngine()
    let runner = ConfigurationRunner(
        engine: engine.renderEngine, sampleRate: current.sampleRate, maxFrames: AudioEngine.maxFrames,
        deviceInputs: device.inputChannels.count, deviceOutputs: device.outputChannels.count,
        cache: CapabilityCache(file: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json"))
    )
    let channel = Channel(kind: .instrument, slot: PluginSlot(plugin: id, displayName: id.subtype), audioOut: .stereo(left: 0, right: 1))
    await runner.apply(Configuration(name: "Probe", channels: [channel]))
    let status = runner.status[channel.id]
    guard status == .ready, let slot = runner.midiSlot(channel: channel.id) else {
        fail("\(id.type) \(id.subtype) \(id.manufacturer) cannot play: \(String(describing: status))", status: 1)
    }

    var settings = AppSettings.defaults
    settings.audioDeviceUID = device.id
    settings.sampleRate = current.sampleRate
    settings.bufferFrames = Int(current.bufferFrames)
    do {
        try engine.start(settings: settings)
    } catch {
        fail("cannot start \(device.name): \(error)", status: 1)
    }
    guard case .running = engine.state else { fail("\(device.name) did not start", status: 1) }

    pr_engine_push_midi(engine.renderEngine, slot, noteOn, middleC, noteVelocity)
    for _ in 0..<noteSeconds {
        try? await Task.sleep(for: .seconds(1))
        print("dspLoad \(engine.dspLoad)")
    }
    pr_engine_push_midi(engine.renderEngine, slot, noteOff, middleC, 0)
    // The next block delivers the note off, so it has to run before audio stops.
    try? await Task.sleep(for: .milliseconds(200))

    engine.stop()
    // The runner only holds the engine's pointer, so the engine has to outlive this call.
    withExtendedLifetime(engine) { runner.shutDown() }
}

if isPlay {
    await play()
} else {
    await recall(stateURL: URL(fileURLWithPath: arguments[5]))
}
