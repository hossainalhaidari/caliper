import Dispatch
import Foundation
import SensorKit

/// The single scheduler for the whole process.
///
/// Three rules, all of which are architectural rather than optimisations, and
/// none of which can be bolted on later:
///
/// 1. **One timer.** Not one per widget, not one per source. Every wakeup in
///    the app originates here, scheduled with generous leeway so the kernel
///    coalesces our wakeups with the rest of the system's. Timer coalescing is
///    the single largest battery win available to a menu bar app and it is free
///    -- but only if there is exactly one timer to coalesce.
///
/// 2. **Refcounted sources.** A source is `activate()`d when its first
///    subscriber appears and `deactivate()`d when its last one leaves. If no
///    visible cell is bound to a GPU metric, the GPU is never touched.
///
/// 3. **Suspendable.** `isRunning = false` stops the timer outright, so a
///    locked screen or a sleeping display costs nothing at all rather than
///    "not very much".
///
/// State is confined to `queue`. The class is `@unchecked Sendable` because
/// that confinement, not a lock, is what makes it safe.
public final class MetricBus: @unchecked Sendable {

    public struct Configuration: Sendable {
        /// The quantum for all sampling. Sources run at whole multiples of it.
        public var baseInterval: TimeInterval = 1.0

        /// Slack handed to the kernel for wakeup coalescing, as a fraction of
        /// `baseInterval`. 10% of a second is imperceptible in a menu bar and
        /// measurably cheaper than demanding precision we do not need.
        public var leewayFraction: Double = 0.1

        /// Samples retained per metric. 3600 at 1Hz is one hour of history.
        public var historyCapacity: Int = 3600

        public init() {}
    }

    /// Cancel to unsubscribe. Releasing the last `Subscription` covering a
    /// source deactivates it, so lifetime alone drives the hardware -- there is
    /// no separate "stop polling" call anyone can forget.
    public final class Subscription: @unchecked Sendable {
        private weak var bus: MetricBus?
        fileprivate let metrics: Set<MetricID>
        private var isCancelled = false

        fileprivate init(bus: MetricBus, metrics: Set<MetricID>) {
            self.bus = bus
            self.metrics = metrics
        }

        public func cancel() {
            guard !isCancelled else { return }
            isCancelled = true
            bus?.release(metrics: metrics)
        }

        deinit { cancel() }
    }

    private struct Registration {
        let source: any MetricSource
        let divisor: Int
        var subscribers = 0
        var isActive = false
        /// Uptime nanoseconds at the previous sample, for `SampleContext.elapsed`.
        /// Cleared on activation so a resumed source starts from a fresh baseline
        /// rather than measuring a rate across the whole suspended period.
        var lastSampledAt: UInt64?
    }

    // MARK: - Queue-confined state

    private let queue = DispatchQueue(
        label: "de.alhaidari.caliper.metric-bus",
        qos: .utility  // never .userInteractive: sampling must yield to the UI
    )
    private var timer: DispatchSourceTimer?
    private var registrations: [ObjectIdentifier: Registration] = [:]
    /// Sources in the order they were registered.
    ///
    /// `registrations` is a dictionary, so iterating it yields sources in hash
    /// order -- which made `availableMetrics()` nondeterministic. The detail
    /// panel takes the first metric in a group as its headline, and opened the
    /// CPU panel titled "Efficiency Cores" because that is what came out first
    /// that run. Registration order is deterministic and is also the order a
    /// source's author considered sensible.
    private var registrationOrder: [ObjectIdentifier] = []
    /// Which source owns which metric, so subscribing by `MetricID` can find it.
    private var ownership: [MetricID: ObjectIdentifier] = [:]
    private var history: [MetricID: RingBuffer<Float>] = [:]
    private var latest: [MetricID: Double] = [:]
    /// Tick at which each metric was last written, for staleness detection.
    private var lastUpdated: [MetricID: UInt64] = [:]
    private var observers: [UUID: @Sendable (Snapshot) -> Void] = [:]
    private var tick: UInt64 = 0
    /// Size of the last snapshot handed to observers, to detect metrics ageing out.
    private var lastDeliveredCount = 0
    /// Reused across every tick; never reallocated in steady state.
    private var sink = SampleSink()
    private var running = false

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Registration

