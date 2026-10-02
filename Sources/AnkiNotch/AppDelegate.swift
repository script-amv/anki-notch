import AppKit
import Observation
import AnkiNotchKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItem?
    private var panel: PanelController?
    private var hotspots: NotchHotspotController?
    private var cardView: CardWebView?
    private var session: ReviewSession?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItem()
        let panel = PanelController()
        let cardView = CardWebView()
        let session = ReviewSession(client: Self.makeClient())
        self.panel = panel
        self.cardView = cardView
        self.session = session

        cardView.frame = panel.contentView.bounds
        cardView.autoresizingMask = [.width, .height]
        panel.contentView.addSubview(cardView)
        cardView.warmUp()
        cardView.onContentHeight = { [weak panel] height in
            panel?.resize(contentHeight: height, animated: true)
        }
        panel.onKey = { key in Task { await session.handle(key) } }

        hotspots = NotchHotspotController { screen in
            guard !panel.isVisible else { return }
            panel.show(on: screen)
            Task { await session.open() }
        }
        observePhase()
    }

    /// Anki, or a canned deck of sample cards with `ANKINOTCH_MOCK=1` so the
    /// panel can be tried without touching a real collection.
    private static func makeClient() -> any AnkiConnectClient {
        guard ProcessInfo.processInfo.environment["ANKINOTCH_MOCK"] == "1" else {
            return AnkiConnectHTTPClient()
        }
        let cards = (0..<8).map { index -> CurrentCard in
            let base = MockAnkiConnectClient.sampleCards[index % 2]
            return CurrentCard(cardId: Int64(index + 1),
                               question: "\(index + 1). \(base.question)",
                               answer: "\(index + 1). \(base.answer)",
                               css: base.css, buttons: base.buttons, deckName: base.deckName)
        }
        return MockAnkiConnectClient(decks: [("Sample", cards)])
    }

    /// Re-renders whenever the session's phase (or media folder) changes.
    /// `onChange` fires just before the new value lands, so the re-arm hops
    /// through a task to read the settled state.
    private func observePhase() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePhase() }
        }
    }

    private func render() {
        guard let session, let panel, let cardView else { return }
        switch session.phase {
        case .front(let card):
            panel.setMessage(nil)
            cardView.show(html: card.question, css: card.css, mediaDir: session.mediaDir)
        case .back(let card):
            panel.setMessage(nil)
            cardView.show(html: card.answer, css: card.css, mediaDir: session.mediaDir)
        case .allDone, .failed:
            panel.setMessage(session.phase.message)
        // Keep whatever is on screen: a request is in flight.
        case .idle, .loading, .submitting:
            break
        }
    }
}
