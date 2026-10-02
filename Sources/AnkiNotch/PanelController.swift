import AppKit
import AnkiNotchKit

/// The borderless window that hangs from the notch. It is a non-activating
/// panel that can still become key: space and `1` reach it while the app that
/// was in front stays the active one. (Activating AnkiNotch instead does not
/// work: macOS refuses an app that was never clicked taking the front on hover.)
private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns the panel: shows it under the notch, collapses it when the mouse has
/// been away for the grace period, and turns space / `1` into `ReviewKey`s.
@MainActor
final class PanelController {
    /// Host for whatever the panel shows below the notch-height strip.
    let contentView = NSView()
    var onKey: ((ReviewKey) -> Void)?

    private let panel: NotchPanel
    private let host = NSView()
    private let messageLabel = NSTextField(labelWithString: "")
    private var geometry: PanelGeometry?
    private var contentHeight: CGFloat = 200
    private var hoverTimer: Timer?
    private var outsideSince: Date?
    private var keyMonitor: Any?
    private var keysArmedAt = Date.distantFuture

    var isVisible: Bool { panel.isVisible }

    init() {
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)

        // Black like the notch, so the panel reads as the notch growing; only
        // the bottom corners are rounded.
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        host.layer?.cornerRadius = PanelGeometry.cornerRadius
        host.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        host.layer?.masksToBounds = true
        panel.contentView = host
        host.addSubview(contentView)

        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    /// Replace the card with one centered line (the terminal states), or, with
    /// nil, bring the card back. The panel falls to its minimum height for a
    /// message; a card brings its own height with it.
    func setMessage(_ text: String?) {
        for view in contentView.subviews where view !== messageLabel {
            view.isHidden = text != nil
        }
        messageLabel.isHidden = text == nil
        guard let text else { return }
        messageLabel.stringValue = text
        resize(contentHeight: PanelGeometry.minContentHeight, animated: true)
    }

    func show(on screen: NSScreen) {
        guard !panel.isVisible else { return }
        let geometry = screen.panelGeometry
        self.geometry = geometry
        let frame = geometry.panelFrame(contentHeight: contentHeight)
        panel.setFrame(frame, display: false)
        contentView.autoresizingMask = [.width, .height]
        contentView.frame = CGRect(x: 0, y: 0, width: frame.width,
                                   height: frame.height - geometry.hotspot.height)
        keysArmedAt = Date().addingTimeInterval(PanelGeometry.keyArmDelay)
        panel.makeKeyAndOrderFront(nil)
        startWatchingMouse()
        installKeyMonitor()
    }

    func hide() {
        guard panel.isVisible else { return }
        hoverTimer?.invalidate()
        hoverTimer = nil
        outsideSince = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        // The previous app never stopped being active, so ordering the panel
        // out is all it takes for its window to get the keyboard back.
        panel.orderOut(nil)
    }

    /// Resize to a card height (clamped by the geometry), staying flush with
    /// the top of the screen.
    func resize(contentHeight: CGFloat, animated: Bool) {
        self.contentHeight = PanelGeometry.clampedHeight(contentHeight)
        guard panel.isVisible, let geometry else { return }
        panel.setFrame(geometry.panelFrame(contentHeight: self.contentHeight),
                       display: true, animate: animated)
    }

    // MARK: Mouse

    /// Polling beats tracking areas here: the panel moves and resizes under
    /// the mouse, and a plain position check against the live frames is
    /// immune to the enter/exit events that resizing swallows or fakes.
    private func startWatchingMouse() {
        outsideSince = nil
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMouse() }
        }
    }

    private func checkMouse() {
        guard let geometry else { return }
        let inside = PanelGeometry.keepsPanelOpen(
            mouse: NSEvent.mouseLocation, hotspot: geometry.hotspot, panel: panel.frame)
        if inside {
            outsideSince = nil
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) >= PanelGeometry.collapseGrace { hide() }
        } else {
            outsideSince = Date()
        }
    }

    // MARK: Keys

    /// A local monitor rather than `keyDown` on the panel: the card's web view
    /// is the first responder and would swallow space. Only an unmodified
    /// space or `1` is ours; everything else passes through untouched.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let key = Self.reviewKey(for: event) else { return event }
            // A held key must not race through cards: only the first press counts.
            if !event.isARepeat {
                MainActor.assumeIsolated { self?.deliver(key) }
            }
            return nil
        }
    }

    /// Keys just after the panel appears are swallowed, not delivered.
    private func deliver(_ key: ReviewKey) {
        guard Date() >= keysArmedAt else { return }
        onKey?(key)
    }

    /// By key code, not by character: with a kana or AZERTY layout the
    /// top-row `1` produces something else. 49 is space, 18 the top-row `1`,
    /// 83 the keypad `1`.
    private nonisolated static func reviewKey(for event: NSEvent) -> ReviewKey? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard modifiers.isEmpty else { return nil }
        switch event.keyCode {
        case 49: return .space
        case 18, 83: return .one
        default: return nil
        }
    }
}
