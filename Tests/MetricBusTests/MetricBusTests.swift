import Foundation
import SensorKit
import Testing
@testable import MetricBus

/// Records the bus's lifecycle calls so the refcounting contract can be
/// asserted. Locked because the test thread reads what the bus queue writes.
final class SpySource: MetricSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _activations = 0
    private var _deactivations = 0
    private var _samples = 0
    private var _lastElapsed: TimeInterval = -1
    private var _firstElapsed: TimeInterval?

    var activations: Int { lock.withLock { _activations } }
    var deactivations: Int { lock.withLock { _deactivations } }
    var samples: Int { lock.withLock { _samples } }
    var lastElapsed: TimeInterval { lock.withLock { _lastElapsed } }
    /// The interval handed to the very first sample, kept however many follow.
    var firstElapsed: TimeInterval? { lock.withLock { _firstElapsed } }

    let cadence: Cadence

    init(cadence: Cadence = .live) { self.cadence = cadence }

    var descriptors: [MetricDescriptor] {
        [
            MetricDescriptor(
                id: "spy.value",
                displayName: "Spy",
                group: "Test",
                unit: .percent,
                range: .percentage
            )
        ]
    }

    func activate() { lock.withLock { _activations += 1 } }
    func deactivate() { lock.withLock { _deactivations += 1 } }

    func sample(into sink: inout SampleSink, context: SampleContext) {
        lock.withLock {
            _samples += 1
            _lastElapsed = context.elapsed
            if _firstElapsed == nil { _firstElapsed = context.elapsed }
        }
        sink.emit("spy.value", 42)
    }
}

@Suite("Metric bus")
struct MetricBusTests {

    /// `availableMetrics()` goes through the bus's serial queue, so calling it
    /// guarantees every previously enqueued block has finished. Cheaper and far
    /// more reliable than sleeping.
    private func drain(_ bus: MetricBus) {
        _ = bus.availableMetrics()
    }

    @Test("registering does not touch hardware")
    func registrationIsInert() {
        let bus = MetricBus()
        let spy = SpySource()
        bus.register(spy)

        #expect(spy.activations == 0, "a registered but unsubscribed source must stay cold")
        #expect(spy.samples == 0)
    }

    @Test("first subscriber activates, last one deactivates")
    func refcounting() {
        let bus = MetricBus()
        let spy = SpySource()
        bus.register(spy)

        let first = bus.subscribe(to: "spy.value")
        #expect(spy.activations == 1)

        let second = bus.subscribe(to: "spy.value")
        #expect(spy.activations == 1, "second subscriber must not re-activate")

        first.cancel()
        drain(bus)
        #expect(spy.deactivations == 0, "still one subscriber left")

        second.cancel()
        drain(bus)
        #expect(spy.deactivations == 1)
    }

    @Test("releasing the subscription object unsubscribes")
    func lifetimeDrivesHardware() {
        let bus = MetricBus()
        let spy = SpySource()
        bus.register(spy)

        do {
            _ = bus.subscribe(to: "spy.value")
        }
        drain(bus)

        #expect(spy.activations == 1)
        #expect(spy.deactivations == 1, "deinit must release the source")
    }

    @Test("unsubscribed sources are never sampled")
    func onlySamplesWhatIsWatched() async throws {
        var configuration = MetricBus.Configuration()
        configuration.baseInterval = 0.05
        let bus = MetricBus(configuration: configuration)

        let watched = SpySource()
        bus.register(watched)

        bus.start()
        try await Task.sleep(for: .milliseconds(200))
        bus.stop()

        #expect(watched.samples == 0, "nobody subscribed, nothing should have been read")
    }

    @Test("stopping halts sampling")
    func suspension() async throws {
        var configuration = MetricBus.Configuration()
        configuration.baseInterval = 0.05
        let bus = MetricBus(configuration: configuration)

        let spy = SpySource()
        bus.register(spy)
        let subscription = bus.subscribe(to: "spy.value")

        bus.start()
        try await Task.sleep(for: .milliseconds(250))
        bus.stop()

        let afterStop = spy.samples
        #expect(afterStop > 0, "should have sampled while running")

        try await Task.sleep(for: .milliseconds(250))
        #expect(spy.samples == afterStop, "no sampling may happen after stop()")

        subscription.cancel()
    }

    @Test("history retains what was sampled")
    func historyAccumulates() async throws {
        var configuration = MetricBus.Configuration()
        configuration.baseInterval = 0.05
        configuration.historyCapacity = 16
        let bus = MetricBus(configuration: configuration)

        let spy = SpySource()
        bus.register(spy)
        let subscription = bus.subscribe(to: "spy.value")

        bus.start()
        try await Task.sleep(for: .milliseconds(250))
        bus.stop()

        let history = bus.history(for: "spy.value", count: 16)
        #expect(!history.isEmpty)
        #expect(history.allSatisfy { $0 == 42 })
        #expect(bus.value(for: "spy.value") == 42)

        subscription.cancel()
    }
}

