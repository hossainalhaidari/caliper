import Foundation
import RenderKit
import SensorKit

/// How a cell draws, as it appears in a document.
///
/// Encoded flat, with a `type` discriminator that is the renderer's own
/// `typeIdentifier`:
///
/// ```json
/// { "type": "graph.history", "mode": "area", "width": 34, "capacity": 60 }
/// ```
///
/// Flat rather than nested (`{"type": "...", "options": {...}}`) because these
/// documents are meant to be read and hand-edited by people, and one level of
/// nesting per cell adds up fast in a widget with eight of them.
///
/// The `type` strings are API. They are also the renderer identifiers, which
/// keeps one name for one concept instead of a lookup table that can drift.
public enum CellStyle: Equatable, Sendable {
    case text(TextOptions = .init())
    case history(HistoryOptions = .init())
    case histogram(HistogramOptions = .init())
    case donut
    case arc
    case bar(BarOptions = .init())
    case coreMatrix(CoreMatrixOptions = .init())
    case dualRate(DualRateOptions = .init())

    /// The date and time, formatted however the user likes.
    case clock(ClockOptions = .init())

    /// Blank space of a fixed width.
    case spacer(SpacerOptions = .init())
    /// A hairline rule.
    case divider(DividerOptions = .init())

    /// A style this version does not know, carried verbatim so that opening and
    /// saving a newer document does not destroy it.
    case unsupported(type: String, payload: JSONValue)

    // MARK: - Options

    public struct TextOptions: Codable, Equatable, Sendable {
        public var decimals: Int
        public var showsUnit: Bool

        public init(decimals: Int = 0, showsUnit: Bool = true) {
            self.decimals = decimals
            self.showsUnit = showsUnit
        }
    }

    public struct HistoryOptions: Codable, Equatable, Sendable {
        public enum Mode: String, Codable, Sendable, CaseIterable {
            case line
            case area
        }

        public var mode: Mode
        public var width: Double
        /// Samples the plot is sized for; also what the cell asks the bus to keep.
        public var capacity: Int

        public init(mode: Mode = .area, width: Double = 34, capacity: Int = 60) {
            self.mode = mode
            self.width = width
            self.capacity = capacity
        }
    }

    public struct HistogramOptions: Codable, Equatable, Sendable {
        public var width: Double
        public var barWidth: Double
        public var barGap: Double

        public init(width: Double = 34, barWidth: Double = 2, barGap: Double = 0.5) {
            self.width = width
            self.barWidth = barWidth
            self.barGap = barGap
        }
    }

    public struct BarOptions: Codable, Equatable, Sendable {
        public var width: Double
        public var thickness: Double

        public init(width: Double = 24, thickness: Double = 6) {
            self.width = width
            self.thickness = thickness
        }
    }

    public struct CoreMatrixOptions: Codable, Equatable, Sendable {
        /// Cores per cluster. Empty means "ask this machine", which is what
        /// makes a shared core-matrix widget work on hardware with a different
        /// layout instead of drawing the author's core count.
        public var groups: [Int]

        public init(groups: [Int] = []) {
            self.groups = groups
        }
    }

    public struct ClockOptions: Codable, Equatable, Sendable {
        /// A `DateFormatter` pattern, or a `strftime` string -- see `syntax`.
        /// A newline stacks the clock into two rows.
        public var format: String
        public var syntax: ClockFormat.Syntax
        /// Identifier such as `Europe/Berlin`. Absent follows the system, which
        /// is what almost everyone wants; setting it is how you get a second
        /// clock for somewhere else.
        public var timeZone: String?
        public var locale: String?

        public init(
            format: String = "HH:mm",
            syntax: ClockFormat.Syntax = .pattern,
            timeZone: String? = nil,
            locale: String? = nil
        ) {
            self.format = format
            self.syntax = syntax
            self.timeZone = timeZone
            self.locale = locale
        }

        var clockFormat: ClockFormat {
            ClockFormat(format: format, syntax: syntax, timeZone: timeZone, locale: locale)
        }
    }

    public struct SpacerOptions: Codable, Equatable, Sendable {
        public var width: Double

