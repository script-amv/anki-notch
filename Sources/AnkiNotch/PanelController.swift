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
    /// Opening: the shape springs out of the notch, with a slight settle.
    static let springStiffness: CGFloat = 380
    static let springDamping: CGFloat = 31
    /// The card content fades in a beat after the shape starts growing, so a
    /// small shape never shows a squashed card.
    static let contentFadeInDelay: CFTimeInterval = 0.1
    static let contentFadeInDuration: CFTimeInterval = 0.2
    static let contentFadeOutDuration: CFTimeInterval = 0.12
    static let collapseDuration: CFTimeInterval = 0.2
    /// Front ↔ back and next-card height changes.
    static let resizeDuration: CFTimeInterval = 0.25
    /// Reduce Motion: no movement, just a quick fade of the content.
    static let reduceMotionFade: CFTimeInterval = 0.15
    /// The shape's bottom corners while it is still notch-sized.
    static let notchCornerRadius: CGFloat = 10
    /// The deck route fading in or out when it is toggled.
    static let routeToggleFade: CFTimeInterval = 0.15
}

/// Owns the panel: grows it out of the notch, collapses it back when the mouse
/// has been away for the grace period, and turns space / `1` / ⌘Z into `ReviewKey`s.
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
    private let root = NSView()
    private let host = NSView()
    private let maskLayer = CALayer()
    private let messageLabel = NSTextField(labelWithString: "")
    /// The deck-route row under the notch strip. `routeRow` follows the panel's
    /// open/close fade; `routeLabel` inside it fades on its own when toggled.
    private let routeRow = NSView()
    private let routeLabel = NSTextField(labelWithString: "")
    private static let routeFont = NSFont.systemFont(ofSize: 11)
    private static let routeInset: CGFloat = 12
    private var geometry: PanelGeometry?
    private var contentHeight: CGFloat = 200
    /// True from `show` until `hide`; the window stays on screen a little
    /// longer while it collapses.
    private var isOpen = false
    /// Bumped by every motion; a finishing animation only acts if it is still
    /// the latest, so reversing mid-way can't be undone by the old one.
    private var generation = 0
    /// The opening spring is still running; a card height that arrives
    /// meanwhile retargets with the same spring instead of a plain ease.
    private var isOpening = false
    /// Where the running shape animation began and when. A layer reports its
    /// *final* value until its first frame renders, so for that instant the
    /// start value is the only honest "where is it now".
    private var motionFrom: (size: CGSize, radius: CGFloat)?
    private var motionStart: CFTimeInterval = 0
    private var hoverTimer: Timer?
    private var outsideSince: Date?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    /// A click on the notch flips this; it survives collapse and reopen, not a
    /// relaunch. The row is shown only while a card has a deck to name.
    private var showsDeckRoute = false
    private var deckRoute: String?
    private var keysArmedAt = Date.distantFuture
    /// A deck menu is being fetched or shown: a second click does nothing.
    private var isPresentingDeckMenu = false
    /// The menu is tracking. It owns the keyboard and the mouse, so the hover
    /// check and the review keys stand down until it closes.
    private var menuIsOpen = false

    var isVisible: Bool { isOpen }

    private var routeVisible: Bool { showsDeckRoute && deckRoute != nil }

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

        // Black like the notch, so the panel reads as the notch growing. The
        // mask is the visible shape: top-anchored, so changing its size grows
        // or shrinks it downward from the top edge; only the bottom corners
        // are rounded.
        root.autoresizesSubviews = true
        panel.contentView = root
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        // Pinned to the top: shrinking the window crops the bottom, nothing moves.
        host.autoresizingMask = [.minYMargin]
        root.addSubview(host)
        maskLayer.backgroundColor = NSColor.black.cgColor
        maskLayer.anchorPoint = CGPoint(x: 0.5, y: 1)
        maskLayer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        maskLayer.cornerRadius = PanelGeometry.cornerRadius
        host.layer?.mask = maskLayer
        contentView.wantsLayer = true
        host.addSubview(contentView)

        routeRow.wantsLayer = true
        routeLabel.font = Self.routeFont
        routeLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        routeLabel.alignment = .center
        routeLabel.lineBreakMode = .byTruncatingTail
        routeLabel.maximumNumberOfLines = 1
        routeLabel.wantsLayer = true
        routeLabel.alphaValue = 0
        routeRow.addSubview(routeLabel)
        host.addSubview(routeRow)

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

    /// The deck path of the card on screen, or nil when there is no card (the
    /// terminal states). The row appears or disappears when that, together with
    /// the click toggle, changes whether it is visible.
    func setDeckRoute(_ route: String?) {
        let wasVisible = routeVisible
        deckRoute = route
        if let route { routeLabel.stringValue = Self.fittingRoute(route) }
        routeVisibilityChanged(from: wasVisible)
    }

    private func toggleDeckRoute() {
        let wasVisible = routeVisible
        showsDeckRoute.toggle()
        routeVisibilityChanged(from: wasVisible)
    }

    private func routeVisibilityChanged(from wasVisible: Bool) {
        guard routeVisible != wasVisible else { return }
        fadeRouteLabel(animated: isOpen && !reduceMotion)
        resize(contentHeight: contentHeight, animated: true)
    }

    private func fadeRouteLabel(animated: Bool) {
        let alpha: CGFloat = routeVisible ? 1 : 0
        guard animated else {
            routeLabel.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PanelMotion.routeToggleFade
            routeLabel.animator().alphaValue = alpha
        }
    }

    /// The first form of the path that fits the row, else the shortest one
    /// (which the label then cuts at its tail).
    private static func fittingRoute(_ deckName: String) -> String {
        let candidates = DeckRoute.candidates(for: deckName)
        let available = PanelGeometry.panelWidth - 2 * routeInset
        let fits = candidates.first {
            ($0 as NSString).size(withAttributes: [.font: routeFont]).width <= available
        }
        return fits ?? candidates.last ?? deckName
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
        routeLabel.alphaValue = routeVisible ? 1 : 0
        keysArmedAt = Date().addingTimeInterval(PanelGeometry.keyArmDelay)
        panel.makeKeyAndOrderFront(nil)
        startWatchingMouse()
        installKeyMonitor()
        installClickMonitor()

        let target = geometry.cardSize(contentHeight: contentHeight, showsRoute: routeVisible)
        if reduceMotion {
            setShape(size: target, cornerRadius: PanelGeometry.cornerRadius)
            fadeContent(to: 1, duration: PanelMotion.reduceMotionFade, delay: 0)
            settleWindow()
            return
        }
        animateShape(to: target, cornerRadius: PanelGeometry.cornerRadius, curve: .spring) {
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
        outsideSince = nil
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
                     curve: .easeIn(PanelMotion.collapseDuration)) { [weak self] in
            guard let self, !self.isOpen else { return }
            self.panel.orderOut(nil)
        }
    }

    /// Resize to a card height (clamped by the geometry), staying flush with
    /// the top of the screen. The content takes its new size at once; the
    /// shape follows with the animation, so growing reveals it and shrinking
    /// leaves black behind it for a moment.
    func resize(contentHeight: CGFloat, animated: Bool) {
        self.contentHeight = PanelGeometry.clampedHeight(contentHeight)
        guard isOpen, let geometry else { return }
        let target = geometry.cardSize(contentHeight: self.contentHeight, showsRoute: routeVisible)
        if animated && !reduceMotion {
            ensureStage()
            layoutContent()
            let wasOpening = isOpening
            animateShape(to: target, cornerRadius: PanelGeometry.cornerRadius,
                         curve: wasOpening ? .spring : .easeOut(PanelMotion.resizeDuration)) {
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
        case spring
        case easeIn(CFTimeInterval)
        case easeOut(CFTimeInterval)
    }

    /// The window as the full-size stage, host and content placed inside it.
    private func layoutStage(_ geometry: PanelGeometry) {
        let stage = geometry.stageFrame
        panel.setFrame(stage, display: false)
        host.frame = CGRect(origin: .zero, size: stage.size)
        maskLayer.position = CGPoint(x: stage.width / 2, y: stage.height)  // top centre
        layoutContent()
    }

    /// The route row directly under the notch strip and the card content under
    /// that, both at their final size and place.
    private func layoutContent() {
        guard let geometry else { return }
        let stage = geometry.stageFrame.size
        let content = PanelGeometry.clampedHeight(contentHeight)
        let row = PanelGeometry.routeRowHeight
        routeRow.frame = CGRect(x: 0, y: stage.height - geometry.hotspot.height - row,
                                width: stage.width, height: row)
        let labelHeight = ceil(routeLabel.intrinsicContentSize.height)
        routeLabel.frame = CGRect(x: Self.routeInset, y: (row - labelHeight) / 2,
                                  width: stage.width - 2 * Self.routeInset, height: labelHeight)
        let top = geometry.hotspot.height + (routeVisible ? row : 0)
        contentView.frame = CGRect(x: 0, y: stage.height - top - content,
                                   width: stage.width, height: content)
    }

    /// Back to the stage before a motion: same top edge and centre as any rest
    /// frame, so nothing visible moves.
    private func ensureStage() {
        guard let geometry, panel.frame != geometry.stageFrame else { return }
        panel.setFrame(geometry.stageFrame, display: false)
    }

    /// At rest the window is exactly the card, so it can't block clicks on
    /// whatever is beneath the transparent stage.
    private func settleWindow() {
        guard isOpen, let geometry else { return }
        panel.setFrame(geometry.panelFrame(contentHeight: contentHeight, showsRoute: routeVisible),
                       display: true)
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
            case .spring:
                break  // a spring sets its own duration below
            case .easeIn(let duration):
                animation.duration = duration
                animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
            case .easeOut(let duration):
                animation.duration = duration
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            }
            return animation
        }
        func makeAnimation(_ keyPath: String) -> CABasicAnimation {
            guard case .spring = curve else { return CABasicAnimation(keyPath: keyPath) }
            let spring = CASpringAnimation(keyPath: keyPath)
            spring.mass = 1
            spring.stiffness = PanelMotion.springStiffness
            spring.damping = PanelMotion.springDamping
            spring.initialVelocity = 0
            spring.duration = spring.settlingDuration
            return spring
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
        maskLayer.add(configure(makeAnimation("bounds"), from: NSValue(rect: fromBounds),
                                to: NSValue(rect: toBounds)), forKey: "shape.bounds")
        maskLayer.add(configure(makeAnimation("cornerRadius"), from: fromRadius,
                                to: cornerRadius), forKey: "shape.radius")
        CATransaction.commit()
    }

    /// What fades with the panel opening and closing: the card and the route row.
    private var fadingLayers: [CALayer] {
        [contentView.layer, routeRow.layer].compactMap { $0 }
    }

    private func setContentOpacity(_ opacity: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in fadingLayers {
            layer.removeAnimation(forKey: "fade")
            layer.opacity = opacity
        }
        CATransaction.commit()
    }

    private func fadeContent(to opacity: Float, duration: CFTimeInterval,
                             delay: CFTimeInterval) {
        for layer in fadingLayers {
            fade(layer, to: opacity, duration: duration, delay: delay)
        }
    }

    private func fade(_ layer: CALayer, to opacity: Float, duration: CFTimeInterval,
                      delay: CFTimeInterval) {
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
        outsideSince = nil
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMouse() }
        }
    }

    private func checkMouse() {
        guard let geometry, !menuIsOpen else { return }
        let inside = PanelGeometry.keepsPanelOpen(
            mouse: NSEvent.mouseLocation, hotspot: geometry.hotspot,
            panel: geometry.panelFrame(contentHeight: contentHeight, showsRoute: routeVisible))
        if inside {
            outsideSince = nil
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) >= PanelGeometry.collapseGrace { hide() }
        } else {
            outsideSince = Date()
        }
    }

    // MARK: Clicks

    /// Only a left click that lands on the panel counts: on the notch rect it
    /// flips the route row, on the visible route row it opens the deck menu.
    /// Clicks on the card or in another window of this app pass through
    /// untouched.
    private func installClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.panel, let geometry = self.geometry
                else { return false }
                let point = self.panel.convertPoint(toScreen: event.locationInWindow)
                if PanelGeometry.isNotchClick(point, hotspot: geometry.hotspot) {
                    self.toggleDeckRoute()
                    return true
                }
                if self.routeVisible, geometry.isRouteRowClick(point) {
                    // After the event: a menu tracks its own loop, which must
                    // not run inside this monitor.
                    Task { @MainActor in await self.showDeckMenu() }
                    return true
                }
                return false
            }
            return handled ? nil : event
        }
    }

    // MARK: Deck menu

    private func showDeckMenu() async {
        guard isOpen, !isPresentingDeckMenu, let loadDecks else { return }
        isPresentingDeckMenu = true
        defer { isPresentingDeckMenu = false }
        guard let data = await loadDecks(), isOpen, routeVisible else { return }
        let menu = DeckMenu.make(decks: data.decks, chosen: data.chosen) { [weak self] deck in
            self?.onPickDeck?(deck)
        }
        menuIsOpen = true
        // Blocks until the menu closes; the action has run by then.
        menu.popUp(positioning: nil, at: NSPoint(x: Self.routeInset, y: 0), in: routeRow)
        menuIsOpen = false
        outsideSince = nil  // the grace period starts from here, not from before the menu
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
