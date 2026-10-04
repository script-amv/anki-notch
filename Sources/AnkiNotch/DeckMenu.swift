import AppKit
import AnkiNotchKit

/// The deck picker: a native menu popped up under the notch. "All decks"
/// first, then the deck tree; a deck with subdecks is a submenu whose first
/// item reviews the whole deck. A checkmark marks the current choice (a dash
/// on the parents leading to it).
@MainActor
enum DeckMenu {
    static func make(decks: [String], chosen: String?,
                     onPick: @escaping @MainActor (String?) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("All decks", checked: chosen == nil) { onPick(nil) })
        menu.addItem(.separator())
        for node in DeckTree.build(from: decks) {
            menu.addItem(item(for: node, chosen: chosen, onPick: onPick))
        }
        return menu
    }

    private static func item(for node: DeckNode, chosen: String?,
                             onPick: @escaping @MainActor (String?) -> Void) -> NSMenuItem {
        guard !node.children.isEmpty else {
            return item(node.name, checked: chosen == node.path) { onPick(node.path) }
        }
        let parent = NSMenuItem(title: node.name, action: nil, keyEquivalent: "")
        if let chosen, chosen.hasPrefix(node.path + "::") { parent.state = .mixed }
        let submenu = NSMenu()
        submenu.addItem(item("\(node.name) (whole deck)", checked: chosen == node.path) {
            onPick(node.path)
        })
        submenu.addItem(.separator())
        for child in node.children {
            submenu.addItem(item(for: child, chosen: chosen, onPick: onPick))
        }
        parent.submenu = submenu
        return parent
    }

    private static func item(_ title: String, checked: Bool,
                             run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let action = MenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
        item.target = action
        item.representedObject = action  // the item keeps its target alive
        item.state = checked ? .on : .off
        return item
    }
}

/// Menu items call selectors on objects; this lets them call a closure.
@MainActor
private final class MenuAction: NSObject {
    private let run: @MainActor () -> Void
    init(_ run: @escaping @MainActor () -> Void) { self.run = run }
    @objc func fire() { run() }
}
