import AppKit
import Sparkle

/// Sparkle, reduced to what the status item menu asks of it: a check to run, a
/// switch to show and flip, and a version waiting for the user's attention.
///
/// Only a release build updates itself. `Tools/bundle.sh` leaves `SUFeedURL` out
/// of any build it was not given a version for, so `make app` never offers to
/// replace itself with the published release. A build with no `SUPublicEDKey`
/// could not verify anything it downloaded, so it is treated the same way, and
/// `swift run Caliper` has no Info.plist at all. In every one of those cases the
/// updater is never started -- started, Sparkle would put up an alert telling
/// the user the app is misconfigured -- and the menu hides the update items.
@MainActor
final class UpdateService: NSObject {
    /// Whether this build has a feed to read and a key to check what it finds
    /// against.
    let isAvailable: Bool

    /// A version a scheduled check found and held back rather than showing. See
    /// `standardUserDriverShouldHandleShowingScheduledUpdate`.
    private(set) var waitingVersion: String?

    private var controller: SPUStandardUpdaterController?

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        isAvailable = Self.isConfigured(info)
        super.init()
    }

    nonisolated static func isConfigured(_ info: [String: Any]) -> Bool {
        ["SUFeedURL", "SUPublicEDKey"].allSatisfy { key in
            guard let value = info[key] as? String else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Separate from `init` so the scheduler's first check waits for the app to
    /// have finished launching, as Sparkle asks.
    func start() {
        guard isAvailable, controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        // Sparkle's default names the app and its version to whoever serves the
        // feed, and URLSession adds the user's preferred languages. The feed
        // needs none of it to answer -- the version is compared here, against
        // the appcast -- so every copy sends the same two values instead.
        controller.updater.userAgentString = "Sparkle"
        controller.updater.httpHeaders = ["Accept-Language": "*"]
        controller.startUpdater()
        self.controller = controller
    }

    /// Read back from Sparkle rather than remembered: it keeps the switch in the
    /// app's own defaults, and its update window can change it without asking.
    var checksAutomatically: Bool {
        controller?.updater.automaticallyChecksForUpdates ?? false
    }

    func setChecksAutomatically(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        // Downloading means nothing without checking, and left on it would come
        // back by itself the next time checking was switched on.
        if !enabled { updater.automaticallyDownloadsUpdates = false }
    }

    /// Checks now, with Sparkle's progress window and answer. If an update is
    /// already waiting, this is also what brings it forward.
    func checkForUpdates() {
        guard let controller else { return }
        // An agent is never the active app on its own; without this the window
        // opens behind whatever the user was working in.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

extension UpdateService: SPUUpdaterDelegate {
    /// No system profile, whatever the defaults say. Sparkle sends one only when
    /// `SUSendProfileInfo` is on, which nothing in Caliper sets and
    /// `SUEnableSystemProfiling` keeps it from asking for -- but a `defaults
    /// write` could still switch it on, and an empty list means it then sends
    /// nothing.
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? {
        []
    }
}

/// Gentle reminders, in Sparkle's terms.
///
/// Caliper is an agent: no Dock tile to bounce, never frontmost unless the user
/// brings it there. A scheduled check that finds something mid-afternoon would
/// open its alert behind whatever the user is doing, where it would sit unseen.
/// So only when Sparkle judges the moment right -- just after launch, or once
/// the Mac has been idle -- does it show the alert itself. Any other time the
/// version waits in the menu item's title, and choosing it there brings the
/// alert forward.
extension UpdateService: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        waitingVersion = update.displayVersionString
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        waitingVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        waitingVersion = nil
    }
}
