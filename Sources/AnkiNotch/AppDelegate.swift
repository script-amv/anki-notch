import AppKit
import AnkiNotchKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItem?
    private var panel: PanelController?
    private var hotspots: NotchHotspotController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItem()
        let panel = PanelController()
        self.panel = panel

        // Placeholder until the card view is wired in.
        let label = NSTextField(labelWithString: "AnkiNotch")
        label.textColor = .white
        label.alignment = .center
        label.frame = panel.contentView.bounds
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        panel.contentView.addSubview(label)

        hotspots = NotchHotspotController { screen in panel.show(on: screen) }
    }
}
