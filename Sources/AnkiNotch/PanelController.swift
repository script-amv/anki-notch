import AppKit
import QuartzCore
import AnkiNotchKit

/// The borderless window that hangs from the notch. It is a non-activating
/// panel that can still become key: space and `1` reach it while the app that
/// was in front stays the active one. (Activating AnkiNotch instead does not
/// work: macOS refuses an app that was never clicked taking the front on hover.)
private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// How the panel moves. The feel lives here; tune these.
private enum PanelMotion {
    /// The non-bouncy option and ordinary resizing: slow start, fast middle,
    /// soft landing. A cubic Bézier.
    static var smoothCurve: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
    }
    static let expandDuration: CFTimeInterval = 0.45
    static let collapseDuration: CFTimeInterval = 0.35
    static let springExpandDuration: CFTimeInterval = 0.55
    static let springCollapseDuration: CFTimeInterval = 0.42
    static let springRetargetDuration: CFTimeInterval = 0.4
    /// Front ↔ back and next-card height changes.
    static let resizeDuration: CFTimeInterval = 0.3
    /// The card content fades in once the shape has begun to grow, so a small
    /// shape never shows a squashed card, and out ahead of the shape closing.
    static let contentFadeInDelay: CFTimeInterval = 0.15
    static let contentFadeInDuration: CFTimeInterval = 0.3
    static let contentFadeOutDuration: CFTimeInterval = 0.15
    /// Reduce Motion: no movement, just a quick fade of the content.
    static let reduceMotionFade: CFTimeInterval = 0.15
    /// The shape's bottom corners while it is still notch-sized.
    static let notchCornerRadius: CGFloat = 10
}

/// Owns the panel: grows it out of the notch, collapses it back the moment the
/// mouse leaves it, and turns space / `1` / ⌘Z into `ReviewKey`s.
///
/// The window is a fixed transparent stage while anything is moving (the
/// largest the card can be, flush with the top of the screen), and shrinks to
/// exactly the card at rest so it never blocks clicks beneath it. Inside it,
/// `host` is black and masked by `maskLayer`; the card content is laid out at
/// its final size once and only revealed by the mask growing, so the web view
/// never reflows mid-animation. All motion is Core Animation on the mask.
@MainActor
final class PanelController {
    /// Host for whatever the panel shows below the notch-height strip.
    let contentView = NSView()
    var onKey: ((ReviewKey) -> Void)?
    /// Anki's deck names and the current choice, for the picker menu; nil
    /// when Anki can't be reached (no menu then).
    var loadDecks: (() async -> (decks: [String], chosen: String?)?)?
    /// The user picked a deck from the menu; nil is "All decks".
    var onPickDeck: ((String?) -> Void)?

    private let panel: NotchPanel
    private let settings: AppSettings
    private let root = NSView()
    private let host = NSView()
    private let maskLayer = CALayer()
    private let messageLabel = NSTextField(labelWithString: "")
    private var geometry: PanelGeometry?
    private var contentHeight: CGFloat = 200
    /// True from `show` until `hide`; the window stays on screen a little
    /// longer while it collapses.
    private var isOpen = false
    /// Bumped by every motion; a finishing animation only acts if it is still
    /// the latest, so reversing mid-way can't be undone by the old one.
    private var generation = 0
    /// Opening is still running; a late card height keeps its motion style.
    private var isOpening = false
    private var openingIsBouncy = false
    /// Where the running shape animation began and when. A layer reports its
    /// *final* value until its first frame renders, so for that instant the
    /// start value is the only honest "where is it now".
    private var motionFrom: (size: CGSize, radius: CGFloat)?
    private var motionStart: CFTimeInterval = 0
    private var hoverTimer: Timer?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var keysArmedAt = Date.distantFuture
    /// A deck menu is being fetched or shown: a second click does nothing.
    private var isPresentingDeckMenu = false
    /// The menu is tracking. It owns the keyboard and the mouse, so the hover
    /// check and the review keys stand down until it closes.
    private var menuIsOpen = false

    var isVisible: Bool { isOpen }

    init(settings: AppSettings) {
        self.settings = settings
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

        // Black like the notch, so the panel reads as the notch growing. The
        // mask is the visible shape: top-anchored, so changing its size grows
        // or shrinks it downward from the top edge; only the bottom corners
        // are rounded.
        root.autoresizesSubviews = true
        panel.contentView = root
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        // Pinned to the top: shrinking the window crops the bottom, nothing moves.
        host.autoresizingMask = [.minYMargin, .minXMargin, .maxXMargin]
        root.addSubview(host)
        maskLayer.backgroundColor = NSColor.black.cgColor
        maskLayer.anchorPoint = CGPoint(x: 0.5, y: 1)
        maskLayer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        maskLayer.cornerRadius = PanelGeometry.cornerRadius
        host.layer?.mask = maskLayer
        contentView.wantsLayer = true
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
        resize(contentHeight: PanelGeometry.messageContentHeight, animated: true)
    }

