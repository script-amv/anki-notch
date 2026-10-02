import AppKit
import AnkiNotchKit

/// An invisible window over the notch of every screen (a virtual one at
/// top-center where there is no notch). Entering it with the mouse reports
/// the screen, which is what opens the panel.
@MainActor
final class NotchHotspotController {
    private let onHover: (NSScreen) -> Void
    private var windows: [NSPanel] = []
    private var observer: (any NSObjectProtocol)?

    init(onHover: @escaping (NSScreen) -> Void) {
        self.onHover = onHover
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        rebuild()
    }

    /// One hotspot per screen, rebuilt whenever the screen setup changes —
    /// rarer than anything else here, so recreating beats diffing.
    func rebuild() {
        for window in windows { window.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let window = Self.makeWindow()
            window.setFrame(screen.panelGeometry.hotspot, display: true)
            window.contentView = HotspotView { [onHover] in onHover(screen) }
            window.orderFrontRegardless()
            return window
        }
    }

    /// Non-activating, so merely passing the mouse over it never steals focus,
    /// and at the panel's level so it sits over the menu bar.
    private static func makeWindow() -> NSPanel {
        let window = NSPanel(contentRect: .zero,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        return window
    }
}

private final class HotspotView: NSView {
    private let onEnter: () -> Void
    private var dwell: DispatchWorkItem?

    init(onEnter: @escaping () -> Void) {
        self.onEnter = onEnter
        super.init(frame: .zero)
        // A fully transparent window region passes mouse events through to
        // whatever is beneath, so keep a whisker of alpha: invisible to the
        // eye, still hoverable.
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.001).cgColor
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Opening waits for the mouse to rest on the notch: a pointer merely
    /// crossing it on the way to a menu would otherwise take the keyboard.
    override func mouseEntered(with event: NSEvent) {
        dwell?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.onEnter() }
        }
        dwell = item
        DispatchQueue.main.asyncAfter(deadline: .now() + PanelGeometry.openDwell, execute: item)
    }

    override func mouseExited(with event: NSEvent) {
        dwell?.cancel()
        dwell = nil
    }
}
