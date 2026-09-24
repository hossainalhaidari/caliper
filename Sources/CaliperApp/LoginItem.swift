import AppKit
import ServiceManagement

/// Launch at Login, through `SMAppService`.
///
/// Not a document setting. Whether an app starts with the Mac is recorded by
/// macOS, per app and per user, and System Settings > General > Login Items
/// changes it without asking. A copy in `layout.json` would be a second record
/// that nobody updates -- so this reads the one macOS keeps, every time.
@MainActor
enum LoginItem {
    /// `swift run Caliper` has no bundle to register, and `SMAppService` fails
    /// on it with an error that says nothing useful. The menu leaves the item
    /// out instead.
    static var isSupported: Bool { Bundle.main.bundleIdentifier != nil }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registers or unregisters, and says so when that did not take.
    ///
    /// `requiresApproval` means the user turned Caliper off in System Settings.
    /// Registering again does not override that -- only they can -- so rather
    /// than a checkmark that silently refuses to stick, this opens the pane where
    /// the switch is.
    static func setEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else if service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            NSLog("caliper: login item %@ failed: %@",
                  enabled ? "registration" : "removal", String(describing: error))
            present(error, enabling: enabled)
            return
        }

        if enabled, service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private static func present(_ error: any Error, enabling: Bool) {
        let alert = NSAlert()
        alert.messageText = enabling
            ? String(
                localized: "Caliper could not be added to your login items",
                comment: "Alert title: Launch at Login could not be switched on")
            : String(
                localized: "Caliper could not be removed from your login items",
                comment: "Alert title: Launch at Login could not be switched off")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "OK", comment: "Button: dismiss an alert"))
        alert.addButton(withTitle: String(
            localized: "Open Login Items\u{2026}",
            comment: "Button: open System Settings at General > Login Items"))

        // An agent app has no windows and does not come forward on its own.
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