    func show(on screen: NSScreen) {
        guard !isOpen else { return }
        isOpen = true
        let geometry = screen.panelGeometry
        self.geometry = geometry
        // Re-opening during a collapse keeps the shape where it is and grows
        // it again from there; from hidden it starts as the notch itself.
        let wasOnScreen = panel.isVisible
        layoutStage(geometry)
        if !wasOnScreen {
            setShape(size: geometry.hotspot.size, cornerRadius: PanelMotion.notchCornerRadius)
            setContentOpacity(0)
        }
        keysArmedAt = Date().addingTimeInterval(PanelGeometry.keyArmDelay)
        panel.makeKeyAndOrderFront(nil)
        startWatchingMouse()
        installKeyMonitor()
        installClickMonitor()

        let target = geometry.cardSize(contentHeight: contentHeight)
        if reduceMotion {
            setShape(size: target, cornerRadius: PanelGeometry.cornerRadius)
            fadeContent(to: 1, duration: PanelMotion.reduceMotionFade, delay: 0)
            settleWindow()
            return
        }
        openingIsBouncy = settings.bouncyAnimations
        animateShape(to: target, cornerRadius: PanelGeometry.cornerRadius,
                     curve: openingIsBouncy ? .spring(PanelMotion.springExpandDuration)
                                            : .easeInOut(PanelMotion.expandDuration)) {
            [weak self] in self?.settleWindow()
        }
        isOpening = true
        fadeContent(to: 1, duration: PanelMotion.contentFadeInDuration,
                    delay: PanelMotion.contentFadeInDelay)
    }

    func hide() {
        guard isOpen else { return }
        isOpen = false
        isOpening = false
        hoverTimer?.invalidate()
        hoverTimer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        // The previous app never stopped being active, so ordering the panel
        // out is all it takes for its window to get the keyboard back.
        guard let geometry, !reduceMotion else {
            generation += 1
            panel.orderOut(nil)
            return
        }
        ensureStage()
        fadeContent(to: 0, duration: PanelMotion.contentFadeOutDuration, delay: 0)
        animateShape(to: geometry.hotspot.size, cornerRadius: PanelMotion.notchCornerRadius,
                     curve: settings.bouncyAnimations ? .spring(PanelMotion.springCollapseDuration)
                                                       : .easeInOut(PanelMotion.collapseDuration)) { [weak self] in
            guard let self, !self.isOpen else { return }
            self.panel.orderOut(nil)
        }
    }

    /// Resize to a card height (clamped by the geometry), staying flush with
    /// the top of the screen. The content takes its new size at once; the
    /// shape follows with the animation, so growing reveals it and shrinking
    /// leaves black behind it for a moment.
    func resize(contentHeight: CGFloat, animated: Bool) {
        self.contentHeight = contentHeight
        guard isOpen, let geometry else { return }
        let target = geometry.cardSize(contentHeight: self.contentHeight)
        if animated && !reduceMotion {
            ensureStage()
            layoutContent()
            let wasOpening = isOpening
            let curve: Curve = wasOpening
                ? (openingIsBouncy ? .spring(PanelMotion.springRetargetDuration)
                                   : .easeOut(PanelMotion.resizeDuration))
                : .easeInOut(PanelMotion.resizeDuration)
            animateShape(to: target, cornerRadius: PanelGeometry.cornerRadius,
                         curve: curve) {
                [weak self] in self?.settleWindow()
            }
            isOpening = wasOpening

        } else {
            layoutContent()
            setShape(size: target, cornerRadius: PanelGeometry.cornerRadius)
            settleWindow()
        }
    }

    // MARK: Motion

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private enum Curve {
        case spring(CFTimeInterval)
        /// The smooth S-curve: opening, collapsing, resizing.
        case easeInOut(CFTimeInterval)
        /// Starts at full speed, for retargeting a shape that is already moving
        /// (an ease-in start would stall it mid-flight).
        case easeOut(CFTimeInterval)
    }

