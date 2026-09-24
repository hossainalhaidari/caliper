import AppKit
import Foundation
import MetricBus
import Observation
import RenderKit
import SchemaKit
import SensorKit
import UserNotifications

/// Turns sustained threshold breaches into notifications.
///
/// The judgement about *whether* something is worth saying lives in
/// `AlertTracker`, which is pure and tested. This class does the parts that need
/// the running app: knowing which cells have thresholds, watching the bus, and
/// delivering to Notification Centre.
@MainActor
final class AlertMonitor {
    private let bus: MetricBus
    private let store: WidgetStore
    private let tracker = AlertTracker()

    private var states: [MetricID: AlertTracker.State] = [:]
    private(set) var thresholds: [MetricID: Thresholds] = [:]
    private var descriptors: [MetricID: MetricDescriptor] = [:]
    private var observer: UUID?
    private var subscription: MetricBus.Subscription?

    /// Requested lazily. Asking on launch would put a permission prompt in front
    /// of someone who has not configured a single threshold yet, which is the
    /// fastest way to be denied permanently.
    private var hasRequestedAuthorisation = false

    init(bus: MetricBus, store: WidgetStore) {
        self.bus = bus
        self.store = store
    }

    deinit {
        // Nonisolated cleanup, as in `StatusItemController`: the bus is
        // thread-safe and the token and subscription are plain handles. In
        // practice the monitor lives as long as the app; this is so that it
        // would not leave a closure behind on the bus if it ever did not.
        if let observer { bus.removeObserver(observer) }
        subscription?.cancel()
    }

    func start() {
        for descriptor in bus.availableMetrics() { descriptors[descriptor.id] = descriptor }
        rebuild()
        observeStore()

        observer = bus.observe { [weak self] snapshot in
            MainActor.assumeIsolated { self?.handle(snapshot) }
        }
    }

    /// Collects every threshold across every enabled widget.
    ///
    /// A metric watched by two widgets gets one tracker, using the tighter
    /// thresholds. Two notifications for one event would be worse than none.
    private func rebuild() {
        thresholds.removeAll(keepingCapacity: true)

        for widget in store.document.widgets where widget.isEnabled {
            for cell in widget.cells {
                guard let cellThresholds = cell.thresholds,
                      cellThresholds.elevated != nil || cellThresholds.critical != nil
                else { continue }

                // The alert metric, when set, is the thing being judged -- the
                // memory cell shows "used" but alerts on pressure. A decorative
                // cell has neither and is skipped.
                guard let metric = cell.alertMetric ?? cell.metric else { continue }
                let existing = thresholds[metric]
                thresholds[metric] = Thresholds(
                    elevated: tighter(existing?.elevated, cellThresholds.elevated),
                    critical: tighter(existing?.critical, cellThresholds.critical)
                )
            }
        }

        // Drop state for metrics nobody watches any more, so re-adding a
        // threshold later starts from a clean slate rather than firing
        // immediately on a stale breach.
        states = states.filter { thresholds[$0.key] != nil }

        subscription?.cancel()
        subscription = thresholds.isEmpty ? nil : bus.subscribe(to: Set(thresholds.keys))
    }

    private func tighter(_ first: Double?, _ second: Double?) -> Double? {
        switch (first, second) {
        case (let a?, let b?): min(a, b)
        case (let a?, nil): a
        case (nil, let b?): b
        default: nil
        }
    }

    private func handle(_ snapshot: Snapshot) {
        guard store.document.alertsEnabled, !thresholds.isEmpty else { return }
        let now = Date()

        for (metric, limits) in thresholds {
            guard let value = snapshot[metric] else { continue }
            var state = states[metric] ?? AlertTracker.State()
            let event = tracker.update(
                &state, metric: metric, value: value, thresholds: limits, now: now
            )
            states[metric] = state

            if let event { deliver(event) }
        }
    }

    private func deliver(_ event: AlertTracker.Event) {
        let descriptor = descriptors[event.metric]
        let name = descriptor?.displayName ?? event.metric.rawValue
        let unit = descriptor?.unit ?? .count

        // UNUserNotificationCenter requires a real bundle; running the binary
        // directly during development would trap rather than fail.
        guard Bundle.main.bundleIdentifier != nil else {
            NSLog("caliper alert: %@", event.message(displayName: name, unit: unit))
            return
        }

        let title = event.title
        let body = event.message(displayName: name, unit: unit)

        guard !hasRequestedAuthorisation else {
            Self.post(title: title, body: body)
            return
        }
        hasRequestedAuthorisation = true

        // Only the two strings cross into the callback. Capturing the
        // notification centre itself would be sending a non-Sendable reference
        // across an isolation boundary, which Swift 6 rejects outright.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in Self.post(title: title, body: body) }
        }
    }

    private static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // No sound. A chime for a CPU spike trains you to ignore chimes.
        content.sound = nil

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    private func observeStore() {
        withObservationTracking {
            _ = store.revision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.rebuild()
                self?.observeStore()
            }
        }
    }
}
