import AppKit

/// The app's only chrome outside the panel: a menu-bar icon with Settings and
/// Quit. A background app with no UI would otherwise have no way to exit.
@MainActor
final class StatusItem: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let onSettings: () -> Void

    init(onSettings: @escaping () -> Void) {
        self.onSettings = onSettings
        super.init()
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                                     accessibilityDescription: "AnkiNotch")
        let menu = NSMenu()
        let settings = menu.addItem(withTitle: "Settings…",
                                    action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AnkiNotch",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    @objc private func openSettings() {
        onSettings()
    }
}
