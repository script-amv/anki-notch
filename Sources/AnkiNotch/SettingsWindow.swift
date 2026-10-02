import AppKit
import SwiftUI
import AnkiNotchKit

/// The settings window: created once, reused. A background app must be
/// activated before a window can come forward, and the card panel sits at
/// `mainMenu + 1`, so the window is one level above it or it would open
/// underneath the panel.
@MainActor
final class SettingsWindow {
    private let settings: AppSettings
    private var window: NSWindow?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: SettingsView(settings: settings)))
        window.title = "AnkiNotch Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        window.center()
        return window
    }
}

private struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Force black background", isOn: $settings.forceBlackBackground)
            Text("Show every card on black, in night mode, whatever its note type says.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 340, alignment: .leading)
    }
}
