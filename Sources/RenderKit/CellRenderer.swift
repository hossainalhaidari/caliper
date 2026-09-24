import CoreGraphics
import SensorKit

/// Everything one cell needs to draw itself, with no reference to where the
/// numbers came from.
///
/// This is why `RenderKit` does not depend on `MetricBus`: a renderer takes
/// plain values, so every visual style can be snapshot-tested against
/// handwritten input without starting a sampler or touching hardware.
public struct CellInput {
    public var value: Double?
    /// Oldest first. May contain `NaN` for periods before sampling began --
    /// renderers must skip those rather than plotting them as zero.
    public var history: [Float]
    public var unit: MetricUnit
    public var range: MetricRange
    /// What identifies this cell -- a caption, an SF Symbol, or an emoji.
    ///
    /// Drawn by the compositor, not by the renderer, so every style shows it.
    public var adornment: CellAdornment

    /// The value that decides severity, when that is a *different* metric from
    /// the one on display.
    ///
    /// macOS forces this distinction: a healthy Mac routinely reads 78% memory
    /// used while the kernel reports no pressure at all. Showing pressure would
    /// be truthful but unfamiliar; alerting on used% would cry wolf every day.
    /// Splitting them lets a cell show the number people expect and alert on the
    /// number that is right.
    ///
    /// Generalises past memory -- show GPU utilisation, alert on GPU temperature
    /// -- so it is a property of every cell rather than a memory special case.
    /// `nil` means severity comes from `value`, which is the ordinary case.
    public var alertValue: Double?

    /// Additional values, in the order the cell declared them.
    ///
    /// Some styles are inherently multi-valued: a per-core matrix is ten
    /// metrics in one cell, a stacked rate is two. Modelling those as several
    /// cells would be wrong -- they share one frame, one scale, and one
    /// alignment, and splitting them would let the parts drift apart.
    public var series: [Double?]

    public init(
        value: Double?,
        history: [Float] = [],
        unit: MetricUnit,
        range: MetricRange,
        adornment: CellAdornment = .none,
        alertValue: Double? = nil,
        series: [Double?] = []
    ) {
        self.value = value
        self.history = history
        self.unit = unit
        self.range = range
        self.adornment = adornment
        self.alertValue = alertValue
        self.series = series
    }

    /// The number severity is judged on.
    public var severityInput: Double? { alertValue ?? value }

    /// Convenience for the common case of a plain text caption.
    public init(
        value: Double?,
        history: [Float] = [],
        unit: MetricUnit,
        range: MetricRange,
        label: String?,
        alertValue: Double? = nil,
        series: [Double?] = []
    ) {
        self.init(
            value: value,
            history: history,
            unit: unit,
            range: range,
            adornment: label.map { CellAdornment.text($0) } ?? .none,
            alertValue: alertValue,
            series: series
        )
    }
}

/// One visual style, bound to one metric.
///
/// Conformances are values, and drawing is a pure function of
/// `(CellInput, RenderContext)`. That is what will let M4 reconstruct a cell
/// from a JSON object and get a pixel-identical result on someone else's Mac.
public protocol CellRenderer {
    /// Stable name; becomes the `"type"` field in a shared widget document, so
    /// it is API in the same way `MetricID` is.
    static var typeIdentifier: String { get }

    /// Fixed width in points. Must not depend on the current value -- see
    /// `ValueFormatter.widestString(for:range:)`.
    func width(for input: CellInput, in context: RenderContext) -> CGFloat

    func draw(
        _ input: CellInput,
        in cgContext: CGContext,
        rect: CGRect,
        context: RenderContext,
        severity: Severity
    )

    /// What the cell currently *looks* like, collapsed to a string.
    ///
    /// The redraw check compares these. Two ticks that produce 41.2% and 41.4%
    /// both render "41%", so the second one costs a string comparison instead
    /// of a rasterisation. At 1Hz across a strip of cells this removes the
    /// large majority of all drawing work the app would otherwise do.
    func changeKey(for input: CellInput, in context: RenderContext) -> String

    func severity(for input: CellInput) -> Severity

    /// The value as a screen reader should say it, when this style shows it in
    /// a way the generic formatting would not -- a clock's own format, a
    /// number's chosen decimals. `nil` leaves it to the caller's default.
    func spokenValue(for input: CellInput) -> String?

    /// Whether this style can honestly represent a metric with this range.
    ///
    /// A donut showing an unbounded value is not merely ugly, it is a lie: it
    /// implies a whole that the number has no relation to. Declaring the
    /// constraint lets the editor refuse the binding at the point the user makes
    /// it, rather than drawing something meaningless and leaving them to work
    /// out why it never fills up.
    static func accepts(_ range: MetricRange) -> Bool
}

public extension CellRenderer {
    func severity(for input: CellInput) -> Severity { .nominal }
    func spokenValue(for input: CellInput) -> String? { nil }
    static func accepts(_ range: MetricRange) -> Bool { true }
}
