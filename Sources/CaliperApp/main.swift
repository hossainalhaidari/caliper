import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate

// No Dock icon, no menu bar menu, no window on launch. The bundled build sets
// LSUIElement in Info.plist for the same effect, but setting it here as well
// means `swift run Caliper` behaves identically to the shipped app -- worth it so
// that day-to-day development is testing the real thing.
application.setActivationPolicy(.accessory)
application.run()
