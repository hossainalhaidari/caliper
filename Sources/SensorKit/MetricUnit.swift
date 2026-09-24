/// The physical dimension of a reading.
///
/// Units live here rather than in the renderer because they are a property of
/// the *measurement*, not of how it is drawn. The renderer decides "1.2 MB/s"
/// vs "1234 KB/s"; SensorKit only guarantees the number is bytes per second.
public enum MetricUnit: String, Sendable, Codable, CaseIterable {
    /// 0...100, not 0...1. Chosen because every drawing surface and every
    /// threshold a user types is in whole percent.
    case percent
    case bytes
    case bytesPerSecond
    case celsius
    case watts
    case hertz
    /// Revolutions per minute. Distinct from `count` because a fan reading is
    /// four digits wide and carries a unit, and `count` is neither -- sharing
    /// the case cost fans both their suffix and their layout reservation.
    case rpm
    /// A dimensionless count (processes, cores, packets).
    case count
    case seconds
    /// Seconds since the Unix epoch. Formatted as a date or a time, never as a
    /// number -- nobody wants to read 1787601111 off their menu bar.
    case timestamp
}

/// The value range a metric can occupy, when it is known.
///
/// Bounded metrics can be drawn as a proportion (arc, pie, filled bar);
/// unbounded ones can only be drawn as text or against a rolling auto-scale.
/// Renderers use this to refuse bindings that make no sense rather than
/// silently drawing a meaningless 3%-full donut for network throughput.
public enum MetricRange: Sendable, Equatable {
    case bounded(min: Double, max: Double)
    case unbounded(min: Double)

    public static let percentage = MetricRange.bounded(min: 0, max: 100)

    public var isBounded: Bool {
        if case .bounded = self { return true }
        return false
    }
}

/// Everything the UI needs to know about a metric without having read one yet.
///
/// The widget editor and the M4 document importer both browse `MetricDescriptor`
/// values -- that is how "which metrics does this Mac actually have?" gets
/// answered without sampling anything.
public struct MetricDescriptor: Sendable, Identifiable {
    public let id: MetricID
    /// Shown in the editor's metric picker.
    public let displayName: String
    /// Groups related metrics in the picker ("CPU", "Memory").
    ///
    /// A key as much as a label: the panel decides which processes to list by
    /// it, and captions are derived from it. So it stays in English, and what a
    /// person reads is `groupTitle`.
    public let group: String
    public let unit: MetricUnit
    public let range: MetricRange

    public init(
        id: MetricID,
        displayName: String,
        group: String,
        unit: MetricUnit,
        range: MetricRange
    ) {
        self.id = id
        self.displayName = displayName
        self.group = group
        self.unit = unit
        self.range = range
    }
}

public extension MetricDescriptor {
    /// `group`, in the reader's language.
    var groupTitle: String { Self.title(ofGroup: group) }

    /// Every group a source declares, spelled out rather than looked up by a
    /// computed key, so the catalogue check can see each one. A group added to
    /// a source without a line here shows its English key, which is the same
    /// failure as a missing translation and no worse.
    static func title(ofGroup group: String) -> String {
        switch group {
        case "Battery": String(localized: "Battery", comment: "Metric group")
        case "CPU": String(localized: "CPU", comment: "Metric group: the processor as a whole")
        case "CPU Cores": String(localized: "CPU Cores", comment: "Metric group: one metric per processor core")
        case "Disk": String(localized: "Disk", comment: "Metric group: disk reads and writes")
        case "Fans": String(localized: "Fans", comment: "Metric group")
        case "GPU": String(localized: "GPU", comment: "Metric group: the graphics processor")
        case "Memory": String(localized: "Memory", comment: "Metric group")
        case "Network": String(localized: "Network", comment: "Metric group: all interfaces together")
        case "Network Interfaces": String(localized: "Network Interfaces", comment: "Metric group: one set of metrics per interface")
        case "Power": String(localized: "Power", comment: "Metric group: power drawn, in watts")
        case "Temperature": String(localized: "Temperature", comment: "Metric group: the summary temperatures")
        case "Temperature (Advanced)": String(localized: "Temperature (Advanced)", comment: "Metric group: every raw temperature sensor")
        case "Time": String(localized: "Time", comment: "Metric group: the clock")
        case "Volumes": String(localized: "Volumes", comment: "Metric group: disk capacity, one set per mounted volume")
        default: group
        }
    }
}