        public init(width: Double = 8) {
            self.width = width
        }
    }

    public struct DividerOptions: Codable, Equatable, Sendable {
        public var thickness: Double
        public var inset: Double

        public init(thickness: Double = 1, inset: Double = 5) {
            self.thickness = thickness
            self.inset = inset
        }
    }

    public struct DualRateOptions: Codable, Equatable, Sendable {
        public var decimals: Int

        public init(decimals: Int = 0) {
            self.decimals = decimals
        }
    }
}

// MARK: - Tolerant option decoding

/// Every option field falls back to the default in its initialiser.
///
/// A style written by hand should be able to say only what it means:
/// `{ "type": "gauge.donut" }` is a complete, valid cell style, and
/// `{ "type": "graph.history", "mode": "line" }` differs from the default in
/// exactly the way it looks like it does. Requiring the full set turns a format
/// advertised as hand-editable into one you can only produce by exporting.
public extension CellStyle.TextOptions {
    private enum Keys: String, CodingKey { case decimals, showsUnit }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let fallback = CellStyle.TextOptions()
        self.init(
            decimals: try container.decodeIfPresent(Int.self, forKey: .decimals) ?? fallback.decimals,
            showsUnit: try container.decodeIfPresent(Bool.self, forKey: .showsUnit) ?? fallback.showsUnit
        )
    }
}

public extension CellStyle.HistoryOptions {
    private enum Keys: String, CodingKey { case mode, width, capacity }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let fallback = CellStyle.HistoryOptions()
        self.init(
            mode: try container.decodeIfPresent(Mode.self, forKey: .mode) ?? fallback.mode,
            width: try container.decodeIfPresent(Double.self, forKey: .width) ?? fallback.width,
            capacity: try container.decodeIfPresent(Int.self, forKey: .capacity) ?? fallback.capacity
        )
    }
}

public extension CellStyle.HistogramOptions {
    private enum Keys: String, CodingKey { case width, barWidth, barGap }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let fallback = CellStyle.HistogramOptions()
        self.init(
            width: try container.decodeIfPresent(Double.self, forKey: .width) ?? fallback.width,
            barWidth: try container.decodeIfPresent(Double.self, forKey: .barWidth) ?? fallback.barWidth,
            barGap: try container.decodeIfPresent(Double.self, forKey: .barGap) ?? fallback.barGap
        )
    }
}

public extension CellStyle.BarOptions {
    private enum Keys: String, CodingKey { case width, thickness }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let fallback = CellStyle.BarOptions()
        self.init(
            width: try container.decodeIfPresent(Double.self, forKey: .width) ?? fallback.width,
            thickness: try container.decodeIfPresent(Double.self, forKey: .thickness) ?? fallback.thickness
        )
    }
}

public extension CellStyle.CoreMatrixOptions {
    private enum Keys: String, CodingKey { case groups }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        self.init(groups: try container.decodeIfPresent([Int].self, forKey: .groups) ?? [])
    }
}

public extension CellStyle.ClockOptions {
    private enum Keys: String, CodingKey { case format, syntax, timeZone, locale }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let fallback = CellStyle.ClockOptions()
        self.init(
            format: try container.decodeIfPresent(String.self, forKey: .format) ?? fallback.format,
            syntax: try container.decodeIfPresent(ClockFormat.Syntax.self, forKey: .syntax) ?? fallback.syntax,
            timeZone: try container.decodeIfPresent(String.self, forKey: .timeZone),
            locale: try container.decodeIfPresent(String.self, forKey: .locale)
        )
    }
}

public extension CellStyle.SpacerOptions {
    private enum Keys: String, CodingKey { case width }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let fallback = CellStyle.SpacerOptions()
        self.init(width: try container.decodeIfPresent(Double.self, forKey: .width) ?? fallback.width)
    }
}

public extension CellStyle.DividerOptions {
    private enum Keys: String, CodingKey { case thickness, inset }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let fallback = CellStyle.DividerOptions()
        self.init(
            thickness: try container.decodeIfPresent(Double.self, forKey: .thickness) ?? fallback.thickness,
            inset: try container.decodeIfPresent(Double.self, forKey: .inset) ?? fallback.inset
        )
    }
}

