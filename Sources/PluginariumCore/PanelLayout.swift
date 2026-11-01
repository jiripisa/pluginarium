import CoreGraphics

/// Where things open on the panel.
public enum PanelLayout {

    /// For a view that reports no size at all.
    public static let fallbackPluginWindowSize = CGSize(width: 400, height: 300)

    /// `openMenu`: under the anchor, kept inside the window, with the top left corner last to give way.
    public static func menuOrigin(anchor: CGRect, menu: CGSize, window: CGSize) -> CGPoint {
        CGPoint(
            x: max(26, min(anchor.minX, window.width - menu.width - 26)),
            y: max(12, min(anchor.maxY + 4, window.height - menu.height - 12))
        )
    }

    /// `AUViewController` views often have a zero frame, so the view owner's preferred size and then
    /// the view's fitting size stand in for it.
    public static func pluginWindowSize(frame: CGSize, preferred: CGSize?, fitting: CGSize) -> CGSize {
        [frame, preferred ?? .zero, fitting].first { $0.width > 0 && $0.height > 0 } ?? fallbackPluginWindowSize
    }

    /// `openWindow`: from the top left of the mixer, each window a step further, six steps around.
    public static func pluginWindowOffset(_ count: Int) -> CGPoint {
        let step = CGFloat(count % 6)
        return CGPoint(x: 240 + step * 34, y: 90 + step * 30)
    }
}
