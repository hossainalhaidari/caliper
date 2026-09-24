import Foundation

/// Power draw in watts, derived from IOReport's energy counters.
///
/// IOReport reports **energy**, not power: each sample is the joules accumulated
/// since the previous one. Watts come from dividing by the measured interval,
/// which is why this source depends on `SampleContext.elapsed` being real rather
/// than assumed -- at a 1 Hz tick with leeway, treating the interval as exactly
/// one second would put a few percent of error into every reading.
///
/// No root, and no `powermetrics`. That was the reason for choosing IOReport in
/// the first place: the same figures without a privileged helper daemon, which
/// removes an entire category of install friction and security surface.
public final class PowerSource: MetricSource, @unchecked Sendable {
    public static let cpu: MetricID = "power.cpu.watts"
    public static let gpu: MetricID = "power.gpu.watts"
    public static let ane: MetricID = "power.ane.watts"
    public static let dram: MetricID = "power.dram.watts"
    public static let total: MetricID = "power.total.watts"

    /// Channel names, in order of preference.
    ///
    /// An M4 publishes both "GPU Energy" (in nJ) and "GPU" (in mJ) for the same
    /// quantity; the finer-grained one is preferred where both exist.
    private static let mapping: [(metric: MetricID, channels: [String])] = [
        (cpu, ["CPU Energy", "CPU"]),
        (gpu, ["GPU Energy", "GPU"]),
        (ane, ["ANE Energy", "ANE"]),
        (dram, ["DRAM Energy", "DRAM"]),
    ]

    private let interface = IOReportInterface.shared
    private var subscription: IOReportInterface.Subscription?
    private var previous: CFDictionary?
    private let available: Bool

    public init() {
        available = IOReportInterface.shared.isSupported
            && IOReportInterface.shared.subscribe(group: "Energy Model") != nil
    }

    public var cadence: Cadence { .live }

    public var descriptors: [MetricDescriptor] {
        guard available else { return [] }

        func watts(_ id: MetricID, _ name: String) -> MetricDescriptor {
            MetricDescriptor(id: id, displayName: name, group: "Power", unit: .watts, range: .unbounded(min: 0))
        }

        return [
            watts(Self.total, String(localized: "Total Power", comment: "Metric name, in the metric picker and the detail panel")),
            watts(Self.cpu, String(localized: "CPU Power", comment: "Metric name, in the metric picker and the detail panel")),
            watts(Self.gpu, String(localized: "GPU Power", comment: "Metric name, in the metric picker and the detail panel")),
            watts(Self.ane, String(localized: "Neural Engine Power", comment: "Metric name, in the metric picker and the detail panel")),
            watts(Self.dram, String(localized: "Memory Power", comment: "Metric name, in the metric picker and the detail panel")),
        ]
    }

    public func activate() {
        guard available else { return }
        subscription = interface.subscribe(group: "Energy Model")
        // Prime, so the first reported interval is a real one rather than
        // everything accumulated since the subscription opened.
        previous = subscription.flatMap { interface.sample($0) }
    }

    public func deactivate() {
        subscription = nil
        previous = nil
    }

    public func sample(into sink: inout SampleSink, context: SampleContext) {
        guard let subscription, let current = interface.sample(subscription) else { return }
        defer { previous = current }

        guard context.hasInterval, let first = previous else { return }

        let energy = interface.energyDelta(from: first, to: current)
        guard !energy.isEmpty else { return }

        var total = 0.0
        for entry in Self.mapping {
            guard let channel = entry.channels.first(where: { energy[$0] != nil }),
                  let joules = energy[channel] else { continue }
            let watts = joules / context.elapsed
            sink.emit(entry.metric, watts)
            total += watts
        }

        // A sum of the parts rather than a package counter, which Apple Silicon
        // does not expose. Named "total" rather than "package" so it does not
        // claim to be something the hardware measured.
        guard total > 0 else { return }
        sink.emit(Self.total, total)
    }
}
