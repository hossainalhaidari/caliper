import AppKit

/// Says whether one of the app's windows can be seen at all.
///
/// `VisibilityMonitor` stops everything when *nothing* can be seen -- the
/// display asleep, the screen locked. This is the per-surface half: a menu bar
/// hidden by a full-screen app, a status item pushed behind the notch by a
/// crowded menu bar, a desktop widget buried under windows or left on a
/// different Space from a full-screen one. The screen is on and the user is
/// there, so sampling everything would carry on; but this one surface is
/// drawing numbers into a bitmap nobody can look at. Full-screen video is
/// exactly that case, and the one where battery matters most.
///
/// Each surface answers for itself because each is hidden for its own
/// reasons. One status item can be behind the notch while its neighbour is in
/// plain view, and a desktop widget on a second display is still visible while
/// the first display plays a film.
///
/// The question is put to the window server rather than worked out: a window's
/// `occlusionState` loses `.visible` once no pixel of it is on screen, which is
/// true of all three cases and needs no model of the menu bar's geometry.
@MainActor
final class OcclusionWatcher {
    /// How long a window must stay out of sight before it counts as hidden.
    ///
    /// Switching Spaces and Mission Control hide windows for a moment and
    /// bring them straight back. Suspending on every one of those would cost a
    /// resubscription each time, and would blank rate cells -- which need two
    /// readings to say anything -- for a second after every glance. Becoming
    /// visible is acted on at once.
    static let defaultGrace: Duration = .seconds(3)

    /// Called when the answer changes, never for a repeat of the same one.
    var onChange: ((Bool) -> Void)?

    private(set) var isVisible = true

    /// Replaceable so a test can stand in a window of its own: re-reading the
    /// real one on every notification is the point, and would undo any answer
    /// a test tried to impose.
    var window: () -> NSWindow?
    /// How a window is asked whether any of it is on screen. Replaceable for
    /// the same reason: what AppKit reports for a window a test made but never
    /// showed depends on the machine -- a CI runner with no display calls a new
    /// window visible for a while, and sends no notification when it stops.
    var isOnScreen: (NSWindow) -> Bool = { $0.occlusionState.contains(.visible) }
    private let canBeHidden: () -> Bool
    private let grace: Duration
    private var pendingHide: Task<Void, Never>?
    private let bag = ObserverBag()

    /// - Parameters:
    ///   - window: read afresh each time, because AppKit replaces a status
    ///     item's window when it moves between displays.
    ///   - canBeHidden: `false` when a hidden window does not mean an unseen
    ///     surface. See `StatusItemController` on menu bars that mirror it.
    init(
        grace: Duration = OcclusionWatcher.defaultGrace,
        window: @escaping () -> NSWindow?,
        canBeHidden: @escaping () -> Bool = { true }
    ) {
        self.grace = grace
        self.window = window
        self.canBeHidden = canBeHidden

        // Every occlusion change in the app, not just this window's: the
        // window may not exist yet, may be replaced, and the object a
        // notification carries is not something to hand across an isolation
        // boundary. Re-reading one property on each is cheaper than any of
        // that, and the app has only a handful of windows.
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSApplication.didChangeScreenParametersNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
            bag.add(center, token)
        }
    }

    /// Reads the window's state now. Called on every notification, and once by
    /// the owner after its window has first been shown.
    func evaluate() {
        let hidden = canBeHidden() && window().map { !isOnScreen($0) } == true
        report(visible: !hidden)
    }

    /// The decision, apart from where the answer came from.
    func report(visible: Bool) {
        if visible {
            pendingHide?.cancel()
            pendingHide = nil
            set(true)
            return
        }
        guard isVisible, pendingHide == nil else { return }
        pendingHide = Task { [weak self, grace] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled, let self else { return }
            self.pendingHide = nil
            self.set(false)
        }
    }

    private func set(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        onChange?(visible)
    }
}
