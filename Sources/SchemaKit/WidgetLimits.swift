import CoreGraphics
import Foundation
import LayoutEngine
import RenderKit
import SensorKit

/// How large a widget may be.
///
/// The editor is self-limiting -- nobody clicks Add three hundred times -- but
/// an import is one double-click on a file somebody else wrote, and sharing is
/// the feature built to accept exactly that. Before these limits a 53 KB file of
/// 300 cells and a 5,000-character name composed an 80,589-point status item: a
/// 103 MB bitmap for one menu bar item, in an app whose whole footprint budget is
/// 30 MB. A histogram whose bars were zero points wide did worse, and trapped.
///
/// So a shared file is measured before anything is drawn from it, and refused
/// with a reason when it is too big, rather than trimmed: a widget quietly cut
/// to fit is a different widget from the one that was sent, and nothing would
/// say so. The numeric ranges are also the editor's, so a widget built here can
/// always be sent, and one that arrives can always be edited.
///
/// Every limit is far past anything the editor produces by accident. They are
/// there to stop the absurd, not to tidy the merely large.
public enum WidgetLimits {

    /// The largest file an import reads. A layout of thirty-two full widgets is
    /// about 150 KB; anything past this is not a widget.
    public static let fileSize = 1_048_576

    /// Widgets in one shared layout.
    public static let widgetsPerFile = 32

    /// Cells in one widget. Two dozen is already wider than most menu bars.
    public static let cellsPerWidget = 24

    /// Lengths, in Unicode scalars rather than characters: a single "character"
    /// can be one letter under ten thousand combining marks, which is short to
    /// count and very long to draw.
    public static let nameLength = 64
    public static let captionLength = 16
    /// Room for a couple of emoji built from several scalars -- a family, a
    /// flag, a skin tone.
    public static let emojiLength = 16
    public static let symbolNameLength = 64
    public static let clockFormatLength = 64

    /// Further metrics in one cell: a core matrix on the largest Mac with room
    /// to spare.
    public static let seriesPerCell = 64
    public static let coreGroups = 8
    public static let coresPerGroup = 64

    /// The widest a widget may be, in points at the regular density.
    ///
    /// About the width of a 13-inch MacBook's whole menu bar, and six times the
    /// default widget. Measured before the recipient's hardware is known -- see
    /// `worstCaseWidth(of:)` -- so a file is accepted or refused the same way on
    /// every Mac.
    public static let width: CGFloat = 1200

    // MARK: - Option ranges, shared with the editor

    public static let decimals = 0...3
    public static let rateDecimals = 0...2
    public static let graphWidth: ClosedRange<Double> = 16...120
    /// Seconds of history a graph shows.
    public static let graphHistory = 10...600
    public static let histogramWidth: ClosedRange<Double> = 16...120
    public static let histogramBarWidth: ClosedRange<Double> = 1...12
    public static let histogramBarGap: ClosedRange<Double> = 0...6
    public static let barWidth: ClosedRange<Double> = 10...120
    public static let barThickness: ClosedRange<Double> = 1...22
    public static let spacerWidth: ClosedRange<Double> = 2...80
    public static let dividerThickness: ClosedRange<Double> = 0.5...4
    public static let dividerInset: ClosedRange<Double> = 0...10
    /// The gap between cells.
    public static let spacing: ClosedRange<Double> = 0...40
    /// A desktop widget's drawing height. The type is scaled from it, so it
    /// decides the size of everything else on the panel.
    public static let desktopHeight: ClosedRange<Double> = 16...200

    // MARK: - Checking

    /// The first limit a file breaks, said so that someone can act on it.
    public enum Violation: Error, Equatable, Sendable {
        case fileTooLarge(bytes: Int)
        case tooManyWidgets(Int)
        case tooManyCells(widget: String, count: Int)
        case nameTooLong(length: Int)
        case textTooLong(widget: String, cell: Int, field: String, length: Int, limit: Int)
        case outOfRange(widget: String, cell: Int?, field: String, value: Double, range: ClosedRange<Double>)
        case tooWide(widget: String, width: Int)

