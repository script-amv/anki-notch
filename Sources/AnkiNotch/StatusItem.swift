import AppKit

/// The app's only chrome outside the panel: a menu-bar icon whose single item
/// quits. A background app with no UI would otherwise have no way to exit.
@MainActor
final class StatusItem {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    init() {
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                                     accessibilityDescription: "AnkiNotch")
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit AnkiNotch",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }
}