    /// Sources are registered once at startup. Registration is cheap and does
    /// not touch hardware -- `activate()` is what does, and that waits for a
    /// subscriber.
    public func register(_ source: any MetricSource) {
        queue.sync {
            let key = ObjectIdentifier(source)
            guard registrations[key] == nil else { return }

            registrations[key] = Registration(
                source: source,
                divisor: max(1, source.cadence.tickDivisor)
            )
            registrationOrder.append(key)
            for descriptor in source.descriptors {
                ownership[descriptor.id] = key
                history[descriptor.id] = RingBuffer(
                    capacity: configuration.historyCapacity,
                    filler: Float.nan  // NaN means "no reading yet", not zero
                )
            }
        }
    }

    /// Every metric available on this machine, for the editor's picker and for
    /// resolving shared documents against local hardware (M4).
    public func availableMetrics() -> [MetricDescriptor] {
        queue.sync {
            registrationOrder.compactMap { registrations[$0] }.flatMap(\.source.descriptors)
        }
    }

    /// Re-reads every source's descriptors and adopts any that are new.
    ///
    /// Hardware appears and disappears while the app is running: an external
    /// drive is plugged in, a VPN tunnel comes up. Sources report those through
    /// their descriptor list, but the bus only reads that list at registration,
    /// so something has to prompt it. The app calls this on volume mount and
    /// unmount notifications.
    public func refreshDescriptors() {
        queue.sync { [self] in
            for key in registrationOrder {
                guard let registration = registrations[key] else { continue }
                for descriptor in registration.source.descriptors where ownership[descriptor.id] == nil {
                    ownership[descriptor.id] = key
                    history[descriptor.id] = RingBuffer(
                        capacity: configuration.historyCapacity,
                        filler: Float.nan
                    )
                }
            }
        }
    }

    // MARK: - Subscription

    public func subscribe(to metrics: Set<MetricID>) -> Subscription {
        queue.sync {
            for metric in metrics {
                guard let key = ownership[metric] else { continue }
                registrations[key]?.subscribers += 1
                activateIfNeeded(key)
            }
        }
        return Subscription(bus: self, metrics: metrics)
    }

    public func subscribe(to metrics: MetricID...) -> Subscription {
        subscribe(to: Set(metrics))
    }

    private func release(metrics: Set<MetricID>) {
        queue.async { [self] in
            for metric in metrics {
                guard let key = ownership[metric],
                      var registration = registrations[key] else { continue }
                registration.subscribers = max(0, registration.subscribers - 1)
                registrations[key] = registration

                if registration.subscribers == 0, registration.isActive {
                    registration.source.deactivate()
                    registrations[key]?.isActive = false
                    registrations[key]?.lastSampledAt = nil
                }
            }
        }
    }

    private func activateIfNeeded(_ key: ObjectIdentifier) {
        guard var registration = registrations[key],
              registration.subscribers > 0,
              !registration.isActive else { return }
        registration.source.activate()
        registration.isActive = true
        registration.lastSampledAt = nil
        registrations[key] = registration
    }

    // MARK: - Observation

    /// Observers are invoked on the **main queue**, because every one of them
    /// so far is a piece of UI. Anything wanting raw off-main delivery should
    /// get its own entry point rather than making every caller hop back.
    @discardableResult
    public func observe(_ handler: @escaping @Sendable (Snapshot) -> Void) -> UUID {
        let token = UUID()
        queue.sync { observers[token] = handler }
        return token
    }

    public func removeObserver(_ token: UUID) {
        queue.async { [self] in observers[token] = nil }
    }

    // MARK: - Running

    /// The suspension switch. Flipped by `VisibilityMonitor` when nothing we
    /// draw can possibly be seen.
    public var isRunning: Bool {
        get { queue.sync { running } }
        set { newValue ? start() : stop() }
    }

    public func start() {
        queue.sync { [self] in
            guard timer == nil else { return }
            running = true

            let interval = configuration.baseInterval
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(
                deadline: .now() + interval,
                repeating: interval,
                leeway: .milliseconds(Int(interval * configuration.leewayFraction * 1000))
            )
            source.setEventHandler { [weak self] in self?.fire() }
            source.resume()
            timer = source
        }
    }

