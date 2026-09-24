import Foundation
import IOKit
import IOKit.ps

/// Battery charge, health, and draw.
///
/// The only entirely public thing in this milestone: `IOPowerSources` and the
/// `AppleSmartBattery` registry entry are both documented. It is here because a
/// laptop's battery is the single most useful thing in the tier, not because it
/// needed private access.
public final class BatterySource: MetricSource, @unchecked Sendable {
    public static let charge: MetricID = "battery.charge.percent"
    public static let health: MetricID = "battery.health.percent"
    public static let cycles: MetricID = "battery.cycles"
    public static let timeRemaining: MetricID = "battery.time.remaining.seconds"
    public static let isCharging: MetricID = "battery.charging"
    public static let power: MetricID = "battery.power.watts"

    private var service: io_object_t = IO_OBJECT_NULL
    private let available: Bool

    public init() {
        // A desktop Mac has no battery, and should not be offered these metrics.
        let probe = Self.matchingService()
        available = probe != IO_OBJECT_NULL
        if probe != IO_OBJECT_NULL { IOObjectRelease(probe) }
    }

    public var cadence: Cadence { .relaxed }

    public var descriptors: [MetricDescriptor] {
        guard available else { return [] }
        return [
            MetricDescriptor(id: Self.charge, displayName: String(localized: "Battery Charge", comment: "Metric name, in the metric picker and the detail panel"), group: "Battery", unit: .percent, range: .percentage),
            MetricDescriptor(id: Self.health, displayName: String(localized: "Battery Health", comment: "Metric name, in the metric picker and the detail panel"), group: "Battery", unit: .percent, range: .percentage),
            MetricDescriptor(id: Self.cycles, displayName: String(localized: "Charge Cycles", comment: "Metric name, in the metric picker and the detail panel"), group: "Battery", unit: .count, range: .unbounded(min: 0)),
            MetricDescriptor(id: Self.timeRemaining, displayName: String(localized: "Time Remaining", comment: "Metric name, in the metric picker and the detail panel"), group: "Battery", unit: .seconds, range: .unbounded(min: 0)),
            MetricDescriptor(id: Self.isCharging, displayName: String(localized: "Charging", comment: "Metric name, in the metric picker and the detail panel"), group: "Battery", unit: .count, range: .bounded(min: 0, max: 1)),
            MetricDescriptor(id: Self.power, displayName: String(localized: "Battery Power", comment: "Metric name, in the metric picker and the detail panel"), group: "Battery", unit: .watts, range: .unbounded(min: 0)),
        ]
    }

    public func activate() {
        guard available else { return }
        service = Self.matchingService()
    }

    public func deactivate() {
        if service != IO_OBJECT_NULL { IOObjectRelease(service) }
        service = IO_OBJECT_NULL
    }

    public func sample(into sink: inout SampleSink, context: SampleContext) {
        guard service != IO_OBJECT_NULL,
              let properties = IORegistryEntryCreateCFProperties2(service)
        else { return }

        if let current = properties["CurrentCapacity"] as? Double,
           let maximum = properties["MaxCapacity"] as? Double, maximum > 0 {
            sink.emit(Self.charge, min(100, current / maximum * 100))
        } else if let percent = properties["CurrentCapacity"] as? Double {
            // Some models report CurrentCapacity already as a percentage.
            sink.emit(Self.charge, min(100, percent))
        }

        // Health is capacity now against capacity when new. "AppleRawMaxCapacity"
        // is the honest figure; "MaxCapacity" is often normalised to 100.
        if let design = properties["DesignCapacity"] as? Double, design > 0,
           let raw = (properties["AppleRawMaxCapacity"] ?? properties["NominalChargeCapacity"]) as? Double {
            sink.emit(Self.health, min(100, raw / design * 100))
        }

        if let count = properties["CycleCount"] as? Double {
            sink.emit(Self.cycles, count)
        }

        let charging = (properties["IsCharging"] as? Bool) ?? false
        sink.emit(Self.isCharging, charging ? 1 : 0)

        // Amperage is signed: negative while discharging. Power is reported as a
        // magnitude, with direction carried by `battery.charging`, so a graph of
        // draw does not flip below the axis when you plug in.
        if let amperage = properties["Amperage"] as? Double,
           let voltage = properties["Voltage"] as? Double {
            sink.emit(Self.power, abs(amperage / 1000 * voltage / 1000))
        }

        if let minutes = properties[charging ? "TimeRemaining" : "TimeRemaining"] as? Double,
           minutes > 0, minutes < 1200 {
            // The registry reports minutes; a value of 65535 means "still
            // calculating" and must not be shown as 45 days remaining.
            sink.emit(Self.timeRemaining, minutes * 60)
        }
    }

    // MARK: - IOKit

    private static func matchingService() -> io_object_t {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return IO_OBJECT_NULL }
        return IOServiceGetMatchingService(kIOMainPortDefault, matching)
    }

    private func IORegistryEntryCreateCFProperties2(_ entry: io_object_t) -> [String: Any]? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS
        else { return nil }
        return properties?.takeRetainedValue() as? [String: Any]
    }

    deinit {
        if service != IO_OBJECT_NULL { IOObjectRelease(service) }
    }
}
