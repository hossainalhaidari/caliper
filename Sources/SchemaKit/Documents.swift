import Foundation
import RenderKit
import SensorKit

/// An icon shown in place of a text label.
///
/// Two kinds, because they behave differently rather than to offer choice for
/// its own sake. An **SF Symbol** is monochrome, so it tints with the menu bar
/// exactly as text does and the strip stays a template image. An **emoji** is a
/// colour glyph, which is the point of using one -- but it forces the whole strip
/// to carry explicit colours, since a template would flatten it to a silhouette.
///
/// Encoded as a single-key object, so the kind is obvious when reading the file:
/// `{"symbol": "cpu"}` or `{"emoji": "\u{1F525}"}`.
public enum CellIcon: Equatable, Sendable {
    case symbol(String)
    case emoji(String)

    public var value: String {
        switch self {
        case .symbol(let name), .emoji(let name): name
        }
    }
}

extension CellIcon: Codable {
    private enum CodingKeys: String, CodingKey {
        case symbol, emoji
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let name = try container.decodeIfPresent(String.self, forKey: .symbol) {
            self = .symbol(name)
        } else if let emoji = try container.decodeIfPresent(String.self, forKey: .emoji) {
            self = .emoji(emoji)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "an icon needs either a \"symbol\" or an \"emoji\""
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .symbol(let name): try container.encode(name, forKey: .symbol)
        case .emoji(let emoji): try container.encode(emoji, forKey: .emoji)
        }
    }
}

/// One cell, as written down.
///
/// The style is nested under `style` rather than flattened into the cell.
/// Flattening reads better by hand, but it makes forward compatibility
/// impossible: an unknown style has to be preserved verbatim, and if its keys
/// share an object with the cell's own there is no way to write it back without
/// either duplicating or dropping fields. One level of nesting buys the
/// guarantee that a document from a future version survives a round trip.
public struct CellDocument: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// `nil` for decorative cells -- spacers and dividers -- which show nothing.
    public var metric: MetricID?
    public var style: CellStyle
    public var label: String?
    /// Shown instead of `label` when set.
    public var icon: CellIcon?
    /// Metric whose value decides severity, when that differs from `metric`.
    public var alertMetric: MetricID?
    /// Further metrics for multi-valued styles, in draw order.
    public var series: [MetricID]
    public var thresholds: Thresholds?

    public init(
        id: UUID = UUID(),
        metric: MetricID? = nil,
        style: CellStyle,
        label: String? = nil,
        icon: CellIcon? = nil,
        alertMetric: MetricID? = nil,
        series: [MetricID] = [],
        thresholds: Thresholds? = nil
    ) {
        self.id = id
        self.metric = metric
        self.style = style
        self.label = label
        self.icon = icon
        self.alertMetric = alertMetric
        self.series = series
        self.thresholds = thresholds
    }

    /// What the compositor should draw before the value.
    ///
    /// An icon wins over a label when both are set, rather than showing both:
    /// they occupy the same slot and are alternatives, which is how the editor
    /// presents them.
    public var adornment: CellAdornment {
        if let icon {
            switch icon {
            case .symbol(let name): return .symbol(name)
            case .emoji(let emoji): return .emoji(emoji)
            }
        }
        if let label, !label.isEmpty { return .text(label) }
        return .none
    }

    /// Every metric this cell reads.
    public var metrics: [MetricID] {
        (metric.map { [$0] } ?? []) + series + (alertMetric.map { [$0] } ?? [])
    }
}

extension CellDocument {
    private enum CodingKeys: String, CodingKey {
        case id, metric, style, label, icon, alertMetric, series, thresholds
    }