public extension CellStyle.DualRateOptions {
    private enum Keys: String, CodingKey { case decimals }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let fallback = CellStyle.DualRateOptions()
        self.init(decimals: try container.decodeIfPresent(Int.self, forKey: .decimals) ?? fallback.decimals)
    }
}

// MARK: - Identity

public extension CellStyle {
    var typeIdentifier: String {
        switch self {
        case .text: TextValueRenderer.typeIdentifier
        case .history: HistoryGraphRenderer.typeIdentifier
        case .histogram: HistogramRenderer.typeIdentifier
        case .donut: DonutRenderer.typeIdentifier
        case .arc: ArcGaugeRenderer.typeIdentifier
        case .bar: BarRenderer.typeIdentifier
        case .coreMatrix: CoreMatrixRenderer.typeIdentifier
        case .dualRate: DualRateRenderer.typeIdentifier
        case .clock: ClockRenderer.typeIdentifier
        case .spacer: SpacerRenderer.typeIdentifier
        case .divider: DividerRenderer.typeIdentifier
        case .unsupported(let type, _): type
        }
    }

    /// Shown in the editor's style picker.
    var displayName: String {
        switch self {
        case .text: String(localized: "Number", comment: "A cell style, in the editor's Style picker")
        case .history(let options):
            options.mode == .line
                ? String(localized: "Line Graph", comment: "A cell style, in the editor's Style picker")
                : String(localized: "Area Graph", comment: "A cell style, in the editor's Style picker")
        case .histogram: String(localized: "Histogram", comment: "A cell style, in the editor's Style picker")
        case .donut: String(localized: "Donut", comment: "A cell style, in the editor's Style picker")
        case .arc: String(localized: "Dial", comment: "A cell style, in the editor's Style picker")
        case .bar: String(localized: "Bar", comment: "A cell style, in the editor's Style picker")
        case .coreMatrix: String(localized: "Core Matrix", comment: "A cell style, in the editor's Style picker")
        case .dualRate: String(localized: "Stacked Rates", comment: "A cell style, in the editor's Style picker")
        case .clock: String(localized: "Clock", comment: "A cell style, in the editor's Style picker")
        case .spacer: String(localized: "Spacer", comment: "A cell style, in the editor's Style picker")
        case .divider: String(localized: "Divider", comment: "A cell style, in the editor's Style picker")
        case .unsupported(let type, _):
            String(
                localized: "Unsupported (\(type))",
                comment: "A cell style from a newer Caliper. The argument is its identifier")
        }
    }

    /// Samples this style needs retained. Derived rather than stored, so a
    /// document cannot describe a graph that is wider than its own history.
    var historyDepth: Int {
        switch self {
        case .history(let options): options.capacity
        case .histogram(let options):
            HistogramRenderer(width: options.width, barWidth: options.barWidth, barGap: options.barGap).barCount
        default: 0
        }
    }

    /// Styles that draw layout rather than data, and so need no metric at all.
    var isDecorative: Bool {
        switch self {
        case .spacer, .divider: true
        default: false
        }
    }

    /// Whether this style can honestly draw a metric with this range.
    func accepts(_ range: MetricRange) -> Bool {
        switch self {
        case .donut: DonutRenderer.accepts(range)
        case .arc: ArcGaugeRenderer.accepts(range)
        case .bar: BarRenderer.accepts(range)
        case .coreMatrix: CoreMatrixRenderer.accepts(range)
        case .text, .history, .histogram, .dualRate, .clock, .spacer, .divider: true
        case .unsupported: false
        }
    }

    /// True for styles that draw more than one metric in a single frame.
    var isMultiValued: Bool {
        switch self {
        case .coreMatrix, .dualRate: true
        default: false
        }
    }

    /// Every style the editor can offer, with sensible starting options.
    static var catalogue: [CellStyle] {
        [
            .text(),
            .history(HistoryOptions(mode: .area)),
            .history(HistoryOptions(mode: .line)),
            .histogram(),
            .donut,
            .arc,
            .bar(),
            .coreMatrix(),
            .dualRate(),
            .clock(),
            .spacer(),
            .divider(),
        ]
    }

