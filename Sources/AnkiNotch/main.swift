import AppKit

// A background app: no Dock icon, no menu bar of its own.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
