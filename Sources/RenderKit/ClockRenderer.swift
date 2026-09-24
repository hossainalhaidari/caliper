import AppKit
import CoreGraphics
import Foundation
import SensorKit

/// How a clock cell turns a moment into text.
public struct ClockFormat: Equatable, Hashable, Sendable {
    /// Which format language the string is written in.
    public enum Syntax: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
        /// Unicode date field patterns, as `DateFormatter` uses: `HH:mm`,
        /// `EEE d MMM`. The native spelling on this platform, and the one that
        /// localises properly.
        case pattern
        /// C `strftime`: `%H:%M`, `%a %d %b`. Included because it is what people
        /// coming from a Linux status bar already have in their fingers, and
        /// retyping a working format in another dialect is a poor welcome.
        case strftime
    }

    public var format: String
    public var syntax: Syntax
    /// Identifier such as `Europe/Berlin`. `nil` follows the system.
    public var timeZone: String?
    /// Identifier such as `de_DE`. `nil` follows the system.
    public var locale: String?

    public init(
        format: String = "HH:mm",
        syntax: Syntax = .pattern,
        timeZone: String? = nil,
        locale: String? = nil
    ) {
        self.format = format
        self.syntax = syntax
        self.timeZone = timeZone
        self.locale = locale
    }

    /// Formats one moment. Public so the editor can show a live preview of what
    /// a format will actually produce, rather than making the user guess.
    public func string(at date: Date = Date()) -> String {
        ClockFormatting.shared.lines(at: date.timeIntervalSince1970, format: self)
            .joined(separator: "\n")
    }

    var resolvedTimeZone: TimeZone {
        timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    var resolvedLocale: Locale {
        locale.map(Locale.init(identifier:)) ?? .current
    }
}

/// Formats clock values, and works out how wide they can ever be.
///
/// Both are cached: building a `DateFormatter` is expensive, and the width probe
/// formats dozens of dates. Neither depends on the current time, so both are
/// computed once per distinct format.
final class ClockFormatting: @unchecked Sendable {
    static let shared = ClockFormatting()

    private let lock = NSLock()
    private var formatters: [ClockFormat: DateFormatter] = [:]
    private var widest: [ClockFormat: [[String]]] = [:]

    /// A format may contain a newline, which stacks it into two rows.
    func lines(at timestamp: Double, format: ClockFormat) -> [String] {
        let date = Date(timeIntervalSince1970: timestamp)
        return render(date, format: format).components(separatedBy: "\n")
    }

    private func render(_ date: Date, format: ClockFormat) -> String {
        switch format.syntax {
        case .pattern:
            return formatter(for: format).string(from: date)
        case .strftime:
            return Self.strftime(date, format: format)
        }
    }

    private func formatter(for format: ClockFormat) -> DateFormatter {
        lock.withLock {
            if let existing = formatters[format] { return existing }
            let formatter = DateFormatter()
            formatter.dateFormat = format.format
            formatter.timeZone = format.resolvedTimeZone
            formatter.locale = format.resolvedLocale
            formatters[format] = formatter
            return formatter
        }
    }

    /// Candidate longest lines, per row, for the renderer to measure.
    ///
    /// Two things here were wrong on the first attempt and are worth naming,
    /// because both produced a reservation that a real value overflowed.
    ///
    /// **Sampling a handful of days does not cover the combinations.** Probing
    /// the 3rd, 10th, 17th, 22nd and 28th of each month misses "Wednesday 25
    /// September" entirely -- September 2024 has no Wednesday on any of those
    /// dates -- and that is the widest thing `EEEE d MMMM` can print. Every day
    /// of a leap year is walked instead, which covers every weekday in every
    /// month by construction.
    ///
    /// **Character count is not width.** In a proportional face "III" and "WWW"
    /// are the same length and nothing like the same size. So this returns the
    /// longest few candidates and lets the renderer measure them in the font it
    /// is actually going to draw with.
    func widestCandidates(for format: ClockFormat) -> [[String]] {
        lock.lock()
        if let existing = widest[format] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        var byRow: [[String]] = []
        for probe in Self.probeDates(in: format.resolvedTimeZone) {
            let rows = render(probe, format: format).components(separatedBy: "\n")
            for (index, row) in rows.enumerated() {
                if index >= byRow.count { byRow.append([]) }
                byRow[index].append(row)
            }
        }

        // Keep the longest handful per row. More than that is measuring the same
        // width repeatedly; fewer risks missing the winner when two candidates
        // tie on length but not on ink.
        let result = byRow.map { candidates in
            Array(Set(candidates).sorted { $0.count > $1.count }.prefix(8))
        }
        let candidates = result.isEmpty ? [[""]] : result

        lock.withLock { widest[format] = candidates }
        return candidates
    }

    private static func probeDates(in timeZone: TimeZone) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var dates: [Date] = []
        // Every day of a leap year, at two times: a two-digit evening hour and a
        // single-digit morning one, so twelve-hour formats see both halves and
        // both padding cases. Roughly 730 formats, computed once per format and
        // cached.
        var components = DateComponents()
        components.year = 2024
        components.month = 1
        components.day = 1
        components.hour = 23
        components.minute = 58
        components.second = 59

        guard var cursor = calendar.date(from: components) else { return [] }
        for _ in 0..<366 {
            dates.append(cursor)
            dates.append(cursor.addingTimeInterval(-13 * 3600))  // 10:58 the same day
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return dates
    }

