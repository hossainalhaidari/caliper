import Foundation

/// Fan speeds, from the SMC.
///
/// ## Verified on hardware that has fans
///
/// This used to read Apple's HID fan usage, written on a fanless M4 MacBook Air
/// and never run anywhere that could contradict it. An M4 Max Mac Studio did:
/// the HID vendor page publishes 39 temperature sensors and nothing whatsoever
/// at the fan usage, so the capability probe correctly found zero fans and the
/// app correctly offered none -- on a machine whose two fans were spinning at
/// the time. Reading the SMC directly returns both of them.
///
/// `SMCSensors` documents the byte-order trap that made the SMC look empty too.
///
/// ## What the fan keys are
///
/// `FNum` is the fan count. Each fan `i` then has `F<i>Ac` for its actual
/// speed and `F<i>Mx` for its rated maximum. The count is treated as a hint
/// rather than a promise: indices are probed and only those that actually read
/// are published, so a machine that reports more fans than it exposes keys for
/// produces no permanent dashes.
///
/// The rated maximum is worth reading for more than curiosity. It makes the
/// metric *bounded*, which is what reserves a four-digit column for it -- an
/// unbounded reading is laid out for three digits, and a fan idling at 1100
/// then overruns its cell into whatever is drawn next to it.
///
/// Read-only, deliberately and permanently. Writing SMC keys can drive fans
/// beyond their rated speed or stop them entirely, and no menu bar app has any
/// business doing that.
public final class FanSource: MetricSource, @unchecked Sendable {
    public static let count: MetricID = "fan.count"
    public static let peak: MetricID = "fan.peak.rpm"

    public static func fan(_ index: Int) -> MetricID {
        MetricID("fan.\(index).rpm")
    }

    /// A fan reading outside this range is a decode error, not a fan.
    private static let plausibleRPM = 0.0 ..< 20_000.0

    /// Machines have single-digit fan counts; the cap only stops a nonsense
    /// `FNum` from turning into thousands of probe round trips.
    private static let maxFans = 16

    /// One fan: its SMC index, and its rated maximum where the machine states
    /// one. A fan whose maximum is missing stays unbounded rather than being
    /// given an invented ceiling.
    private struct Fan {
        let index: Int
        let maxRPM: Double?
    }

    private let interface = SMCInterface.shared
    private var connection: io_connect_t?
    private var indices: [Int] = []
    private let discovered: [Fan]

    public init() {
        guard interface.isSupported, let connection = interface.open() else {
            discovered = []
            return
        }
        defer { interface.close(connection) }
        discovered = Self.probe(connection, interface: interface)
    }

    /// Fans that answer with a plausible speed right now.
    private static func probe(_ connection: io_connect_t, interface: SMCInterface) -> [Fan] {
        let reported = interface.read(connection, key: "FNum").map { Int($0) } ?? 0
        guard reported > 0 else { return [] }

        return (0 ..< min(reported, maxFans)).compactMap { index in
            guard let rpm = interface.read(connection, key: "F\(index)Ac"),
                  rpm.isFinite, plausibleRPM.contains(rpm) else { return nil }

            let rated = interface.read(connection, key: "F\(index)Mx")
            let maxRPM = rated.flatMap { $0.isFinite && plausibleRPM.contains($0) && $0 > 0 ? $0 : nil }
            return Fan(index: index, maxRPM: maxRPM)
        }
    }

    /// A fan's range, bounded by what the hardware says it can do.
    private static func range(forMax maxRPM: Double?) -> MetricRange {
        guard let maxRPM else { return .unbounded(min: 0) }
        // From zero, not from the rated minimum: a stopped fan is a real
        // reading, and a gauge that starts at 1000 would draw it as full.
        return .bounded(min: 0, max: maxRPM)
    }

    public var cadence: Cadence { .relaxed }

    public var descriptors: [MetricDescriptor] {
        // Zero fans means zero metrics: a fanless Mac should not offer a fan
        // reading that will forever be a dash.
        guard !discovered.isEmpty else { return [] }

        // The fastest fan can reach the highest ceiling any single fan has.
        let peakMax = discovered.compactMap(\.maxRPM).max()

        var result: [MetricDescriptor] = [
            MetricDescriptor(id: Self.peak, displayName: String(localized: "Fastest Fan", comment: "Metric name, in the metric picker and the detail panel"), group: "Fans", unit: .rpm, range: Self.range(forMax: peakMax)),
            MetricDescriptor(id: Self.count, displayName: String(localized: "Fan Count", comment: "Metric name, in the metric picker and the detail panel"), group: "Fans", unit: .count, range: .bounded(min: 0, max: Double(discovered.count))),
        ]
        for (position, fan) in discovered.enumerated() {
            result.append(
                MetricDescriptor(
                    id: Self.fan(position),
                    displayName: String(localized: "Fan \(position + 1)", comment: "Metric name, in the metric picker and the detail panel"),
                    group: "Fans",
                    unit: .rpm,
                    range: Self.range(forMax: fan.maxRPM)
                )
            )
        }
        return result
    }

    public func activate() {
        guard !discovered.isEmpty else { return }
        connection = interface.open()
        indices = connection == nil ? [] : discovered.map(\.index)
    }

    public func deactivate() {
        if let connection { interface.close(connection) }
        connection = nil
        indices = []
    }

    public func sample(into sink: inout SampleSink, context: SampleContext) {
        guard let connection, !indices.isEmpty else { return }

        var speeds: [Double] = []
        for (position, index) in indices.enumerated() {
            guard let rpm = interface.read(connection, key: "F\(index)Ac"),
                  rpm.isFinite, Self.plausibleRPM.contains(rpm) else { continue }
            sink.emit(Self.fan(position), rpm)
            speeds.append(rpm)
        }

        guard !speeds.isEmpty else { return }
        sink.emit(Self.count, Double(speeds.count))
        sink.emit(Self.peak, speeds.max() ?? 0)
    }
}
