import AppKit
import Foundation

/// Holds notification tokens and unregisters them on release.
///
/// Kept separate from `VisibilityMonitor` and `OcclusionWatcher` so that they
/// -- being main-actor isolated -- do not need to touch non-`Sendable` token
/// objects from a nonisolated `deinit`. This class has no isolation of its own,
/// so its deinit can clean up from wherever the last release happens.
final class ObserverBag: @unchecked Sendable {
    private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    func add(_ center: NotificationCenter, _ token: NSObjectProtocol) {
        tokens.append((center, token))
    }

    deinit {
        for entry in tokens {
            entry.center.removeObserver(entry.token)
        }
    }
}

/// Watches for "nothing we draw can possibly be seen" and says so.
///
/// This is the cheapest large win in the whole app. A stats app that keeps
/// sampling through a locked screen and a sleeping display is burning battery
/// to compute numbers that are rendered into a bitmap nobody will ever look at.
/// Suspending is not an optimisation to add after profiling -- it is the
/// difference between "negligible" and "why is my fan on".
///
/// This covers display sleep, system sleep, and screen lock, which hide
/// everything at once and so stop the whole bus. A full-screen app hiding the
/// menu bar, or a status item pushed behind the notch, hides one surface at a
/// time; those are `OcclusionWatcher`'s, asked of each surface's own window.
@MainActor
final class VisibilityMonitor {
    /// Called whenever visibility flips. Not called for redundant changes.
    var onChange: ((Bool) -> Void)?

    private(set) var isVisible = true {
        didSet {
            guard isVisible != oldValue else { return }
            onChange?(isVisible)
        }
    }

    /// What a given notification tells us. An enum rather than a closure so
    /// that nothing but plain `Sendable` data crosses into the notification
    /// handler.
    private enum Signal: Sendable {
        case screensAsleep(Bool)
        case systemAsleep(Bool)
        case screenLocked(Bool)
    }

    private var screensAsleep = false
    private var systemAsleep = false
    private var screenLocked = false

    private let bag = ObserverBag()

    /// The centres are parameters so tests can post to private ones. Posting
    /// "com.apple.screenIsLocked" to the real distributed centre would tell
    /// every other app on the Mac that the screen had locked.
    init(
        workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
        distributed: NotificationCenter = DistributedNotificationCenter.default()
    ) {
        observe(workspace, NSWorkspace.screensDidSleepNotification, .screensAsleep(true))
        observe(workspace, NSWorkspace.screensDidWakeNotification, .screensAsleep(false))
        observe(workspace, NSWorkspace.willSleepNotification, .systemAsleep(true))
        observe(workspace, NSWorkspace.didWakeNotification, .systemAsleep(false))

        // Screen lock has no public AppKit notification. These distributed
        // names are long-standing and documented only by usage; if a future
        // macOS drops them the app degrades to "keeps sampling while locked",
        // never to a crash.
        observe(distributed, Notification.Name("com.apple.screenIsLocked"), .screenLocked(true))
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), .screenLocked(false))
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ signal: Signal
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.apply(signal)
            }
        }
        bag.add(center, token)
    }

    private func apply(_ signal: Signal) {
        switch signal {
        case .screensAsleep(let value): screensAsleep = value
        case .systemAsleep(let value): systemAsleep = value
        case .screenLocked(let value): screenLocked = value
        }
        isVisible = !(screensAsleep || systemAsleep || screenLocked)
    }
}
