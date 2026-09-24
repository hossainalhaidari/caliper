import Foundation

/// How often a source wants to be sampled.
///
/// Sources declare a cadence instead of owning a timer. The bus quantises these
/// to whole multiples of its base tick so that *everything* in the process
/// wakes up on the same schedule -- see `MetricBus` for why that matters.
public enum Cadence: Sendable, Comparable, CaseIterable {
    /// Anything the eye reads as "live": CPU, network, disk throughput.
    case live       // 1s
    /// Physically slow-moving, and often expensive to read. Temperatures are
    /// one IOKit round trip *per sensor key*; sampling them at 1Hz is most of
    /// what makes naive stats apps costly.
    case relaxed    // 5s
    /// Capacity-style values that barely move.
    case idle       // 30s
    /// Never polled; the source pushes when the OS notifies it (battery,
    /// mount/unmount). Sampled once on activation to get an initial value.
    case onDemand

    /// Number of base ticks between samples, at the bus's default 1s tick.
    public var tickDivisor: Int {
        switch self {
        case .live: 1
        case .relaxed: 5
        case .idle: 30
        case .onDemand: 0
        }
    }
}

/// A preallocated destination for readings produced during one tick.
///
/// The bus owns exactly one of these and reuses it forever. Sources append into
/// it rather than returning an array, so a steady-state tick performs no heap
/// allocation at all once the buffer has grown to its working size.
public struct SampleSink: Sendable {
    public private(set) var readings: [Reading] = []

    public init(reservingCapacity capacity: Int = 64) {
        readings.reserveCapacity(capacity)
    }

    public mutating func emit(_ id: MetricID, _ value: Double) {
        readings.append(Reading(id: id, value: value))
    }

    /// Called by the bus at the start of every tick. Keeps capacity.
    public mutating func reset() {
        readings.removeAll(keepingCapacity: true)
    }
}

/// What the bus knows about this sample that the source cannot work out alone.
///
/// Rate metrics -- network throughput, disk I/O -- are deltas over time, and the
/// time is not a constant. The bus ticks with deliberate leeway so the kernel can
/// coalesce wakeups, sources run at different cadences, and a resumed timer will
/// not land exactly on the beat. Dividing a byte delta by an assumed 1.0 seconds
/// would report throughput that is quietly wrong by however much the tick drifted.
///
/// The bus measures the interval once per source and hands it over, so no source
/// has to read a clock and they all agree on what "per second" means.
public struct SampleContext: Sendable {
    /// Seconds since this source's previous sample. Zero on the first sample
    /// after `activate()`, where there is no baseline to measure against.
    public let elapsed: TimeInterval

    public init(elapsed: TimeInterval) {
        self.elapsed = elapsed
    }

    /// True when there is no usable interval, so rate sources should stay silent.
    public var hasInterval: Bool { elapsed > 0 }
}

/// One value, at one instant.
public struct Reading: Sendable, Equatable {
    public let id: MetricID
    public let value: Double

    public init(id: MetricID, value: Double) {
        self.id = id
        self.value = value
    }
}

/// A thing that can read some hardware.
///
/// Conformances are **queue-confined**: the bus guarantees `activate`,
/// `sample` and `deactivate` are only ever called on its own serial queue, and
/// never concurrently. That is why concrete sources declare `@unchecked
/// Sendable` -- their mutable delta state is protected by that discipline, not
/// by a lock.
public protocol MetricSource: AnyObject, Sendable {
    /// Every metric this source can produce, whether or not anyone wants it.
    var descriptors: [MetricDescriptor] { get }

    var cadence: Cadence { get }

    /// Called when the subscriber count goes 0 -> 1. Open ports, allocate
    /// buffers, prime delta state here -- never in `init`, or an app showing
    /// only CPU would still be holding a GPU connection open.
    func activate()

    /// Called when the subscriber count goes 1 -> 0. Release everything.
    func deactivate()

    /// Read the hardware and emit readings. Must not block.
    func sample(into sink: inout SampleSink, context: SampleContext)
}

public extension MetricSource {
    func activate() {}
    func deactivate() {}
}
