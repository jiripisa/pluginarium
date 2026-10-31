import AppKit
import PluginariumAudio
import PluginariumCore
import SwiftUI

/// The plugins' own windows, at most one for each plugin. They show what `ConfigurationRunner` runs
/// and leave the plugin's life to it. A window holds on to its plugin only while it is open, so the
/// view goes before the unit, and everything that takes a plugin away closes its window first.
@MainActor
@Observable
final class PluginWindows {
    private var windows: [PluginLocation: PluginWindow] = [:]

    @ObservationIgnored private var opened = 0
    @ObservationIgnored private var isHidden = false
    @ObservationIgnored private unowned let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    func isOpen(channel: UUID, effect: UUID?) -> Bool {
        windows[PluginLocation(channel: channel, effect: effect)] != nil
    }

    /// Opens the plugin's window, or closes it the way its red button does.
    func toggle(channel: UUID, effect: UUID?) {
        let location = PluginLocation(channel: channel, effect: effect)
        if let window = windows[location] {
            window.close()
            return
        }
        guard let plugin = app.hostedPlugin(at: location), let slot = app.session?.configuration.slot(at: location) else { return }
        let window = PluginWindow(plugin: plugin, title: slot.displayName, cascade: opened, isHidden: isHidden) { [weak self] opened, closed in
            self?.windows[location] = nil
            self?.app.notePluginState(at: location, opened: opened, closed: closed)
        }
        opened += 1
        windows[location] = window
        Task { await window.show() }
    }

    /// Takes the windows off the screen and brings them back where they were. They stay open all the
    /// while, and one that closes in the meantime stays closed.
    func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        isHidden = hidden
        if hidden {
            windows.values.forEach { $0.hide() }
        } else {
            windows.values.sorted { $0.stackPosition > $1.stackPosition }.forEach { $0.reveal() }
        }
    }

    /// Reads what the open windows have done to their plugins, without closing them.
    func noteChanges() {
        for (location, window) in windows {
            app.notePluginState(at: location, opened: window.stateOnOpening, closed: try? window.plugin.fullState())
        }
    }

    /// Closes the windows of plugins that have left `configuration`. Their state goes with them.
    func closeWindowsOfPluginsGone(from configuration: Configuration) {
        for (location, window) in windows where !configuration.holds(window.plugin.id, at: location) {
            window.closeWithoutReadingState()
        }
    }

    /// For when every plugin goes. Nothing can use the state they are in.
    func closeAll() {
        windows.values.forEach { $0.closeWithoutReadingState() }
    }
}

/// One plugin's `NSWindow`, which takes the size the plugin gives its view.
@MainActor
private final class PluginWindow: NSObject, NSWindowDelegate {
    let plugin: HostedPlugin
    /// What the plugin was doing when the window opened.
    let stateOnOpening: Data?
    /// Where it stood among the app's windows when it was hidden, front first.
    private(set) var stackPosition = 0

    private let title: String
    private let cascade: Int
    private let onClose: (_ opened: Data?, _ closed: Data?) -> Void
    private var window: NSWindow?
    private var view: NSView?
    private weak var mixer: NSWindow?
    private var preferredSize: NSKeyValueObservation?
    private var isHidden: Bool
    private var isOpening = true
    private var isClosed = false
    private var readsStateOnClose = true

    init(plugin: HostedPlugin, title: String, cascade: Int, isHidden: Bool, onClose: @escaping (_ opened: Data?, _ closed: Data?) -> Void) {
        self.plugin = plugin
        stateOnOpening = try? plugin.fullState()
        self.title = title
        self.cascade = cascade
        self.isHidden = isHidden
        self.onClose = onClose
    }

