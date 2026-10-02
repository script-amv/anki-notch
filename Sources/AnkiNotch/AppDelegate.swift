import AppKit
import AnkiNotchKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItem?
    private var panel: PanelController?
    private var hotspots: NotchHotspotController?
    private var cardView: CardWebView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItem()
        let panel = PanelController()
        let cardView = CardWebView()
        self.panel = panel
        self.cardView = cardView

        cardView.frame = panel.contentView.bounds
        cardView.autoresizingMask = [.width, .height]
        panel.contentView.addSubview(cardView)
        cardView.onContentHeight = { [weak panel] height in
            panel?.resize(contentHeight: height, animated: true)
        }

        // Temporary wiring until the review session drives the panel.
        let sample = MockAnkiConnectClient.sampleCards[0]
        hotspots = NotchHotspotController { screen in
            cardView.show(html: sample.question, css: sample.css, mediaDir: nil)
            panel.show(on: screen)
        }
    }
}
