import CoreGraphics
import Testing
@testable import AnkiNotchKit

@Suite struct PanelGeometryTests {
    private let notchedScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let notch = CGRect(x: 656, y: 950, width: 200, height: 32)

    @Test func clampsContentHeight() {
        #expect(PanelGeometry.clampedHeight(100) == 160)
        #expect(PanelGeometry.clampedHeight(300) == 300)
        #expect(PanelGeometry.clampedHeight(900) == 560)
    }

    @Test func panelFrameHangsFromTheNotch() {
        let geometry = PanelGeometry(screenFrame: notchedScreen, visibleFrame: notchedScreen,
                                     notch: notch)
        #expect(geometry.hotspot == notch)
        #expect(geometry.panelFrame(contentHeight: 300)
                == CGRect(x: 596, y: 650, width: 320, height: 332))
    }

    @Test func notchlessScreenUsesVirtualNotch() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let geometry = PanelGeometry(screenFrame: screen, visibleFrame: visible, notch: nil)
        #expect(geometry.hotspot == CGRect(x: 860, y: 1055, width: 200, height: 25))
        #expect(geometry.panelFrame(contentHeight: 160)
                == CGRect(x: 800, y: 895, width: 320, height: 185))
    }

    @Test func virtualNotchIs24HighWhenMenuBarAutoHides() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let geometry = PanelGeometry(screenFrame: screen, visibleFrame: screen, notch: nil)
        #expect(geometry.hotspot == CGRect(x: 860, y: 1056, width: 200, height: 24))
    }

    @Test func notchRectFromAuxiliaryAreas() {
        let rect = PanelGeometry.notchRect(
            screenFrame: notchedScreen, safeAreaTop: 32,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 656, height: 32),
            auxiliaryTopRightArea: CGRect(x: 856, y: 950, width: 656, height: 32))
        #expect(rect == notch)
    }

    @Test func notchRectFallsBackTo200WhenAreasMissing() {
        let rect = PanelGeometry.notchRect(screenFrame: notchedScreen, safeAreaTop: 32,
                                           auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil)
        #expect(rect == notch)
    }

    @Test func noNotchWhenSafeAreaIsZero() {
        #expect(PanelGeometry.notchRect(screenFrame: notchedScreen, safeAreaTop: 0,
                                        auxiliaryTopLeftArea: nil,
                                        auxiliaryTopRightArea: nil) == nil)
    }

    @Test func keepsPanelOpenInsideHotspotOrPanelOnly() {
        let panel = CGRect(x: 596, y: 650, width: 320, height: 332)
        func keeps(_ x: CGFloat, _ y: CGFloat) -> Bool {
            PanelGeometry.keepsPanelOpen(mouse: CGPoint(x: x, y: y), hotspot: notch, panel: panel)
        }
        #expect(keeps(756, 966))      // inside the hotspot
        #expect(keeps(700, 700))      // inside the panel
        #expect(keeps(596, 650))      // exactly on the panel's min corner
        #expect(keeps(916, 982))      // exactly on its max corner
        #expect(!keeps(100, 100))
        #expect(!keeps(756, 640))     // just below the panel
    }

    // MARK: Animation stage

    @Test func stageFrameIsTheLargestPanelHangingFromTheNotch() {
        let geometry = PanelGeometry(screenFrame: notchedScreen, visibleFrame: notchedScreen,
                                     notch: notch)
        #expect(geometry.stageFrame == CGRect(x: 596, y: 390, width: 320, height: 592))
        // Every rest frame fits inside it with the same top edge and centre.
        let rest = geometry.panelFrame(contentHeight: 300)
        #expect(geometry.stageFrame.maxY == rest.maxY)
        #expect(geometry.stageFrame.midX == rest.midX)
    }

    @Test func stageFrameOnANotchlessScreenUsesTheVirtualNotch() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let geometry = PanelGeometry(screenFrame: screen, visibleFrame: visible, notch: nil)
        #expect(geometry.stageFrame == CGRect(x: 800, y: 495, width: 320, height: 585))
    }

    @Test func cardSizeIsTheStripPlusTheClampedContent() {
        let geometry = PanelGeometry(screenFrame: notchedScreen, visibleFrame: notchedScreen,
                                     notch: notch)
        #expect(geometry.cardSize(contentHeight: 300) == CGSize(width: 320, height: 332))
        #expect(geometry.cardSize(contentHeight: 10) == CGSize(width: 320, height: 192))
        #expect(geometry.cardSize(contentHeight: 900) == CGSize(width: 320, height: 592))
        #expect(geometry.panelFrame(contentHeight: 300).size
                == geometry.cardSize(contentHeight: 300))
    }
}