    /// A plugin can take seconds to hand over its view, and can go in the meantime.
    func show() async {
        let view = await plugin.makeView()
        isOpening = false
        guard !isClosed else {
            plugin.releaseView()
            return
        }
        let content = view.map(sized) ?? noWindowNote()
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: content.frame.size), styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = title
        window.contentView = content
        window.delegate = self
        self.window = window
        self.view = view
        follow(view)
        place(window)
        if !isHidden {
            attach(window)
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Closes it as Close plugin and the red button do. A window still waiting for its view stays,
    /// so a plugin never answers two requests at once.
    func close() {
        guard !isOpening else { return }
        window?.close()
        // A window that is off the screen may not hear of its own closing.
        finish()
    }

    func closeWithoutReadingState() {
        readsStateOnClose = false
        window?.close()
        finish()
    }

    func hide() {
        isHidden = true
        guard let window else { return }
        stackPosition = window.orderedIndex
        let hadKeyboard = window.isKeyWindow
        mixer?.removeChildWindow(window)
        window.orderOut(nil)
        if hadKeyboard { mixer?.makeKey() }
    }

    func reveal() {
        isHidden = false
        if let window { attach(window) }
    }

    func windowWillClose(_ notification: Notification) {
        finish()
    }

    // MARK: - Private

    /// The view inside a container, so the window sizes the container and the view stays the plugin's.
    private func sized(_ view: NSView) -> NSView {
        let size = PanelLayout.pluginWindowSize(
            frame: view.frame.size, preferred: plugin.viewController?.preferredContentSize, fitting: view.fittingSize
        )
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.autoresizesSubviews = false
        view.setFrameOrigin(.zero)
        view.setFrameSize(size)
        container.addSubview(view)
        return container
    }

    private func noWindowNote() -> NSView {
        let note = NSHostingView(rootView: NoWindowNote())
        note.setFrameSize(note.fittingSize)
        return note
    }

    /// The prototype's cascade over the mixer.
    private func place(_ window: NSWindow) {
        guard let mixer = NSApp.mainWindow.map({ $0.parent ?? $0 }) else {
            window.center()
            return
        }
        self.mixer = mixer
        let offset = PanelLayout.pluginWindowOffset(cascade)
        window.setFrameTopLeftPoint(NSPoint(x: mixer.frame.minX + offset.x, y: mixer.frame.maxY - offset.y))
    }

    /// As a child it stays above the mixer at the normal level.
    private func attach(_ window: NSWindow) {
        mixer?.addChildWindow(window, ordered: .above)
        window.orderFront(nil)
    }

    /// A plugin resizes by changing its view's frame or its controller's preferred size.
    private func follow(_ view: NSView?) {
        guard let view else { return }
        view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewFrameChanged), name: NSView.frameDidChangeNotification, object: view)
        preferredSize = plugin.viewController?.observe(\.preferredContentSize) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.preferredSizeChanged() }
        }
    }

    private func preferredSizeChanged() {
        guard let size = plugin.viewController?.preferredContentSize, size.width > 0, size.height > 0 else { return }
        view?.setFrameSize(size)
    }

    @objc private func viewFrameChanged() {
        guard let window, let size = view?.frame.size, size.width > 0, size.height > 0, window.contentView?.frame.size != size else { return }
        // Grows and shrinks from the bottom, so the title bar stays under the pointer.
        let resized = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        let top = window.frame.maxY
        window.setFrame(NSRect(x: window.frame.minX, y: top - resized.height, width: resized.width, height: resized.height), display: true)
    }

    private func finish() {
        guard !isClosed else { return }
        isClosed = true
        NotificationCenter.default.removeObserver(self)
        preferredSize = nil
        let closed = readsStateOnClose ? try? plugin.fullState() : nil
        if let window {
            window.delegate = nil
            window.parent?.removeChildWindow(window)
            window.contentView = nil
            // AppKit is still inside `close`, so the window has to outlive this call.
            DispatchQueue.main.async { [window] in _ = window }
        }
        view?.removeFromSuperview()
        view = nil
        window = nil
        if !isOpening { plugin.releaseView() }
        onClose(stateOnOpening, closed)
    }
}

/// `makeView` gave nothing.
private struct NoWindowNote: View {
    var body: some View {
        Text("This plugin has no window")
            .font(.panelText(14))
            .foregroundStyle(Color.muted)
            .frame(width: 280, height: 80)
            .background(Color.panel)
    }
}