    /// Written by hand rather than synthesised, to leave out what is empty.
    ///
    /// The synthesised version emits `"series": []` for every single-metric
    /// cell, which pretty-printing renders as a three-line blank block. In a
    /// format whose entire purpose is being read, diffed and pasted into a
    /// message, that is most of the file spent on nothing.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(metric, forKey: .metric)
        try container.encode(style, forKey: .style)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(alertMetric, forKey: .alertMetric)
        if !series.isEmpty { try container.encode(series, forKey: .series) }
        try container.encodeIfPresent(thresholds, forKey: .thresholds)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.metric = try container.decodeIfPresent(MetricID.self, forKey: .metric)
        self.style = try container.decode(CellStyle.self, forKey: .style)
        self.label = try container.decodeIfPresent(String.self, forKey: .label)
        self.icon = try container.decodeIfPresent(CellIcon.self, forKey: .icon)
        self.alertMetric = try container.decodeIfPresent(MetricID.self, forKey: .alertMetric)
        // Absent means none. A hand-written widget should not need to spell out
        // every empty field to be valid.
        self.series = try container.decodeIfPresent([MetricID].self, forKey: .series) ?? []
        self.thresholds = try container.decodeIfPresent(Thresholds.self, forKey: .thresholds)
    }
}

/// Where a widget sits on the desktop, if it does.
///
/// Optional on the document: most widgets live only in the menu bar, and a
/// shared file should not drag the author's screen coordinates onto someone
/// else's display -- which may not even have a pixel at that point.
public struct DesktopPlacement: Codable, Equatable, Sendable {
    public enum Level: String, Codable, Sendable, CaseIterable {
        /// Above ordinary windows.
        case floating
        /// Behind them, sitting on the desktop.
        case desktop

        /// Raw window level for this placement.
        ///
        /// `desktop` is deliberately **not** `kCGDesktopIconWindowLevel`, which
        /// is the obvious choice and produces a widget nobody can ever see. On
        /// this era of macOS, WindowManager and Finder both composite
        /// full-screen windows at exactly that level, so a third-party window
        /// placed there is buried behind them permanently -- and ordering
        /// forward does not help, because those surfaces belong to the window
        /// server rather than to any app.
        ///
        /// One below normal puts it above every desktop surface and below every
        /// ordinary window, which is what the setting says it does.
        public var windowLevel: Int {
            switch self {
            case .floating: 3   // kCGFloatingWindowLevel
            case .desktop: -1   // kCGNormalWindowLevel - 1
            }
        }
    }

    public var x: Double
    public var y: Double
    public var level: Level
    /// Drawing height in points. The menu bar is fixed at 22; a desktop widget
    /// can be legible from across a room.
    public var height: Double

    /// The window level this placement asks for, as a raw value.
    ///
    /// Kept with the model rather than in the window code so the one part that
    /// is easy to get catastrophically wrong can be tested. See
    /// `Level.windowLevel` for why "desktop" is not the desktop level.
    public var windowLevel: Int { level.windowLevel }

    public init(x: Double = 80, y: Double = 80, level: Level = .desktop, height: Double = 44) {
        self.x = x
        self.y = y
        self.level = level
        self.height = height
    }
}

/// One menu bar item's worth of cells. This is the unit that gets shared.
public struct WidgetDocument: Codable, Equatable, Sendable, Identifiable {
    public static let schemaVersion = "caliper.widget/1"

    public var schema: String
    public var id: UUID
    public var name: String
    public var cells: [CellDocument]
    /// Whether this widget is currently shown.
    ///
    /// Shown *where* is `desktop`'s business, not this flag's: hiding a desktop
    /// widget has to keep its placement, or showing it again would put it back
    /// in the default corner instead of where it was left.
    public var isEnabled: Bool
    /// Gap between cells, overriding the density default.
    public var spacing: Double?
    /// Set when the widget is drawn on the desktop instead of the menu bar.
    ///
    /// The two are alternatives rather than additions. A widget wanted in both
    /// places is two widgets -- which the editor's Duplicate makes cheap -- and
    /// that keeps "show this" a single unambiguous switch.
    public var desktop: DesktopPlacement?
    public var author: String?
    public var created: Date?