    /// Builds the drawing object. `thresholds` lives on the cell rather than the
    /// style because it is a statement about the *metric* -- 70% is hot whether
    /// you draw it as a number or a ring.
    func makeRenderer(thresholds: Thresholds) -> (any CellRenderer)? {
        switch self {
        case .text(let options):
            TextValueRenderer(
                formatter: ValueFormatter(decimals: options.decimals, showsUnit: options.showsUnit),
                thresholds: thresholds
            )

        case .history(let options):
            HistoryGraphRenderer(
                style: options.mode == .line ? .line : .area,
                width: options.width,
                capacity: options.capacity,
                thresholds: thresholds
            )

        case .histogram(let options):
            HistogramRenderer(
                width: options.width,
                barWidth: options.barWidth,
                barGap: options.barGap,
                thresholds: thresholds
            )

        case .donut:
            DonutRenderer(thresholds: thresholds)

        case .arc:
            ArcGaugeRenderer(thresholds: thresholds)

        case .bar(let options):
            BarRenderer(thresholds: thresholds, width: options.width, thickness: options.thickness)

        case .coreMatrix(let options):
            CoreMatrixRenderer(groups: options.groups, thresholds: thresholds)

        case .dualRate(let options):
            DualRateRenderer(
                formatter: ValueFormatter(decimals: options.decimals),
                thresholds: thresholds
            )

        case .clock(let options):
            ClockRenderer(format: options.clockFormat)

        case .spacer(let options):
            SpacerRenderer(width: options.width)

        case .divider(let options):
            DividerRenderer(thickness: options.thickness, inset: options.inset)

        case .unsupported:
            // Nothing sensible to draw. The caller renders a placeholder, and
            // the document keeps the definition intact for a version that does
            // understand it.
            nil
        }
    }
}

// MARK: - Coding

extension CellStyle: Codable {
    private enum TypeKey: String, CodingKey {
        case type
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: TypeKey.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case TextValueRenderer.typeIdentifier:
            self = .text(try TextOptions(from: decoder))
        case HistoryGraphRenderer.typeIdentifier:
            self = .history(try HistoryOptions(from: decoder))
        case HistogramRenderer.typeIdentifier:
            self = .histogram(try HistogramOptions(from: decoder))
        case DonutRenderer.typeIdentifier:
            self = .donut
        case ArcGaugeRenderer.typeIdentifier:
            self = .arc
        case BarRenderer.typeIdentifier:
            self = .bar(try BarOptions(from: decoder))
        case CoreMatrixRenderer.typeIdentifier:
            self = .coreMatrix(try CoreMatrixOptions(from: decoder))
        case DualRateRenderer.typeIdentifier:
            self = .dualRate(try DualRateOptions(from: decoder))
        case ClockRenderer.typeIdentifier:
            self = .clock(try ClockOptions(from: decoder))
        case SpacerRenderer.typeIdentifier:
            self = .spacer(try SpacerOptions(from: decoder))
        case DividerRenderer.typeIdentifier:
            self = .divider(try DividerOptions(from: decoder))
        default:
            self = .unsupported(type: type, payload: try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        // The unsupported payload already carries its own `type`, so writing it
        // straight back out reproduces the original object byte for byte.
        if case .unsupported(_, let payload) = self {
            try payload.encode(to: encoder)
            return
        }

        switch self {
        case .text(let options): try options.encode(to: encoder)
        case .history(let options): try options.encode(to: encoder)
        case .histogram(let options): try options.encode(to: encoder)
        case .bar(let options): try options.encode(to: encoder)
        case .coreMatrix(let options): try options.encode(to: encoder)
        case .dualRate(let options): try options.encode(to: encoder)
        case .clock(let options): try options.encode(to: encoder)
        case .spacer(let options): try options.encode(to: encoder)
        case .divider(let options): try options.encode(to: encoder)
        case .donut, .arc, .unsupported: break
        }

        var container = encoder.container(keyedBy: TypeKey.self)
        try container.encode(typeIdentifier, forKey: .type)
    }
}