/// Emits for a fixed number of samples and then falls silent, standing in for a
/// volume being ejected or a sensor disappearing across an OS update.
final class TransientSource: MetricSource, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int

    init(emitting count: Int) { self.remaining = count }

    var cadence: Cadence { .live }

    var descriptors: [MetricDescriptor] {
        [
            MetricDescriptor(
                id: "transient.value",
                displayName: "Transient",
                group: "Test",
                unit: .percent,
                range: .percentage
            )
        ]
    }

    func sample(into sink: inout SampleSink, context: SampleContext) {
        let shouldEmit = lock.withLock { () -> Bool in
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        if shouldEmit { sink.emit("transient.value", 7) }
    }
}

final class SnapshotCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Snapshot] = []

    func record(_ snapshot: Snapshot) { lock.withLock { storage.append(snapshot) } }
    var all: [Snapshot] { lock.withLock { storage } }
    var last: Snapshot? { lock.withLock { storage.last } }
}

@Suite("Metric bus timing and staleness")
struct MetricBusTimingTests {

    private func fastConfiguration() -> MetricBus.Configuration {
        var configuration = MetricBus.Configuration()
        configuration.baseInterval = 0.05
        configuration.historyCapacity = 32
        return configuration
    }

    @Test("first sample after activation reports no interval")
    func firstSampleHasNoInterval() async throws {
        let bus = MetricBus(configuration: fastConfiguration())
        let spy = SpySource()
        bus.register(spy)
        let subscription = bus.subscribe(to: "spy.value")

        bus.start()
        // Waits for the first tick rather than sleeping for "about one": on a
        // loaded CI runner an 80ms sleep ran long enough for three, and the
        // test then asserted on the wrong sample. What matters is the first
        // one, however many follow it.
        let deadline = ContinuousClock.now + .seconds(2)
        while spy.firstElapsed == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        bus.stop()
        subscription.cancel()

        let first = try #require(spy.firstElapsed, "the bus never sampled")
        // Rate sources depend on this being zero rather than an assumed 1.0 --
        // otherwise every launch would open with a fabricated throughput spike.
        #expect(first == 0)
    }

    @Test("measures the real interval, not the nominal one")
    func elapsedIsMeasured() async throws {
        let bus = MetricBus(configuration: fastConfiguration())
        let spy = SpySource()
        bus.register(spy)
        let subscription = bus.subscribe(to: "spy.value")

        bus.start()
        try await Task.sleep(for: .milliseconds(400))
        bus.stop()
        subscription.cancel()

        // Timer leeway means ticks drift by design, so this must be close to the
        // configured interval without being exactly it.
        #expect(spy.lastElapsed > 0.02)
        #expect(spy.lastElapsed < 0.20)
    }

    @Test("a metric that stops reporting is dropped from snapshots")
    func stalenessDropsMetrics() async throws {
        let bus = MetricBus(configuration: fastConfiguration())
        bus.register(TransientSource(emitting: 3))
        let subscription = bus.subscribe(to: "transient.value")

        let collector = SnapshotCollector()
        bus.observe { collector.record($0) }

        bus.start()
        try await Task.sleep(for: .milliseconds(600))
        bus.stop()
        subscription.cancel()

        let snapshots = collector.all
        #expect(snapshots.contains { $0.values["transient.value"] != nil },
                "should have seen the metric while it was reporting")

        let final = try #require(snapshots.last)
        #expect(final.values["transient.value"] == nil,
                "a metric that stopped reporting must not linger in the menu bar")
    }

    @Test("refreshDescriptors adopts metrics that appear later")
    func dynamicDescriptors() {
        let bus = MetricBus(configuration: fastConfiguration())
        let spy = SpySource()
        bus.register(spy)

        // Idempotent: hardware notifications can arrive in bursts, and mount
        // plus unmount in quick succession must not duplicate anything.
        let before = bus.availableMetrics().count
        bus.refreshDescriptors()
        bus.refreshDescriptors()
        #expect(bus.availableMetrics().count == before)
    }
}

@Suite("Metric ordering")
struct MetricOrderingTests {

    @Test("metrics come back in registration order, every time")
    func orderIsDeterministic() {
        // Nondeterministic order is not a cosmetic problem: the detail panel
        // headlines a group with its first metric, and hash-ordered iteration
        // once opened the CPU panel titled "Efficiency Cores".
        let bus = MetricBus()
        bus.register(CPULoadSource())
        bus.register(CPUCoreSource())
        bus.register(MemorySource())

        let first = bus.availableMetrics().map(\.id)
        #expect(first.first == CPULoadSource.total,
                "the first registered source's first metric must lead")

        for _ in 0..<20 {
            #expect(bus.availableMetrics().map(\.id) == first)
        }
    }

    @Test("order is stable across a descriptor refresh")
    func refreshPreservesOrder() {
        let bus = MetricBus()
        bus.register(CPULoadSource())
        bus.register(MemorySource())

        let before = bus.availableMetrics().map(\.id)
        bus.refreshDescriptors()
        #expect(bus.availableMetrics().map(\.id) == before)
    }
}
