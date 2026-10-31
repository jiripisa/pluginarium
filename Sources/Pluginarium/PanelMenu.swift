import AppKit
import PluginariumCore
import SwiftUI

/// A menu on screen, `.menu` of `ui-prototype/styles.css`. A system menu can show neither its legends
/// and hints nor the amber of the current entry.
struct PanelMenu: Identifiable {
    let id = UUID()
    /// What it opens under, in the coordinates of the mixer window, measured with `panelMenuAnchor`.
    var anchor: CGRect
    var entries: [MenuEntry<() -> Void>]
}

extension View {
    /// Keeps `anchor` on this view's frame, for a menu to open under.
    func panelMenuAnchor(_ anchor: Binding<CGRect>) -> some View {
        onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { anchor.wrappedValue = $0 }
    }

    /// While a menu is open, a click anywhere else on the mixer only closes it.
    func panelMenuBackdrop(_ model: AppModel) -> some View {
        overlay {
            if model.menu != nil {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.closeMenu() }
            }
        }
    }
}

/// Holds the menu on screen. It has a window of its own because plugin windows sit above the mixer,
/// and a menu goes above those as well, as in the prototype.
@MainActor
final class PanelMenuWindow: NSObject, NSWindowDelegate {

    /// A window without a title bar takes the keyboard only when it says it can.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let close: () -> Void
    private var panel: NSPanel?
    /// Gets the keyboard back from the menu.
    private weak var keyBefore: NSWindow?

    init(close: @escaping () -> Void) {
        self.close = close
    }

    func show(_ menu: PanelMenu) {
        hide()
        guard let mixer = NSApp.mainWindow.map({ $0.parent ?? $0 }) else {
            close()
            return
        }
        let content = NSHostingView(rootView: PanelMenuBox(menu: menu, maxHeight: mixer.frame.height) { [close] action in
            close()
            action?()
        })
        content.setFrameSize(content.fittingSize)
        let origin = PanelLayout.menuOrigin(anchor: menu.anchor, menu: content.frame.size, window: mixer.frame.size)
        let panel = Panel(
            contentRect: NSRect(
                x: mixer.frame.minX + origin.x, y: mixer.frame.maxY - origin.y - content.frame.height,
                width: content.frame.width, height: content.frame.height
            ),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = content
        panel.delegate = self
        keyBefore = NSApp.keyWindow
        mixer.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        self.panel = panel
    }

    func hide() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        let hadKeyboard = panel.isKeyWindow
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if hadKeyboard { keyBefore?.makeKey() }
        // The menu's own button is still running when it asks for this.
        DispatchQueue.main.async { [panel] in _ = panel }
    }

    /// A click on a plugin window, or on another app.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// `.menu`: at least 210 pt wide and at most 320, with arrows, Return, Space and Escape working as the
/// prototype's focused buttons do.
private struct PanelMenuBox: View {
    private static let padding: CGFloat = 4
    private static let border: CGFloat = 1

    let menu: PanelMenu
    /// The height of the window it opens in.
    let maxHeight: CGFloat
    /// Called with the entry's action, or nil to just close.
    let close: ((() -> Void)?) -> Void

    @State private var highlighted: Int?
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                MenuColumn(
                    minWidth: 210 - 2 * (Self.padding + Self.border), maxWidth: 320 - 2 * (Self.padding + Self.border)
                ) {
                    ForEach(Array(menu.entries.enumerated()), id: \.offset) { index, entry in
                        row(entry, at: index).id(index)
                    }
                }
                .padding(Self.padding)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: min(420, maxHeight * 0.8))
            .fixedSize()
            .padding(Self.border)
            .onChange(of: highlighted) { _, index in
                if let index { proxy.scrollTo(index) }
            }
        }
        .background(Color.panelMenu)
        .overlay(Rectangle().strokeBorder(Color.lineStrong, lineWidth: Self.border))
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(by: 1) }
        .onKeyPress(.upArrow) { move(by: -1) }
        .onKeyPress(.return) { activate() }
        .onKeyPress(.space) { activate() }
        .onKeyPress(.escape) {
            close(nil)
            return .handled
        }
        .onAppear {
            highlighted = actions.first
            isFocused = true
        }
    }

    /// The lines that can be chosen, by their index in the menu.
    private var actions: [Int] {
        menu.entries.indices.filter { index in
            if case .item(_, _, _, true) = menu.entries[index] { return true }
            return false
        }
    }

    private func move(by step: Int) -> KeyPress.Result {
        let actions = actions
        guard !actions.isEmpty else { return .handled }
        if let highlighted, let position = actions.firstIndex(of: highlighted) {
            self.highlighted = actions[(position + step + actions.count) % actions.count]
        } else {
            highlighted = step > 0 ? actions.first : actions.last
        }
        return .handled
    }

    private func activate() -> KeyPress.Result {
        if let highlighted, case .item(_, let action, _, true) = menu.entries[highlighted] { close(action) }
        return .handled
    }

    @ViewBuilder private func row(_ entry: MenuEntry<() -> Void>, at index: Int) -> some View {
        switch entry {
        case .legend(let text):
            Legend(text)
                .padding(.top, 6)
                .padding(.bottom, -1)
                .padding(.horizontal, 8)
        case .hint(let text):
            Text(text)
                .font(.panelText(13))
                .foregroundStyle(Color.muted)
                .padding(.top, 4)
                .padding(.bottom, 6)
                .padding(.horizontal, 8)
        case .separator:
            Rectangle()
                .fill(Color.line)
                .frame(height: 1)
                .padding(.vertical, 4)
        case .item(let title, let action, let isCurrent, let isEnabled):
            Button { close(action) } label: {
                Text(title)
                    .font(.panelText(14))
                    .foregroundStyle(isEnabled ? isCurrent ? Color.ledSoft : Color.legend : Color.muted.opacity(0.6))
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(highlighted == index ? Color.panelRaised : Color.clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disabled(!isEnabled)
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            .onHover { isHovered in
                if isHovered, isEnabled { highlighted = index }
            }
        }
    }
}

/// The lines of a menu, as wide as the widest wants to be between two limits. Text wraps at that width.
private struct MenuColumn: Layout {
    let minWidth: CGFloat
    let maxWidth: CGFloat

    private func width(of subviews: Subviews) -> CGFloat {
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return min(max(widest, minWidth), maxWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = width(of: subviews)
        let offered = ProposedViewSize(width: width, height: nil)
        return CGSize(width: width, height: subviews.reduce(0) { $0 + $1.sizeThatFits(offered).height })
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let offered = ProposedViewSize(width: bounds.width, height: nil)
        var y = bounds.minY
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: offered)
            y += subview.sizeThatFits(offered).height
        }
    }
}
