import CoreGraphics
import Testing
@testable import PluginariumCore

struct PanelLayoutTests {
    private let window = CGSize(width: 1280, height: 760)
    private let menu = CGSize(width: 320, height: 200)

    @Test func aMenuOpensUnderItsAnchor() {
        let anchor = CGRect(x: 43, y: 188, width: 164, height: 22)
        #expect(PanelLayout.menuOrigin(anchor: anchor, menu: menu, window: window) == CGPoint(x: 43, y: 214))
    }

    @Test func aMenuStaysInsideTheRightEdge() {
        let anchor = CGRect(x: 1200, y: 100, width: 60, height: 20)
        #expect(PanelLayout.menuOrigin(anchor: anchor, menu: menu, window: window).x == 934)
    }

    @Test func aMenuStaysInsideTheBottomEdge() {
        let anchor = CGRect(x: 100, y: 700, width: 60, height: 20)
        #expect(PanelLayout.menuOrigin(anchor: anchor, menu: menu, window: window).y == 548)
    }

    @Test func aMenuTallerThanTheWindowKeepsItsTopInside() {
        let anchor = CGRect(x: 100, y: 100, width: 60, height: 20)
        let origin = PanelLayout.menuOrigin(anchor: anchor, menu: CGSize(width: 2000, height: 2000), window: window)
        #expect(origin == CGPoint(x: 26, y: 12))
    }

    @Test func aViewWithAFrameKeepsIt() {
        let size = PanelLayout.pluginWindowSize(frame: CGSize(width: 500, height: 300), preferred: CGSize(width: 1, height: 1), fitting: CGSize(width: 2, height: 2))
        #expect(size == CGSize(width: 500, height: 300))
    }

    @Test func aViewWithoutAFrameTakesThePreferredSize() {
        let size = PanelLayout.pluginWindowSize(frame: .zero, preferred: CGSize(width: 640, height: 480), fitting: CGSize(width: 2, height: 2))
        #expect(size == CGSize(width: 640, height: 480))
    }

    @Test func noPreferredSizeLeavesTheFittingSize() {
        #expect(PanelLayout.pluginWindowSize(frame: .zero, preferred: nil, fitting: CGSize(width: 320, height: 200)) == CGSize(width: 320, height: 200))
        #expect(PanelLayout.pluginWindowSize(frame: .zero, preferred: .zero, fitting: CGSize(width: 320, height: 200)) == CGSize(width: 320, height: 200))
    }

    @Test func aSizeWithOneZeroSideIsNoSize() {
        let size = PanelLayout.pluginWindowSize(frame: CGSize(width: 500, height: 0), preferred: nil, fitting: CGSize(width: 320, height: 200))
        #expect(size == CGSize(width: 320, height: 200))
    }

    @Test func aViewWithNoSizeAtAllStillGetsAWindow() {
        #expect(PanelLayout.pluginWindowSize(frame: .zero, preferred: nil, fitting: .zero) == PanelLayout.fallbackPluginWindowSize)
    }

    @Test func windowsCascadeFromTheMixerAndComeBackAroundAfterSix() {
        #expect(PanelLayout.pluginWindowOffset(0) == CGPoint(x: 240, y: 90))
        #expect(PanelLayout.pluginWindowOffset(2) == CGPoint(x: 308, y: 150))
        #expect(PanelLayout.pluginWindowOffset(6) == CGPoint(x: 240, y: 90))
    }
}
