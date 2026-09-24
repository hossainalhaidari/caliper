import CoreGraphics
import RenderKit
import SensorKit

/// One cell: a metric, a visual style, and the styling that binds them.
///
/// The renderer is held as an existential rather than a generic parameter
/// because a widget is a *heterogeneous* strip -- a number next to a graph next
/// to a gauge -- and because documents build these at runtime, where the
/// concrete type is not known until the file is read.
public struct Cell {
    /// `nil` for decorative cells -- spacers and dividers -- which show nothing
    /// and must not cause a source to be activated.
    public var metric: MetricID?
    public var renderer: any CellRenderer
    /// How many samples of history the renderer wants. Graph styles need this;
    /// text needs none.
    public var historyDepth: Int
    /// Caption, SF Symbol, or emoji shown before the value.
    ///
    /// Drawn by `StripComposer`, not by the renderer, so every style shows it.
    public var adornment: CellAdornment

    /// Metric whose value decides this cell's severity, when that differs from
    /// the metric being displayed. See `CellInput.alertValue`.
    public var alertMetric: MetricID?

    /// Further metrics for multi-valued styles, in draw order.
    public var series: [MetricID]

    public init(
        metric: MetricID? = nil,
        renderer: any CellRenderer,
        historyDepth: Int = 0,
        adornment: CellAdornment = .none,
        alertMetric: MetricID? = nil,
        series: [MetricID] = []
    ) {
        self.metric = metric
        self.renderer = renderer
        self.historyDepth = historyDepth
        self.adornment = adornment
        self.alertMetric = alertMetric
        self.series = series
    }

    /// Convenience for the common case of a plain text caption.
    public init(
        metric: MetricID?,
        renderer: any CellRenderer,
        historyDepth: Int = 0,
        label: String?,
        alertMetric: MetricID? = nil,
        series: [MetricID] = []
    ) {
        self.init(
            metric: metric,
            renderer: renderer,
            historyDepth: historyDepth,
            adornment: label.map { CellAdornment.text($0) } ?? .none,
            alertMetric: alertMetric,
            series: series
        )
    }
}

/// An ordered strip of cells that renders as a single menu bar item.
///
/// The same model drives desktop panels -- the difference is the surface it is
/// composited onto, not the structure. One model for both is what stops "any
/// combination of stats" from turning into two parallel layout systems.
public struct Widget {
    public var name: String
    public var cells: [Cell]
    /// Gap between cells, overriding the density default.
    ///
    /// Per widget rather than global, because the right spacing depends on what
    /// is in the strip: a row of gauges wants more air than a caption and its
    /// number.
    public var spacing: CGFloat?

    public init(name: String, cells: [Cell], spacing: CGFloat? = nil) {
        self.name = name
        self.cells = cells
        self.spacing = spacing
    }

    /// Every metric this widget needs, for the bus subscription. Deduplicated,
    /// so two cells showing CPU from different angles still only cause one
    /// source activation.
    public var requiredMetrics: Set<MetricID> {
        Set(cells.compactMap(\.metric))
            .union(cells.compactMap(\.alertMetric))
            .union(cells.flatMap(\.series))
    }
}