    /// The window as the full-size stage, host and content placed inside it.
    private func layoutStage(_ geometry: PanelGeometry) {
        let stage = geometry.animationStageFrame
        panel.setFrame(stage, display: false)
        host.frame = CGRect(origin: .zero, size: stage.size)
        maskLayer.position = CGPoint(x: stage.width / 2, y: stage.height)  // top centre
        layoutContent()
    }

    /// The card content at its final size. No padding anywhere: the card fills
    /// the panel edge to edge, from the top of the screen.
    private func layoutContent() {
        guard let geometry else { return }
        let stage = geometry.animationStageFrame.size
        let content = geometry.contentAreaHeight(for: contentHeight)
        contentView.frame = CGRect(x: (stage.width - PanelGeometry.panelWidth) / 2,
                                   y: stage.height - content,
                                   width: PanelGeometry.panelWidth, height: content)
    }

    /// Back to the stage before a motion: same top edge and centre as any rest
    /// frame, so nothing visible moves.
    private func ensureStage() {
        guard let geometry, panel.frame != geometry.animationStageFrame else { return }
        panel.setFrame(geometry.animationStageFrame, display: false)
    }

    /// At rest the window is exactly the card, so it can't block clicks on
    /// whatever is beneath the transparent stage.
    private func settleWindow() {
        guard isOpen, let geometry else { return }
        panel.setFrame(geometry.panelFrame(contentHeight: contentHeight), display: true)
    }

    /// Where the shape visibly is right now.
    private var visibleShape: (size: CGSize, radius: CGFloat) {
        guard maskLayer.animationKeys()?.isEmpty == false else {
            return (maskLayer.bounds.size, maskLayer.cornerRadius)
        }
        if let motionFrom, CACurrentMediaTime() - motionStart < 0.04 { return motionFrom }
        guard let presentation = maskLayer.presentation() else {
            return (maskLayer.bounds.size, maskLayer.cornerRadius)
        }
        return (presentation.bounds.size, presentation.cornerRadius)
    }

    /// Jump the shape to `size`, cancelling any motion in flight.
    private func setShape(size: CGSize, cornerRadius: CGFloat) {
        generation += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.removeAllAnimations()
        maskLayer.bounds = CGRect(origin: .zero, size: size)
        maskLayer.cornerRadius = cornerRadius
        CATransaction.commit()
        motionFrom = nil
        isOpening = false
    }

