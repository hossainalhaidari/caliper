import Foundation

/// The current time, as a metric.
///
/// A clock is not obviously a sensor, and making it one is a deliberate choice
/// rather than a convenience. The alternative -- a renderer that simply reads
/// `Date()` when asked to draw -- looks simpler and is broken: a widget
/// containing only a clock would subscribe to nothing, so the bus would deliver
/// no snapshots, nothing would ask it to redraw, and the clock would freeze at
/// whatever second it was created.
///
/// As a source it keeps the single timer alive exactly like any other metric,
/// takes part in the same refcounting, and stops when the screen is locked. And
/// because the redraw check compares rendered output rather than values, a clock
/// showing only hours and minutes is rasterised once a minute despite being
/// sampled once a second.
public final class ClockSource: MetricSource, @unchecked Sendable {
    public static let epoch: MetricID = "time.epoch"
    public static let uptime: MetricID = "system.uptime.seconds"

    public init() {}

    /// Once a second, so a format that shows seconds is right. Formats that do
    /// not simply skip the redraw.
    public var cadence: Cadence { .live }

    public var descriptors: [MetricDescriptor] {
        [
            MetricDescriptor(
                id: Self.epoch,
                displayName: String(localized: "Clock", comment: "Metric name, in the metric picker and the detail panel"),
                group: "Time",
                unit: .timestamp,
                range: .unbounded(min: 0)
            ),
            MetricDescriptor(
                id: Self.uptime,
                displayName: String(localized: "Uptime", comment: "Metric name, in the metric picker and the detail panel"),
                group: "Time",
                unit: .seconds,
                range: .unbounded(min: 0)
            ),
        ]
    }

    public func sample(into sink: inout SampleSink, context: SampleContext) {
        sink.emit(Self.epoch, Date().timeIntervalSince1970)
        // Monotonic since boot, and unaffected by the clock being set.
        sink.emit(Self.uptime, ProcessInfo.processInfo.systemUptime)
    }
}
