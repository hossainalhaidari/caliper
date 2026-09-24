import Foundation

/// Temperatures, from Apple's HID thermal sensors.
///
/// The hard part is not reading them, it is making sense of them. An M4 MacBook
/// Air exposes 47 sensors, and **none** has a human-meaningful name: they are
/// `PMU tdie1`-`tdie14`, `PMU2 tdev1`-`5`, `NAND CH0 temp`, and six sensors all
/// called `gas gauge battery`. There is no "CPU" or "GPU" sensor to find; on
/// hardware that has one, its name differs per model.
///
/// So this publishes two tiers:
///
/// **Aggregates** (`thermal.peak`, `.average`, `.battery`, `.storage`) mean the
/// same thing on any Mac, which is what a shared widget needs. They are the
/// portable spelling.
///
/// **Raw sensors** (`thermal.sensor.*`) are every individual reading, for people
/// who want them. Their ids embed a machine-specific name, exactly like
/// `disk.volume.*`, so a widget built on them will not resolve elsewhere -- and
/// M4's import report says so rather than failing quietly.
public final class ThermalSource: MetricSource, @unchecked Sendable {
    public static let peak: MetricID = "thermal.peak"
    public static let average: MetricID = "thermal.average"
    public static let battery: MetricID = "thermal.battery"
    public static let storage: MetricID = "thermal.storage"

    public static func sensor(_ slug: String) -> MetricID {
        MetricID("thermal.sensor.\(slug)")
    }

    struct Sensor {
        let name: String
        let slug: String
        let metric: MetricID
        let category: Category
        let service: AnyObject
    }

    enum Category {
        case chip
        case battery
        case storage
        /// A calibration reference rather than a measurement. Excluded from the
        /// aggregates: on an M4 both `tcal` sensors sit at exactly 51.82 C and
        /// would otherwise pin `thermal.peak` to a constant that means nothing.
        case reference
    }

    /// Sensors read per sample.
    ///
    /// `IOHIDServiceClientCopyEvent` takes about 745 microseconds per sensor, so
    /// reading all 47 costs **44 milliseconds**. That first looked like a CPU
    /// disaster; measuring properly showed it is not one. Of those 745
    /// microseconds only 32 are CPU -- the call is 96% blocking wait on an IPC
    /// round trip to the HID event system, and there is no batch form.
    ///
    /// The problem is therefore not cost but **occupancy**. `MetricBus` samples
    /// every source on one serial queue, so 44 ms in here is 44 ms during which
    /// nothing else is read: on a one-second tick that is 4% of the interval
    /// spent stalled, and every other source's cadence jitters behind it.
    ///
    /// So the sensors are read round-robin, six per sample, with every reading
    /// cached. That is about 4.5 ms of queue time every five seconds, and each
    /// individual sensor refreshes roughly every forty seconds.
    ///
    /// The trade is right *for this quantity*: temperatures move over minutes,
    /// not milliseconds, so a forty-second-old reading of one sensor is as good
    /// as a fresh one. The aggregates still update every sample, mixing fresh
    /// readings with cached ones.
    static let batchSize = 6

    private let interface = HIDSensorInterface.shared
    private var client: AnyObject?
    private var sensors: [Sensor] = []
    private var readings: [Double?] = []
    private var cursor = 0
    private let available: Bool

    public init() {
        // Probe once at startup, so a machine where these symbols have gone
        // publishes nothing rather than a picker full of dead metrics.
        guard interface.isSupported, let client = HIDSensorInterface.shared.makeClient() else {
            available = false
            return
        }
        let found = HIDSensorInterface.shared.services(
            from: client, usage: HIDSensorInterface.temperatureUsage
        )
        available = !found.isEmpty
    }

    public var cadence: Cadence { .relaxed }

    public var descriptors: [MetricDescriptor] {
        guard available else { return [] }

        var result: [MetricDescriptor] = [
            MetricDescriptor(id: Self.peak, displayName: String(localized: "Hottest Sensor", comment: "Metric name, in the metric picker and the detail panel"), group: "Temperature", unit: .celsius, range: .bounded(min: 0, max: 110)),
            MetricDescriptor(id: Self.average, displayName: String(localized: "Average Temperature", comment: "Metric name, in the metric picker and the detail panel"), group: "Temperature", unit: .celsius, range: .bounded(min: 0, max: 110)),
        ]

        // The catalogue needs sensors enumerated even before activation, so the
        // editor can offer them without something being bound first.
        for sensor in sensors.isEmpty ? discover() : sensors {
            switch sensor.category {
            case .battery where !result.contains(where: { $0.id == Self.battery }):
                result.append(MetricDescriptor(id: Self.battery, displayName: String(localized: "Battery Temperature", comment: "Metric name, in the metric picker and the detail panel"), group: "Temperature", unit: .celsius, range: .bounded(min: 0, max: 110)))
            case .storage where !result.contains(where: { $0.id == Self.storage }):
                result.append(MetricDescriptor(id: Self.storage, displayName: String(localized: "Storage Temperature", comment: "Metric name, in the metric picker and the detail panel"), group: "Temperature", unit: .celsius, range: .bounded(min: 0, max: 110)))
            default:
                break
            }
        }

        for sensor in sensors.isEmpty ? discover() : sensors {
            result.append(
                MetricDescriptor(
                    id: sensor.metric,
                    displayName: sensor.name,
                    group: "Temperature (Advanced)",
                    unit: .celsius,
                    range: .bounded(min: 0, max: 110)
                )
            )
        }

        return result
    }

