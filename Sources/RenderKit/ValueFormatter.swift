import Foundation
import SensorKit

/// Turns a `Double` into the string a cell shows.
///
/// The important method here is not `string(for:)` -- it is `widestString(for:)`.
///
/// A menu bar cell that sizes itself to its *current* text reflows every time
/// CPU crosses from 9% to 10%, which shoves every item to its right sideways.
/// Do that once a second and the menu bar becomes unreadable in the specific
/// way that makes people uninstall stats apps. So every cell measures itself
/// against the widest string it could *ever* produce and never changes width.
/// The number moves; the layout does not.
public struct ValueFormatter: Sendable {
    public var decimals: Int
    /// Suppress the unit suffix, for cells whose label already implies it.
    public var showsUnit: Bool

    public init(decimals: Int = 0, showsUnit: Bool = true) {
        self.decimals = decimals
        self.showsUnit = showsUnit
    }

    /// The glyph shown when there is no reading: an en dash, not "0", not
    /// "n/a". Zero is a lie about the hardware and "n/a" is three characters of
    /// noise in a 40-point cell.
    public static let placeholder = "\u{2013}"

    /// A formatted value split at the boundary between number and unit.
    ///
    /// They are laid out in separate columns: the number right-aligned so its
    /// digits stay put, the unit left-aligned immediately after so it sits at a
    /// fixed x. Rendering them as one right-aligned string instead leaves a
    /// visible hole between a short value and its label -- "0 B/s" floating at
    /// the far end of a slot reserved for "888 MB/s" -- and, worse, lets the
    /// unit slide horizontally as the magnitude changes, so a strip of cells
    /// never lines up.
    public struct Components: Equatable, Sendable {
        public let number: String
        public let suffix: String

        public var joined: String { number + suffix }
    }

    public func string(for value: Double, unit: MetricUnit) -> String {
        components(for: value, unit: unit).joined
    }

    public func components(for value: Double, unit: MetricUnit) -> Components {
        // Checked once, here, so no unit suffix can ever be glued onto the
        // placeholder and produce "-%".
        guard value.isFinite else {
            return Components(number: Self.placeholder, suffix: "")
        }

        return switch unit {
        case .percent:
            Components(number: number(value), suffix: showsUnit ? "%" : "")

        case .bytes:
            scaled(value, units: Self.byteUnits, rateSuffix: "")

        case .bytesPerSecond:
            scaled(value, units: Self.byteUnits, rateSuffix: "/s")

        case .celsius:
            // The degree sign alone, not "°C". At 11pt in a menu bar the "C"
            // costs real width and carries no information -- nobody is
            // wondering whether their Mac is 48 degrees Fahrenheit.
            Components(number: number(value), suffix: showsUnit ? "\u{00B0}" : "")

        case .watts:
            Components(number: number(value), suffix: showsUnit ? " W" : "")

        case .hertz:
            scaled(value, units: ["Hz", "kHz", "MHz", "GHz"], rateSuffix: "", divisor: 1000)

        case .seconds:
            // A duration reads as a duration. "7140.0s" is technically the
            // battery's time remaining and tells you nothing; "1h 59m" is the
            // same fact in the form a person actually holds it in.
            duration(value)

        case .rpm:
            Components(number: number(value), suffix: showsUnit ? " RPM" : "")

        case .count:
            Components(number: number(value), suffix: "")

        case .timestamp:
            Components(number: Self.plainClock.string(from: Date(timeIntervalSince1970: value)), suffix: "")
        }
    }

    /// Fallback for a timestamp shown by a plain text cell. The clock style
    /// exists for anything more considered than this.
    private static let plainClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// The widest string this formatter can produce for the given unit and
    /// range. Used for layout, never displayed.
    ///
    /// Uses "8" as the sample digit: in almost every typeface with tabular
    /// figures all digits are the same width, but where a face cheats, 8 is the
    /// widest. Cheaper and far more robust than measuring all ten.
    public func widestString(for unit: MetricUnit, range: MetricRange) -> String {
        widestComponents(for: unit, range: range).joined
    }

