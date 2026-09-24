import SensorKit

/// The state of every subscribed metric at one tick, handed to observers.
///
/// Immutable and `Sendable` so it can cross from the sampling queue to the main
/// actor without copying discipline or locks.
public struct Snapshot: Sendable {
    /// Monotonic tick number since the bus started. Useful for "has anything
    /// happened since I last drew?" checks without comparing values.
    public let tick: UInt64
    public let values: [MetricID: Double]

    public init(tick: UInt64, values: [MetricID: Double]) {
        self.tick = tick
        self.values = values
    }

    public subscript(id: MetricID) -> Double? { values[id] }
}
