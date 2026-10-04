import CoreGraphics
import Testing
@testable import AnkiNotchKit

@Suite struct PanelGeometryTests {
    private let notchedScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let notch = CGRect(x: 656, y: 950, width: 200, height: 32)

    @Test func thePanelHugsTheContentAndIsBoundedOnlyByTheScreen() {
        let geometry = PanelGeometry(screenFrame: notchedScreen, visibleFrame: notchedScreen,
                                     notch: notch)
        #expect(geometry.availableHeight == 982)  // top of the screen to the bottom of the usable area
        // The content height is the page's own: no minimum, no arbitrary maximum.
        #expect(geometry.contentAreaHeight(for: 0) == 0)
        #expect(geometry.contentAreaHeight(for: 100) == 100)
        #expect(geometry.contentAreaHeight(for: 900) == 900)
        // Only the screen limits it, and then the card scrolls.
        #expect(geometry.contentAreaHeight(for: 5000) == 982)
        // With the route strip above, that much less fits.
        #expect(geometry.contentAreaHeight(for: 5000, showsRoute: true) == 928)
    }

    @Test func panelFrameHangsFromTheNotch() {
        let geometry = PanelGeometry(screenFrame: notchedScreen, visibleFrame: notchedScreen,
                                     notch: notch)
        #expect(geometry.hotspot == notch)
        #expect(geometry.panelFrame(contentHeight: 300)
                == CGRect(x: 516, y: 682, width: 480, height: 300))
    }

    @Test func notchlessScreenUsesVirtualNotch() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let geometry = PanelGeometry(screenFrame: screen, visibleFrame: visible, notch: nil)
        #expect(geometry.hotspot == CGRect(x: 860, y: 1055, width: 200, height: 25))
        #expect(geometry.panelFrame(contentHeight: 160)
                == CGRect(x: 720, y: 920, width: 480, height: 160))
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
        let panel = CGRect(x: 516, y: 650, width: 480, height: 332)
        func keeps(_ x: CGFloat, _ y: CGFloat) -> Bool {
            PanelGeometry.keepsPanelOpen(mouse: CGPoint(x: x, y: y), hotspot: notch, panel: panel)
        }
        #expect(keeps(756, 966))      // inside the hotspot
        #expect(keeps(700, 700))      // inside the panel
        #expect(keeps(516, 650))      // exactly on the panel's min corner
        #expect(keeps(996, 982))      // exactly on its max corner
        #expect(!keeps(100, 100))
        #expect(!keeps(756, 640))     // just below the panel
    }

    // MARK: Animation stage

    @Test func stageFrameIsTheLargestPanelHangingFromTheNotch() {
        let geometry = PanelGeometry(screenFrame: notchedScreen, visibleFrame: notchedScreen,
                                     notch: notch)
        #expect(geometry.stageFrame == CGRect(x: 516, y: 0, width: 480, height: 982))
        // Every rest frame fits inside it with the same top edge and centre.
        let rest = geometry.panelFrame(contentHeight: 300)
        #expect(geometry.stageFrame.maxY == rest.maxY)
        #expect(geometry.stageFrame.midX == rest.midX)
    }

    @Test func stageFrameOnANotchlessScreenUsesTheVirtualNotch() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let geometry = PanelGeometry(screenFrame: screen, visibleFrame: visible, notch: nil)
        #expect(geometry.stageFrame == CGRect(x: 720, y: 0, width: 480, height: 1080))
    }

    @Test func cardSizeIsTheContentAloneWithTheRouteStripWhenShown() {
        let geometry = PanelGeometry(screenFrame: notchedScreen, visibleFrame: notchedScreen,
                                     notch: notch)
        #expect(geometry.cardSize(contentHeight: 300) == CGSize(width: 480, height: 300))
        #expect(geometry.cardSize(contentHeight: 10) == CGSize(width: 480, height: 10))
        #expect(geometry.cardSize(contentHeight: 900) == CGSize(width: 480, height: 900))
        #expect(geometry.panelFrame(contentHeight: 300).size
                == geometry.cardSize(contentHeight: 300))
    }

    // MARK: Deck route row

    @Test func routeRowAddsItsHeightOutsideTheClamp() {
        let geometry = PanelGeometry(screenFrame: notchedScreen, visibleFrame: notchedScreen,
                                     notch: notch)
        #expect(geometry.cardSize(contentHeight: 300, showsRoute: true)
                == CGSize(width: 480, height: 354))
        // The card area keeps its clamp; the row is extra, not part of it.
        #expect(geometry.cardSize(contentHeight: 900, showsRoute: true).height == 954)
        #expect(geometry.cardSize(contentHeight: 10, showsRoute: true).height == 64)
        #expect(geometry.cardSize(contentHeight: 300, showsRoute: false)
                == geometry.cardSize(contentHeight: 300))
    }

    @Test func routeAwarePanelFrameStaysFlushWithTheTop() {
        let geometry = PanelGeometry(screenFrame: notchedScreen, visibleFrame: notchedScreen,
                                     notch: notch)
        let frame = geometry.panelFrame(contentHeight: 300, showsRoute: true)
        #expect(frame == CGRect(x: 516, y: 628, width: 480, height: 354))
        #expect(frame.maxY == geometry.stageFrame.maxY)
        #expect(geometry.stageFrame.height == geometry.availableHeight)
    }

    @Test func notchClickIsInsideTheHotspotEdgesIncluded() {
        func click(_ x: CGFloat, _ y: CGFloat) -> Bool {
            PanelGeometry.isNotchClick(CGPoint(x: x, y: y), hotspot: notch)
        }
        #expect(click(756, 966))      // middle of the notch
        #expect(click(656, 950))      // min corner
        #expect(click(856, 982))      // max corner
        #expect(!click(655, 966))     // just left of it (the visible black strip)
        #expect(!click(857, 966))     // just right of it
        #expect(!click(756, 949))     // just below it, on the route row / card
    }
}

@Suite struct RouteRowClickTests {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let notch = CGRect(x: 656, y: 950, width: 200, height: 32)
    private var geometry: PanelGeometry {
        PanelGeometry(screenFrame: screen, visibleFrame: screen, notch: notch)
    }

    @Test func rowIsTheStripUnderTheNotchAcrossThePanelWidth() {
        #expect(geometry.isRouteRowClick(CGPoint(x: 700, y: 940)))
        #expect(geometry.isRouteRowClick(CGPoint(x: 600, y: 930)))   // beside the notch's width
        #expect(geometry.isRouteRowClick(CGPoint(x: 516, y: 928)))   // left and bottom edges
        #expect(geometry.isRouteRowClick(CGPoint(x: 996, y: 940)))   // right edge
    }

    @Test func notchItselfAndEverythingElseIsNotTheRow() {
        #expect(!geometry.isRouteRowClick(CGPoint(x: 700, y: 950)))  // the notch's bottom edge
        #expect(!geometry.isRouteRowClick(CGPoint(x: 700, y: 965)))
        #expect(!geometry.isRouteRowClick(CGPoint(x: 700, y: 927)))  // the card below
        #expect(!geometry.isRouteRowClick(CGPoint(x: 515, y: 940)))
        #expect(!geometry.isRouteRowClick(CGPoint(x: 997, y: 940)))
    }
}
