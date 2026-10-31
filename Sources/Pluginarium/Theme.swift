import SwiftUI

// The synth front panel of `ui-prototype/styles.css`, whose sizes and colors these are.

extension Color {
    static let panel = Color(hex: 0x2A2B2E)
    static let panelDeep = Color(hex: 0x191A1C)
    static let panelRaised = Color(hex: 0x333438)
    static let legend = Color(hex: 0xECE8DC)
    static let muted = Color(hex: 0xA9A698)
    static let line = Color(hex: 0x55554F)
    static let lineStrong = Color(hex: 0x8F8C80)
    static let led = Color(hex: 0xFF8A1F)
    static let ledSoft = Color(hex: 0xFFB066)
    static let fault = Color(hex: 0xFF6A52)
    static let walnut = Color(hex: 0x6D4529)
    static let walnutDark = Color(hex: 0x553420)

    private init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double(hex >> 16 & 0xFF) / 255,
            green: Double(hex >> 8 & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension Font {
    /// DIN Condensed, for names. macOS ships it in bold only.
    static func panelDisplay(_ size: CGFloat) -> Font { .custom("DINCondensed-Bold", fixedSize: size) }
    /// DIN Alternate, for everything else. macOS ships it in bold only.
    static func panelText(_ size: CGFloat) -> Font { .custom("DINAlternate-Bold", fixedSize: size) }
}

extension View {
    /// CSS letter spacing, given in em for a font of `size`.
    func panelSpacing(_ em: CGFloat, size: CGFloat) -> some View {
        tracking(em * size)
    }
}

/// `:focus-visible`: amber instead of the system's blue ring, which the window turns off.
private struct FocusOutline: ViewModifier {
    let outset: CGFloat

    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content.overlay {
            if isFocused {
                Rectangle().strokeBorder(Color.led, lineWidth: 2).padding(-outset)
            }
        }
    }
}

extension View {
    /// For the label of a control that can take keyboard focus. `outset` is the prototype's 2 pt
    /// gap and its 2 pt outline; a row in a scrolling list has no room for them.
    func panelFocusOutline(outset: CGFloat = 4) -> some View {
        modifier(FocusOutline(outset: outset))
    }
}

/// `.key`. Use `.key` or `KeyButtonStyle.primary`.
struct KeyButtonStyle: ButtonStyle {
    static let primary = KeyButtonStyle(isPrimary: true)

    private static let fontSize: CGFloat = 12.5

    var isPrimary = false

    func makeBody(configuration: Configuration) -> some View {
        KeyLabel(label: configuration.label, isPrimary: isPrimary, isPressed: configuration.isPressed)
    }

    private struct KeyLabel<Label: View>: View {
        let label: Label
        let isPrimary: Bool
        let isPressed: Bool

        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            label
                .font(.panelText(KeyButtonStyle.fontSize))
                .panelSpacing(0.06, size: KeyButtonStyle.fontSize)
                .textCase(.uppercase)
                .lineLimit(1)
                .fixedSize()
                .frame(height: 16.25)
                .foregroundStyle(isPrimary ? Color.panelDeep : Color.legend)
                .padding(.vertical, 5)
                .padding(.horizontal, 12)
                .background(isPrimary ? Color.legend : Color.clear)
                .overlay(Rectangle().strokeBorder(borderColor, lineWidth: 1))
                .contentShape(Rectangle())
                .opacity(isPrimary && !isEnabled ? 0.4 : isPressed ? 0.8 : 1)
                .panelFocusOutline()
                .onHover { isHovered = $0 }
        }

        private var borderColor: Color {
            isPrimary || (isHovered && isEnabled) ? .legend : .lineStrong
        }
    }
}

extension ButtonStyle where Self == KeyButtonStyle {
    static var key: KeyButtonStyle { KeyButtonStyle() }
}

/// `.legend`, the silk-screen label above a control.
struct Legend: View {
    private static let fontSize: CGFloat = 11.5

    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.panelText(Self.fontSize))
            .panelSpacing(0.08, size: Self.fontSize)
            .textCase(.uppercase)
            .foregroundStyle(Color.muted)
            .padding(.bottom, 3)
    }
}

/// `.led`.
struct LED: View {
    var body: some View {
        Circle()
            .fill(Color.led)
            .frame(width: 8, height: 8)
            .shadow(color: .led, radius: 4)
    }
}

/// The panel between its two walnut cheeks. The panel's content stays below the title bar, while
/// the panel and the cheeks run up to the top of the window.
struct WalnutFrame<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            WalnutCheek()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            WalnutCheek()
        }
        .background(Color.panel.ignoresSafeArea())
    }
}

/// `body::before`: 9 pt of grain, repeating along a line 2 degrees off the horizontal, so the stripes
/// lean a little. Distance along that line starts from the top left corner.
private struct WalnutCheek: View {
    private static let width: CGFloat = 18
    private static let period: CGFloat = 9
    private static let darkFrom: CGFloat = 3
    private static let darkTo: CGFloat = 4
    private static let across = sin(92 * CGFloat.pi / 180)
    private static let down = -cos(92 * CGFloat.pi / 180)

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.walnut))
            var distance = -Self.period
            let end = size.width * Self.across + size.height * Self.down
            while distance < end {
                context.fill(stripe(from: distance + Self.darkFrom, to: distance + Self.darkTo, height: size.height), with: .color(.walnutDark))
                distance += Self.period
            }
        }
        .frame(width: Self.width)
        .ignoresSafeArea()
    }

    private func stripe(from start: CGFloat, to end: CGFloat, height: CGFloat) -> Path {
        func x(_ distance: CGFloat, atY y: CGFloat) -> CGFloat { (distance - y * Self.down) / Self.across }
        var path = Path()
        path.move(to: CGPoint(x: x(start, atY: 0), y: 0))
        path.addLine(to: CGPoint(x: x(end, atY: 0), y: 0))
        path.addLine(to: CGPoint(x: x(end, atY: height), y: height))
        path.addLine(to: CGPoint(x: x(start, atY: height), y: height))
        path.closeSubpath()
        return path
    }
}