    /// Animate the shape from wherever it visibly is to `size`. `completion`
    /// runs only if nothing newer has started by then.
    private func animateShape(to size: CGSize, cornerRadius: CGFloat, curve: Curve,
                              completion: @escaping @MainActor () -> Void) {
        generation += 1
        let mine = generation
        let visible = visibleShape
        let fromBounds = CGRect(origin: .zero, size: visible.size)
        let fromRadius = visible.radius
        motionFrom = visible
        motionStart = CACurrentMediaTime()
        let toBounds = CGRect(origin: .zero, size: size)

        func configure(_ animation: CABasicAnimation, from: Any, to: Any) -> CABasicAnimation {
            animation.fromValue = from
            animation.toValue = to
            switch curve {
            case .spring(let duration):
                animation.duration = duration
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            case .easeInOut(let duration):
                animation.duration = duration
                animation.timingFunction = PanelMotion.smoothCurve
            case .easeOut(let duration):
                animation.duration = duration
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            }
            return animation
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == mine else { return }
                self.isOpening = false
                completion()
            }
        }
        maskLayer.removeAnimation(forKey: "shape.bounds")
        maskLayer.removeAnimation(forKey: "shape.radius")
        maskLayer.bounds = toBounds
        maskLayer.cornerRadius = cornerRadius
        if case .spring(let duration) = curve, let geometry {
            let spring = CAKeyframeAnimation(keyPath: "bounds")
            spring.values = PanelSpring.sizes(from: visible.size, to: size,
                                              maximumSize: geometry.animationStageFrame.size).map {
                NSValue(rect: CGRect(origin: .zero, size: $0))
            }
            spring.duration = duration
            spring.calculationMode = .linear
            spring.timingFunction = CAMediaTimingFunction(name: .linear)
            maskLayer.add(spring, forKey: "shape.bounds")
        } else {
            maskLayer.add(configure(CABasicAnimation(keyPath: "bounds"), from: NSValue(rect: fromBounds),
                                    to: NSValue(rect: toBounds)), forKey: "shape.bounds")
        }
        maskLayer.add(configure(CABasicAnimation(keyPath: "cornerRadius"), from: fromRadius,
                                to: cornerRadius), forKey: "shape.radius")
        CATransaction.commit()
    }

    private func setContentOpacity(_ opacity: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentView.layer?.removeAnimation(forKey: "fade")
        contentView.layer?.opacity = opacity
        CATransaction.commit()
    }

    private func fadeContent(to opacity: Float, duration: CFTimeInterval,
                             delay: CFTimeInterval) {
        guard let layer = contentView.layer else { return }
        let from = layer.animationKeys()?.isEmpty == false
            ? (layer.presentation()?.opacity ?? layer.opacity) : layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "fade")
        layer.opacity = opacity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = opacity
        fade.duration = duration
        fade.beginTime = CACurrentMediaTime() + delay
        fade.fillMode = .backwards
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    // MARK: Mouse

    /// Polling beats tracking areas here: the panel moves and resizes under
    /// the mouse, and a plain position check is immune to the enter/exit
    /// events that resizing swallows or fakes. It tests against the card's
    /// final frame, never the animating one: the window is the larger stage
    /// while anything moves.
    private func startWatchingMouse() {
        // 60 Hz: the panel closes within a frame of the mouse leaving it.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMouse() }
        }
    }

    private func checkMouse() {
        guard let geometry, !menuIsOpen else { return }
        let inside = PanelGeometry.keepsPanelOpen(
            mouse: NSEvent.mouseLocation, hotspot: geometry.hotspot,
            panel: geometry.panelFrame(contentHeight: contentHeight))
        // No grace period: the moment the mouse is out, the panel collapses.
        if !inside { hide() }
    }

    // MARK: Clicks

    /// Only a left click that lands on the panel inside the notch rect counts:
    /// it opens the deck menu. Clicks on the card or in another window of this
    /// app pass through untouched.
    private func installClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.panel, let geometry = self.geometry
                else { return false }
                let point = self.panel.convertPoint(toScreen: event.locationInWindow)
                guard PanelGeometry.isNotchClick(point, hotspot: geometry.hotspot) else {
                    return false
                }
                // After the event: a menu tracks its own loop, which must
                // not run inside this monitor.
                Task { @MainActor in await self.showDeckMenu() }
                return true
            }
            return handled ? nil : event
        }
    }

    // MARK: Deck menu

    private func showDeckMenu() async {
        guard isOpen, !isPresentingDeckMenu, let loadDecks else { return }
        isPresentingDeckMenu = true
        defer { isPresentingDeckMenu = false }
        guard let geometry, let data = await loadDecks(), isOpen else { return }
        let menu = DeckMenu.make(decks: data.decks, chosen: data.chosen) { [weak self] deck in
            self?.onPickDeck?(deck)
        }
        menuIsOpen = true
        // Blocks until the menu closes; the action has run by then.
        // Just under the notch, its left edge on the notch's left edge (host
        // coordinates: the stage's origin is the host's).
        let stage = geometry.animationStageFrame
        menu.popUp(positioning: nil,
                   at: NSPoint(x: geometry.hotspot.minX - stage.minX,
                               y: stage.height - geometry.hotspot.height),
                   in: host)
        menuIsOpen = false
    }

    // MARK: Keys

    /// A local monitor rather than `keyDown` on the panel: the card's web view
    /// is the first responder and would swallow space. Only an unmodified
    /// space or `1`, or ⌘Z, typed into the panel is ours; everything else passes
    /// through untouched, including keys aimed at another window of this app
    /// (the settings window): space must toggle its checkbox, and must never
    /// answer a card the user is not looking at.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, !self.menuIsOpen, event.window === self.panel,
                      let key = Self.reviewKey(for: event) else { return false }
                // A held key must not race through cards: only the first press counts.
                if !event.isARepeat { self.deliver(key) }
                return true
            }
            return handled ? nil : event
        }
    }

    /// Keys just after the panel appears are swallowed, not delivered.
    private func deliver(_ key: ReviewKey) {
        guard Date() >= keysArmedAt else { return }
        onKey?(key)
    }

    /// Space, `1` and ⌘Z. Space and `1` are matched by key code, not by
    /// character: with a kana or AZERTY layout the top-row `1` produces
    /// something else. 49 is space, 18 the top-row `1`, 83 the keypad `1`.
    /// ⌘Z is matched by the letter, as in every Mac app (⇧⌘Z is redo: not ours).
    private nonisolated static func reviewKey(for event: NSEvent) -> ReviewKey? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if modifiers == .command {
            return event.charactersIgnoringModifiers?.lowercased() == "z" ? .undo : nil
        }
        guard modifiers.isEmpty else { return nil }
        switch event.keyCode {
        case 49: return .space
        case 18, 83: return .one
        default: return nil
        }
    }
}
