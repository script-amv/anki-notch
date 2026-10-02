import CoreGraphics
import Foundation

/// Frame math for the notch hotspot and the panel that hangs from it. Free of
/// AppKit so it is unit-testable; the app layer feeds it `NSScreen` measurements.
public struct PanelGeometry: Equatable, Sendable {
    public static let panelWidth: CGFloat = 480
    public static let minContentHeight: CGFloat = 160
    public static let maxContentHeight: CGFloat = 560
    public static let cornerRadius: CGFloat = 20
    /// The deck-route row between the notch strip and the card. It sits
    /// outside the content-height clamp.
    public static let routeRowHeight: CGFloat = 22
    /// How long the mouse may be outside hotspot and panel before the panel collapses.
    public static let collapseGrace: TimeInterval = 0.25
    /// How long the mouse must rest on the notch before the panel opens, so
    /// crossing the menu bar through it doesn't take the keyboard.
    public static let openDwell: TimeInterval = 0.15
    /// After the panel appears, space and `1` are ignored this long, so
    /// keystrokes already on their way to the previous app can't grade a card
    /// the user hasn't looked at yet.
    public static let keyArmDelay: TimeInterval = 0.25

    /// Notch width to assume when a screen reports a camera housing but no
    /// auxiliary top areas (14"/16" notches measure about 180–200 pt).
    static let fallbackNotchWidth: CGFloat = 200
    /// Height of the virtual notch when the menu bar auto-hides.
    static let fallbackMenuBarHeight: CGFloat = 24

    /// Full screen frame (AppKit coordinates, bottom-left origin).
    public let screenFrame: CGRect
    /// Frame minus menu bar and Dock.
    public let visibleFrame: CGRect
    /// The real notch rect at the top edge, nil on notchless screens.
    public let notch: CGRect?

    public init(screenFrame: CGRect, visibleFrame: CGRect, notch: CGRect?) {
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
        self.notch = notch
    }

    /// The card area's height, clamped. Taller cards scroll inside the panel.
    public static func clampedHeight(_ contentHeight: CGFloat) -> CGFloat {
        min(max(contentHeight, minContentHeight), maxContentHeight)
    }

    /// The notch as a screen reports it: `safeAreaTop` is
    /// `NSScreen.safeAreaInsets.top`, the auxiliary areas are the usable menu
    /// bar strips either side of the camera housing.
    public static func notchRect(screenFrame: CGRect,
                                 safeAreaTop: CGFloat,
                                 auxiliaryTopLeftArea: CGRect?,
                                 auxiliaryTopRightArea: CGRect?) -> CGRect? {
        guard safeAreaTop > 0 else { return nil }
        let width: CGFloat
        let minX: CGFloat
        if let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea,
           right.minX > left.maxX {
            width = right.minX - left.maxX
            minX = left.maxX
        } else {
            width = fallbackNotchWidth
            minX = screenFrame.midX - width / 2
        }
        return CGRect(x: minX, y: screenFrame.maxY - safeAreaTop,
                      width: width, height: safeAreaTop)
    }

    /// Where hovering opens the panel: the real notch, or a virtual one at
    /// top-center (notch-wide, menu-bar tall) on screens without a notch.
    public var hotspot: CGRect {
        if let notch { return notch }
        let menuBar = max(0, screenFrame.maxY - visibleFrame.maxY)
        let height = menuBar > 0 ? menuBar : Self.fallbackMenuBarHeight
        return CGRect(x: screenFrame.midX - Self.fallbackNotchWidth / 2,
                      y: screenFrame.maxY - height,
                      width: Self.fallbackNotchWidth, height: height)
    }

    /// The card's size: a strip as tall as the notch (it reads as the notch
    /// growing), the route row when shown, then the card area, clamped.
    public func cardSize(contentHeight: CGFloat, showsRoute: Bool = false) -> CGSize {
        CGSize(width: Self.panelWidth,
               height: hotspot.height + (showsRoute ? Self.routeRowHeight : 0)
                   + Self.clampedHeight(contentHeight))
    }

    /// The panel's window frame at rest: flush with the screen's top edge and
    /// centered on the hotspot.
    public func panelFrame(contentHeight: CGFloat, showsRoute: Bool = false) -> CGRect {
        frame(for: cardSize(contentHeight: contentHeight, showsRoute: showsRoute))
    }

    /// The largest the panel can be, route row included: the window while it
    /// animates, so the shape can grow and shrink inside it (toggling the row
    /// never changes the window). Same top edge and centre as every rest
    /// frame, so shrinking the window to a rest frame moves nothing.
    public var stageFrame: CGRect {
        frame(for: cardSize(contentHeight: Self.maxContentHeight, showsRoute: true))
    }

    private func frame(for size: CGSize) -> CGRect {
        CGRect(x: hotspot.midX - size.width / 2, y: screenFrame.maxY - size.height,
               width: size.width, height: size.height)
    }

    /// Whether the mouse is still over the hotspot or the panel, edges
    /// included (`CGRect.contains` excludes the max edges).
    public static func keepsPanelOpen(mouse: CGPoint, hotspot: CGRect, panel: CGRect) -> Bool {
        [hotspot, panel].contains {
            (($0.minX)...($0.maxX)).contains(mouse.x) && (($0.minY)...($0.maxY)).contains(mouse.y)
        }
    }

    /// Whether a click (screen coordinates) is on the notch, edges included.
    public static func isNotchClick(_ point: CGPoint, hotspot: CGRect) -> Bool {
        (hotspot.minX...hotspot.maxX).contains(point.x)
            && (hotspot.minY...hotspot.maxY).contains(point.y)
    }

    /// Whether a click (screen coordinates) is on the route row: the strip
    /// under the notch, as wide as the panel. The notch's own bottom edge
    /// belongs to the notch, not the row.
    public func isRouteRowClick(_ point: CGPoint) -> Bool {
        let row = CGRect(x: hotspot.midX - Self.panelWidth / 2,
                         y: hotspot.minY - Self.routeRowHeight,
                         width: Self.panelWidth, height: Self.routeRowHeight)
        return (row.minX...row.maxX).contains(point.x)
            && point.y >= row.minY && point.y < row.maxY
    }
}