    public func stop() {
        queue.sync { [self] in
            running = false
            timer?.cancel()
            timer = nil
            // Sources keep their subscribers but drop their hardware handles;
            // delta state is re-primed on resume so the first post-wake reading
            // is not a spike covering the whole sleep period.
            for (key, registration) in registrations where registration.isActive {
                registration.source.deactivate()
                registrations[key]?.isActive = false
                registrations[key]?.lastSampledAt = nil
            }
        }
    }

    /// Sample once, right now, without waiting for the next tick. Used to paint
    /// something real immediately on launch or on wake instead of showing a
    /// placeholder for a full second.
    public func sampleNow() {
        queue.async { [self] in
            for key in registrations.keys { activateIfNeeded(key) }
            // Forced: "sample once, right now" has to mean every source, not
            // only the ones whose cadence happens to land on this tick.
            // Otherwise opening the editor leaves every slow metric -- disk
            // capacity, temperatures, battery -- showing a dash for up to thirty
            // seconds, which reads as broken rather than as unsampled.
            fire(forcingAll: true)
        }
    }

    // MARK: - The tick

    private func fire(forcingAll: Bool = false) {
        tick &+= 1
        sink.reset()

        // One clock read for the whole tick, not one per source.
        let now = DispatchTime.now().uptimeNanoseconds

        for (key, registration) in registrations {
            guard registration.subscribers > 0 else { continue }
            guard forcingAll || tick % UInt64(registration.divisor) == 0 else { continue }
            activateIfNeeded(key)

            // `lastSampledAt` may have just been cleared by activation, in which
            // case elapsed is zero and rate sources correctly stay silent.
            let elapsed = registrations[key]?.lastSampledAt.map {
                Double(now &- $0) / 1_000_000_000
            } ?? 0
            registrations[key]?.lastSampledAt = now
            registrations[key]?.source.sample(into: &sink, context: SampleContext(elapsed: elapsed))
        }

        for reading in sink.readings {
            latest[reading.id] = reading.value
            lastUpdated[reading.id] = tick
            history[reading.id]?.append(Float(reading.value))
        }

        guard !observers.isEmpty else { return }

        // A tick that produced no readings is usually nothing to report -- but
        // not always. If a metric just aged out, the observers need to hear
        // about it, or a value that stopped arriving would sit frozen in the
        // menu bar looking entirely plausible. Delivering when the fresh set
        // *shrank* catches exactly that case without waking the UI on every
        // idle tick.
        let values = freshValues()
        guard !sink.readings.isEmpty || values.count < lastDeliveredCount else { return }
        lastDeliveredCount = values.count

        let snapshot = Snapshot(tick: tick, values: values)
        let handlers = Array(observers.values)
        DispatchQueue.main.async {
            for handler in handlers { handler(snapshot) }
        }
    }

    /// Latest values, with anything that has stopped reporting removed.
    ///
    /// A metric goes quiet for real reasons -- a volume was ejected, a VPN
    /// dropped, a sensor vanished on a macOS update. Left alone, its last value
    /// would sit frozen in the menu bar looking perfectly plausible, which is the
    /// worst possible failure for a monitoring tool. Dropping it turns the cell
    /// into a placeholder instead.
    ///
    /// The allowance is three of the owning source's own intervals, so a 30
    /// second capacity metric is not judged by the standards of a 1 second one.
    private func freshValues() -> [MetricID: Double] {
        var result: [MetricID: Double] = [:]
        result.reserveCapacity(latest.count)

        for (metric, value) in latest {
            guard let updated = lastUpdated[metric] else { continue }
            let divisor = ownership[metric].flatMap { registrations[$0]?.divisor } ?? 1
            guard tick &- updated <= UInt64(divisor * 3) else { continue }
            result[metric] = value
        }

        return result
    }

    // MARK: - Reading history

    /// The last `count` samples for a metric, oldest first. `NaN` entries mean
    /// "not sampled yet" and must be skipped by renderers rather than drawn as
    /// zero -- a graph that starts at the floor is a lie about the past.
    public func history(for metric: MetricID, count: Int) -> [Float] {
        queue.sync { history[metric]?.suffix(count) ?? [] }
    }

    public func value(for metric: MetricID) -> Double? {
        queue.sync { latest[metric] }
    }
}