    private static func strftime(_ date: Date, format: ClockFormat) -> String {
        let zone = format.resolvedTimeZone
        let offset = zone.secondsFromGMT(for: date)

        // Shifted into UTC and read back with `gmtime_r`, so an explicit time
        // zone works without touching the process environment -- which is
        // global, and which no menu bar cell has any business changing.
        var shifted = time_t(date.timeIntervalSince1970) + time_t(offset)
        var parts = tm()
        gmtime_r(&shifted, &parts)

        // Darwin's strftime ignores `tm_gmtoff` and `tm_zone`: with the offset
        // set to Tokyo's +32400 it still printed the *process* zone for %z and
        // "UTC" for %Z. The only other lever is the TZ environment variable,
        // which is global process state and not something a menu bar cell should
        // be reaching for. So those two specifiers are resolved here and
        // substituted before the string ever reaches strftime.
        let resolved = Self.substituteZoneSpecifiers(in: format.format, zone: zone, date: date, offset: offset)

        var buffer = [CChar](repeating: 0, count: 512)
        let written = Darwin.strftime(&buffer, buffer.count, resolved, &parts)
        guard written > 0 else { return "" }
        return String(decoding: buffer.prefix(written).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Replaces `%z` and `%Z` with literal text for the requested zone.
    ///
    /// Walks the format rather than doing a blind replace, so `%%z` -- an escaped
    /// percent followed by a letter -- is left alone.
    static func substituteZoneSpecifiers(
        in format: String,
        zone: TimeZone,
        date: Date,
        offset: Int
    ) -> String {
        let isDaylight = zone.isDaylightSavingTime(for: date)
        let name = zone.localizedName(
            for: isDaylight ? .shortDaylightSaving : .shortStandard,
            locale: .current
        ) ?? zone.abbreviation(for: date) ?? "UTC"

        let sign = offset < 0 ? "-" : "+"
        let magnitude = abs(offset)
        let numeric = String(format: "%@%02d%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)

        var result = ""
        var iterator = format.makeIterator()
        var pending: Character?

        while let character = pending ?? iterator.next() {
            pending = nil
            guard character == "%" else {
                result.append(character)
                continue
            }

            guard let next = iterator.next() else {
                result.append(character)
                break
            }

            switch next {
            case "z": result += escapePercent(numeric)
            case "Z": result += escapePercent(name)
            case "%": result += "%%"
            default:
                result.append(character)
                result.append(next)
            }
        }
        return result
    }

    /// Substituted text is fed back through strftime, so a stray percent in a
    /// zone name would otherwise be read as a specifier.
    private static func escapePercent(_ text: String) -> String {
        text.replacingOccurrences(of: "%", with: "%%")
    }
}

/// The date and time, formatted however the user likes.
public struct ClockRenderer: CellRenderer {
    public static var typeIdentifier: String { "text.clock" }

    public var format: ClockFormat

    public init(format: ClockFormat = ClockFormat()) {
        self.format = format
    }

    /// A clock reads a moment, not a quantity, so no range constrains it.
    public static func accepts(_ range: MetricRange) -> Bool { true }

    private func font(_ context: RenderContext, rows: Int) -> NSFont {
        // Two rows in 22pt need the same treatment as the stacked rate cell.
        let scale: CGFloat = rows > 1 ? 0.72 : 1
        return NSFont.monospacedDigitSystemFont(
            ofSize: (context.font.pointSize * scale).rounded(),
            weight: .regular
        )
    }

    public func width(for input: CellInput, in context: RenderContext) -> CGFloat {
        let candidates = ClockFormatting.shared.widestCandidates(for: format)
        let font = font(context, rows: candidates.count)
        // Measured in the real font rather than counted in characters.
        let widest = candidates.flatMap { $0 }.map { TextDraw.measure($0, font: font) }.max() ?? 0
        return (widest + context.density.cellPadding * 2).rounded(.up)
    }

    public func changeKey(for input: CellInput, in context: RenderContext) -> String {
        // The rendered text, so a clock showing only hours and minutes is
        // rasterised once a minute rather than once a second.
        "clock|" + lines(for: input).joined(separator: "\u{1F}")
    }

    public func draw(
        _ input: CellInput,
        in cgContext: CGContext,
        rect: CGRect,
        context: RenderContext,
        severity: Severity
    ) {
        let rows = lines(for: input)
        guard !rows.isEmpty else { return }

        let colour = severity.color ?? context.nominalColor
        let font = font(context, rows: rows.count)
        let origin = rect.minX + context.density.cellPadding
        let available = rect.width - context.density.cellPadding * 2
        let rowHeight = rect.height / CGFloat(rows.count)

        for (index, text) in rows.enumerated() {
            // Top row first, and the view is y-up, so rows are laid out downward
            // from the top of the cell.
            let frame = CGRect(
                x: rect.minX,
                y: rect.maxY - rowHeight * CGFloat(index + 1),
                width: rect.width,
                height: rowHeight
            )
            // Centred within the reserved width, which keeps a stacked date and
            // time visually aligned with each other.
            let width = TextDraw.measure(text, font: font)
            TextDraw.draw(
                text,
                font: font,
                color: colour,
                at: origin + max(0, (available - width) / 2),
                in: frame,
                context: cgContext
            )
        }
    }

    /// The time exactly as the cell draws it, in its own format and zone. A
    /// two-row clock is read as one phrase.
    public func spokenValue(for input: CellInput) -> String? {
        guard let value = input.value, value.isFinite else { return nil }
        return lines(for: input).joined(separator: " ")
    }

    private func lines(for input: CellInput) -> [String] {
        guard let value = input.value, value.isFinite else {
            return [ValueFormatter.placeholder]
        }
        return ClockFormatting.shared.lines(at: value, format: format)
    }
}