        public var message: String {
            switch self {
            case .fileTooLarge(let bytes):
                let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                let limit = ByteCountFormatter.string(fromByteCount: Int64(WidgetLimits.fileSize), countStyle: .file)
                return String(
                    localized: "This file is \(size). A widget file is never more than \(limit), so this is not one.",
                    comment: "Import error. The file's size, then the limit, such as 1 MB")
            case .tooManyWidgets(let count):
                return String(
                    localized: "This file holds \(count) widgets, and Caliper imports at most \(WidgetLimits.widgetsPerFile) at a time. Ask whoever sent it for a file with fewer.",
                    comment: "Import error. The number of widgets in the file, then the limit, currently 32")
            case .tooManyCells(let widget, let count):
                return String(
                    localized: "\u{201C}\(widget)\u{201D} has \(count) cells, and a widget can have at most \(WidgetLimits.cellsPerWidget). Ask whoever sent it to split it into smaller widgets.",
                    comment: "Import error. A widget's name, its number of cells, then the limit, currently 24")
            case .nameTooLong(let length):
                return String(
                    localized: "A widget in this file has a name \(length) characters long, and a name can be at most \(WidgetLimits.nameLength).",
                    comment: "Import error. The length of the name, then the limit, currently 64")
            case .textTooLong(let widget, let cell, let field, let length, let limit):
                return String(
                    localized: "Cell \(cell) of \u{201C}\(widget)\u{201D} has a \(field) \(length) characters long, and it can be at most \(limit).",
                    comment: "Import error. A cell's position counting from 1, a widget's name, a field name from the file kept as it is (label, emoji, symbol, format), its length, then the limit")
            case .outOfRange(let widget, let cell?, let field, let value, let range):
                return String(
                    localized: "Cell \(cell) of \u{201C}\(widget)\u{201D} sets \(field) to \(Self.number(value)), which must be between \(Self.number(range.lowerBound)) and \(Self.number(range.upperBound)).",
                    comment: "Import error. A cell's position counting from 1, a widget's name, a field name from the file kept as it is (width, capacity), its value, then the smallest and largest allowed")
            case .outOfRange(let widget, nil, let field, let value, let range):
                return String(
                    localized: "\u{201C}\(widget)\u{201D} sets \(field) to \(Self.number(value)), which must be between \(Self.number(range.lowerBound)) and \(Self.number(range.upperBound)).",
                    comment: "Import error. A widget's name, a field name from the file kept as it is (spacing, height), its value, then the smallest and largest allowed")
            case .tooWide(let widget, let width):
                return String(
                    localized: "\u{201C}\(widget)\u{201D} would be \(width) points wide, and a widget can be at most \(Int(WidgetLimits.width)) -- about the width of a laptop's whole menu bar. Ask whoever sent it to split it into smaller widgets.",
                    comment: "Import error. A widget's name, its width, then the limit, currently 1200")
            }
        }

        private static func number(_ value: Double) -> String {
            value.formatted(.number.precision(.fractionLength(0...2)))
        }
    }

    /// Checks everything a shared file carries, stopping at the first problem.
    public static func check(_ widgets: [WidgetDocument]) throws(Violation) {
        guard widgets.count <= widgetsPerFile else { throw .tooManyWidgets(widgets.count) }
        for widget in widgets { try check(widget) }
    }

    /// Checks one widget. The cheap structural limits come first, so a file of
    /// three hundred cells is refused before anything is measured.
    public static func check(_ widget: WidgetDocument) throws(Violation) {
        let nameLength = widget.name.unicodeScalars.count
        guard nameLength <= self.nameLength else { throw .nameTooLong(length: nameLength) }
        // Named in every later message, so a name that has passed is short enough
        // to quote.
        let name = widget.name

        guard widget.cells.count <= cellsPerWidget else {
            throw .tooManyCells(widget: name, count: widget.cells.count)
        }
        if let spacing = widget.spacing {
            try require(spacing, in: self.spacing, widget: name, cell: nil, field: "spacing")
        }
        if let desktop = widget.desktop {
            try require(desktop.height, in: desktopHeight, widget: name, cell: nil, field: "height")
        }

        for (index, cell) in widget.cells.enumerated() {
            try check(cell, number: index + 1, widget: name)
        }

        let measured = worstCaseWidth(of: widget)
        guard measured <= width else { throw .tooWide(widget: name, width: Int(measured.rounded(.up))) }
    }