    public init(
        schema: String = WidgetDocument.schemaVersion,
        id: UUID = UUID(),
        name: String,
        cells: [CellDocument],
        isEnabled: Bool = true,
        spacing: Double? = nil,
        desktop: DesktopPlacement? = nil,
        author: String? = nil,
        created: Date? = nil
    ) {
        self.schema = schema
        self.id = id
        self.name = name
        self.cells = cells
        self.isEnabled = isEnabled
        self.spacing = spacing
        self.desktop = desktop
        self.author = author
        self.created = created
    }
}

extension WidgetDocument {
    private enum CodingKeys: String, CodingKey {
        case schema, id, name, cells, isEnabled, spacing, desktop, author, created
    }

    /// Tolerant of everything that can be inferred.
    ///
    /// The format is meant to be hand-written, and requiring somebody to invent
    /// a UUID before their widget will load is a pointless obstacle. Identity,
    /// schema version and enabled-state all have obvious defaults, so a widget
    /// can legitimately be four lines of JSON:
    ///
    /// ```json
    /// { "name": "CPU", "cells": [ { "metric": "cpu.usage.total",
    ///                               "style": { "type": "text.value" } } ] }
    /// ```
    ///
    /// Being strict here would also produce the wrong *error*: a missing widget
    /// id masks whatever is actually wrong further down, so the user is told
    /// about the one field they could not have known to write.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schema = try container.decodeIfPresent(String.self, forKey: .schema)
            ?? WidgetDocument.schemaVersion
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        self.cells = try container.decodeIfPresent([CellDocument].self, forKey: .cells) ?? []
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.spacing = try container.decodeIfPresent(Double.self, forKey: .spacing)
        self.desktop = try container.decodeIfPresent(DesktopPlacement.self, forKey: .desktop)
        self.author = try container.decodeIfPresent(String.self, forKey: .author)
        self.created = try container.decodeIfPresent(Date.self, forKey: .created)
    }
}

extension LayoutDocument {
    private enum CodingKeys: String, CodingKey {
        case schema, widgets, density, alertsEnabled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schema = try container.decodeIfPresent(String.self, forKey: .schema)
            ?? LayoutDocument.schemaVersion
        self.widgets = try container.decodeIfPresent([WidgetDocument].self, forKey: .widgets) ?? []
        self.density = try container.decodeIfPresent(Density.self, forKey: .density) ?? .regular
        self.alertsEnabled = try container.decodeIfPresent(Bool.self, forKey: .alertsEnabled) ?? true
    }
}

/// Everything the app persists: the whole set of widgets plus display settings.
///
/// Separate from `WidgetDocument` because they are shared differently. A widget
/// is a thing you send someone; a layout is your particular arrangement of them,
/// which nobody else wants.
public struct LayoutDocument: Codable, Equatable, Sendable {
    public static let schemaVersion = "caliper.layout/1"

    public var schema: String
    public var widgets: [WidgetDocument]
    public var density: Density
    /// Whether threshold crossings produce notifications. Colour in the strip is
    /// unaffected and always on -- that is the glanceable signal, and it costs
    /// nothing to leave enabled.
    public var alertsEnabled: Bool

    public init(
        schema: String = LayoutDocument.schemaVersion,
        widgets: [WidgetDocument],
        density: Density = .regular,
        alertsEnabled: Bool = true
    ) {
        self.schema = schema
        self.widgets = widgets
        self.density = density
        self.alertsEnabled = alertsEnabled
    }
}

// MARK: - Serialisation

public extension WidgetDocument {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Sorted keys and real indentation: these files are meant to be read,
        // diffed, and pasted into a message by people.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func encoded() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    init(json: Data) throws {
        self = try Self.makeDecoder().decode(WidgetDocument.self, from: json)
    }
}

public extension LayoutDocument {
    func encoded() throws -> Data {
        try WidgetDocument.makeEncoder().encode(self)
    }

    init(json: Data) throws {
        self = try WidgetDocument.makeDecoder().decode(LayoutDocument.self, from: json)
    }
}