    /// Widest number and widest suffix, sized independently.
    ///
    /// They are maximised separately on purpose: the widest number and the
    /// widest unit need not occur at the same value, and reserving each column
    /// for its own worst case is what guarantees neither can ever overflow.
    public func widestComponents(for unit: MetricUnit, range: MetricRange) -> Components {
        // Durations and clocks are formatted inline and do not follow the digit
        // rules.
        // Wide enough for the days tier: an uptime of several hundred days is
        // unusual but not impossible, and a reservation that a real value can
        // overflow is worse than no reservation at all.
        if unit == .seconds { return Components(number: "888d 88h", suffix: "") }
        if unit == .timestamp { return Components(number: "88:88:88", suffix: "") }

        let text = Self.autoScales(unit)
            ? widestScaledNumber(for: unit)
            : widestPlainNumber(for: range)

        guard showsUnit else { return Components(number: text, suffix: "") }

        // "MB" stands in for every two-letter byte unit; KB, GB and TB differ by
        // a fraction of a point in a proportional face.
        let suffix = switch unit {
        case .percent: "%"
        case .bytes: " MB"
        case .bytesPerSecond: " MB/s"
        case .celsius: "\u{00B0}"
        case .watts: " W"
        case .hertz: " GHz"
        case .rpm: " RPM"
        case .seconds, .timestamp: ""  // these carry their own units inline
        case .count: ""
        }
        return Components(number: text, suffix: suffix)
    }

    /// Units whose values are divided down into KB, MB, GB and so on.
    static func autoScales(_ unit: MetricUnit) -> Bool {
        switch unit {
        case .bytes, .bytesPerSecond, .hertz: true
        default: false
        }
    }

    /// The widest number an auto-scaling unit can produce.
    ///
    /// **Bounded by the radix, not by the metric's range.** This is the fix for a
    /// genuinely absurd reservation: memory used on a 16 GB Mac is declared as
    /// `bounded(0, 17_179_869_184)`, and deriving digits from that raw maximum
    /// reserved room for `88888888888.8 MB` in order to display `11.9 GB`. Disk
    /// free was worse, at twelve digits.
    ///
    /// A scaled value never leaves its unit until it reaches the radix, so the
    /// mantissa lives in `[0, base)` no matter how large the underlying quantity
    /// is. For bytes that means at most `1023` before it becomes `1.0 GB` -- four
    /// digits, not eleven.
    ///
    /// It also fixes a latent overflow in the other direction: the unbounded path
    /// reserved three digits, which `1023 MB/s` does not fit in.
    private func widestScaledNumber(for unit: MetricUnit) -> String {
        let base = ValueScale.base(for: unit)
        let integerDigits = base > 1000 ? 4 : 3

        // Two shapes compete. Above a mantissa of 100 the formatter drops
        // decimals, so the widest all-digit case is "1023"; below it, decimals
        // are kept, so the widest is "99.9". Whichever renders wider wins, and
        // digits are wider than a decimal point at equal length.
        let allDigits = String(repeating: "8", count: integerDigits)
        guard decimals > 0 else { return allDigits }

        let withDecimals = "88." + String(repeating: "8", count: decimals)
        return allDigits.count >= withDecimals.count ? allDigits : withDecimals
    }

    /// For units that are shown as-is, the range really does decide the width.
    private func widestPlainNumber(for range: MetricRange) -> String {
        let integerDigits: Int = switch range {
        case .bounded(_, let max):
            Swift.max(1, String(Int(max.rounded(.up))).count)
        case .unbounded:
            3
        }

        var text = String(repeating: "8", count: integerDigits)
        if decimals > 0 { text += "." + String(repeating: "8", count: decimals) }
        return text
    }

    // MARK: - Internals

    private static let byteUnits = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// The coarsest pair of units that still says something useful.
    ///
    /// The days tier is not cosmetic. Uptime on a machine left running for a
    /// week is 191 hours, which is wider than the two-digit hour the reservation
    /// allowed -- so the number overflowed leftwards into its own label and the
    /// two collided. "7d 23h" is both more readable and bounded.
    private func duration(_ value: Double) -> Components {
        let total = Int(value.rounded())
        guard total >= 60 else { return Components(number: "\(total)s", suffix: "") }

        let minutes = total / 60
        guard minutes >= 60 else { return Components(number: "\(minutes)m", suffix: "") }

        let hours = minutes / 60
        guard hours >= 24 else { return Components(number: "\(hours)h \(minutes % 60)m", suffix: "") }

        return Components(number: "\(hours / 24)d \(hours % 24)h", suffix: "")
    }

    private func number(_ value: Double) -> String {
        String(format: "%.\(decimals)f", value)
    }

    private func scaled(
        _ value: Double,
        units: [String],
        rateSuffix: String,
        divisor: Double = 1024
    ) -> Components {
        var magnitude = abs(value)
        var index = 0
        while magnitude >= divisor, index < units.count - 1 {
            magnitude /= divisor
            index += 1
        }

        // Adaptive precision: one decimal while there is room for it, none once
        // the integer part is three digits wide. Keeps the string at a constant
        // character count as the value grows, which is what makes the fixed
        // cell width above hold.
        let places = magnitude >= 100 ? 0 : decimals
        let sign = value < 0 ? "-" : ""
        let text = sign + String(format: "%.\(places)f", magnitude)

        guard showsUnit else { return Components(number: text, suffix: "") }
        return Components(number: text, suffix: " " + units[index] + rateSuffix)
    }
}