    private static func check(_ cell: CellDocument, number: Int, widget: String) throws(Violation) {
        func text(_ value: String?, _ field: String, _ limit: Int) throws(Violation) {
            guard let length = value?.unicodeScalars.count, length > limit else { return }
            throw .textTooLong(widget: widget, cell: number, field: field, length: length, limit: limit)
        }
        func range(_ value: Double, _ allowed: ClosedRange<Double>, _ field: String) throws(Violation) {
            try require(value, in: allowed, widget: widget, cell: number, field: field)
        }
        func range(_ value: Int, _ allowed: ClosedRange<Int>, _ field: String) throws(Violation) {
            try range(Double(value), Double(allowed.lowerBound)...Double(allowed.upperBound), field)
        }

        try text(cell.label, "label", captionLength)
        switch cell.icon {
        case .symbol(let name): try text(name, "symbol", symbolNameLength)
        case .emoji(let emoji): try text(emoji, "emoji", emojiLength)
        case nil: break
        }
        try range(cell.series.count, 0...seriesPerCell, "series")

        switch cell.style {
        case .text(let options):
            try range(options.decimals, decimals, "decimals")
        case .dualRate(let options):
            try range(options.decimals, rateDecimals, "decimals")
        case .history(let options):
            try range(options.width, graphWidth, "width")
            try range(options.capacity, graphHistory, "capacity")
        case .histogram(let options):
            try range(options.width, histogramWidth, "width")
            try range(options.barWidth, histogramBarWidth, "barWidth")
            try range(options.barGap, histogramBarGap, "barGap")
        case .bar(let options):
            try range(options.width, barWidth, "width")
            try range(options.thickness, barThickness, "thickness")
        case .coreMatrix(let options):
            try range(options.groups.count, 0...coreGroups, "groups")
            for group in options.groups {
                try range(group, 0...coresPerGroup, "groups")
            }
        case .clock(let options):
            try text(options.format, "format", clockFormatLength)
        case .spacer(let options):
            try range(options.width, spacerWidth, "width")
        case .divider(let options):
            try range(options.thickness, dividerThickness, "thickness")
            try range(options.inset, dividerInset, "inset")
        case .donut, .arc, .unsupported:
            break
        }
    }

    private static func require(
        _ value: Double,
        in allowed: ClosedRange<Double>,
        widget: String,
        cell: Int?,
        field: String
    ) throws(Violation) {
        // `contains` is false for NaN, which JSON cannot carry but a document
        // built in code can.
        guard !allowed.contains(value) else { return }
        throw .outOfRange(widget: widget, cell: cell, field: field, value: value, range: allowed)
    }

    // MARK: - Width

    /// How wide the widget could be on any Mac, at the regular density.
    ///
    /// A cell's width depends on its metric's unit -- a byte rate reserves room
    /// for `888 MB/s`, a percentage for `100%` -- and which metrics a file names
    /// says nothing about their units until the recipient's Mac has resolved
    /// them. So every cell is measured as its widest possible self. That makes
    /// the check pessimistic by a few points a cell, and the same on every
    /// machine: whether a file is accepted cannot depend on who opens it.
    public static func worstCaseWidth(of widget: WidgetDocument) -> CGFloat {
        let context = RenderContext(density: .regular, scale: 1)
        let ranges: [MetricRange] = [.percentage, .unbounded(min: 0)]

        let widths = widget.cells.map { cell -> CGFloat in
            guard let renderer = cell.style.makeRenderer(thresholds: .none) else { return 0 }
            let adornment = AdornmentPainter.advance(cell.adornment, in: context)
            let series = [Double?](repeating: nil, count: cell.series.count)
            var widest: CGFloat = 0
            for unit in MetricUnit.allCases {
                for range in ranges {
                    let input = CellInput(value: nil, unit: unit, range: range, series: series)
                    widest = max(widest, renderer.width(for: input, in: context))
                }
            }
            return adornment + widest
        }

        let spacing = widget.spacing.map { CGFloat($0) } ?? context.density.cellSpacing
        return widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
    }

    // MARK: - Editing

    /// `text` cut to at most `limit` Unicode scalars, at a character boundary.
    ///
    /// For the editor's text fields, which apply the same limits as an import:
    /// typing past the end of a caption does nothing, rather than producing a
    /// widget that could not be sent to anyone.
    public static func truncated(_ text: String, to limit: Int) -> String {
        guard text.unicodeScalars.count > limit else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = character.unicodeScalars.count
            guard used + size <= limit else { break }
            result.append(character)
            used += size
        }
        return result
    }
}