    public func activate() {
        guard available else { return }
        client = interface.makeClient()
        sensors = discover()
        readings = Array(repeating: nil, count: sensors.count)
        cursor = 0
    }

    public func deactivate() {
        client = nil
        sensors = []
        readings = []
    }

    public func sample(into sink: inout SampleSink, context: SampleContext) {
        guard !sensors.isEmpty else { return }

        // Refresh this tick's slice of the rotation.
        let batch = min(Self.batchSize, sensors.count)
        for offset in 0..<batch {
            let index = (cursor + offset) % sensors.count
            let value = interface.read(
                sensors[index].service,
                eventType: HIDSensorInterface.temperatureEvent
            )
            readings[index] = value.flatMap { Self.isPlausible($0) ? $0 : nil }
        }
        cursor = (cursor + batch) % sensors.count

        var chipReadings: [Double] = []
        var batteryReadings: [Double] = []
        var storageReadings: [Double] = []

        // Every sensor reports every tick, using its most recent reading. A cell
        // bound to one sensor would otherwise show a dash for the thirty-odd
        // seconds between its turns in the rotation.
        for (index, sensor) in sensors.enumerated() {
            guard let value = readings[index] else { continue }
            sink.emit(sensor.metric, value)

            switch sensor.category {
            case .chip: chipReadings.append(value)
            case .battery: batteryReadings.append(value)
            case .storage: storageReadings.append(value)
            case .reference: break
            }
        }

        if let hottest = chipReadings.max() { sink.emit(Self.peak, hottest) }
        if !chipReadings.isEmpty {
            sink.emit(Self.average, chipReadings.reduce(0, +) / Double(chipReadings.count))
        }
        if let batteryPeak = batteryReadings.max() { sink.emit(Self.battery, batteryPeak) }
        if let storagePeak = storageReadings.max() { sink.emit(Self.storage, storagePeak) }
    }

    // MARK: - Discovery

    /// Rejects readings no Mac produces.
    ///
    /// Three sensors on the development machine sit at about -22 C: unpopulated
    /// channels reporting a sentinel rather than a temperature. Including them
    /// would drag the average down and make the minimum meaningless.
    static func isPlausible(_ value: Double) -> Bool {
        value > -5 && value < 150
    }

    static func categorise(_ name: String) -> Category {
        let lowered = name.lowercased()
        if lowered.contains("tcal") { return .reference }
        if lowered.contains("battery") || lowered.contains("gas gauge") { return .battery }
        if lowered.contains("nand") || lowered.contains("ssd") || lowered.contains("nvme") { return .storage }
        return .chip
    }

    /// Sensor names are not unique -- six on this machine are all "gas gauge
    /// battery" -- so identical names get a numeric suffix. Without it several
    /// sensors would collapse onto one metric id and silently overwrite each
    /// other.
    static func slugs(for names: [String]) -> [String] {
        var counts: [String: Int] = [:]
        var result: [String] = []

        for name in names {
            let base = name
                .lowercased()
                .map { $0.isLetter || $0.isNumber ? $0 : "-" }
                .reduce(into: "") { $0.append($1) }
                .split(separator: "-", omittingEmptySubsequences: true)
                .joined(separator: "-")

            let slug = base.isEmpty ? "sensor" : base
            let seen = counts[slug, default: 0]
            counts[slug] = seen + 1
            result.append(seen == 0 ? slug : "\(slug)-\(seen + 1)")
        }

        return result
    }

    private func discover() -> [Sensor] {
        guard let client = client ?? interface.makeClient() else { return [] }
        let found = interface.services(from: client, usage: HIDSensorInterface.temperatureUsage)
        let slugs = Self.slugs(for: found.map(\.name))

        return zip(found, slugs).map { entry, slug in
            Sensor(
                name: entry.name,
                slug: slug,
                metric: Self.sensor(slug),
                category: Self.categorise(entry.name),
                service: entry.service
            )
        }
    }
}
