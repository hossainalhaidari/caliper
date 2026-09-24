import AppKit
import CoreGraphics
import SensorKit

/// Shared plotting behaviour for the styles that draw a data window.
enum PlotArea {
    /// Vertical inset inside the 22pt item, so a graph does not run edge to edge
    /// against the menu bar's own text.
    static let inset: CGFloat = 4

    static func rect(in bounds: CGRect, padding: CGFloat) -> CGRect {
        bounds.insetBy(dx: padding, dy: inset)
    }

    /// Newest sample on the right.
    ///
    /// The window fills from the right as history accumulates, so a freshly
    /// launched graph grows into its frame instead of stretching two samples
    /// across the full width and pretending to know more than it does.
    static func x(
        forIndex index: Int,
        count: Int,
        capacity: Int,
        in rect: CGRect
    ) -> CGFloat {
        let slots = max(1, capacity - 1)
        let step = rect.width / CGFloat(slots)
        return rect.maxX - CGFloat(count - 1 - index) * step
    }
}

/// A line or filled area over the metric's recent history.
public struct HistoryGraphRenderer: CellRenderer {
    public static var typeIdentifier: String { "graph.history" }

    public enum Style: String, Sendable, Codable {
        case line
        case area
    }

    public var style: Style
    /// `nil` adopts the default policy for the bound metric's range.
    public var scale: ValueScale?
    public var width: CGFloat
    /// Number of samples the graph is sized for. The cell must request at least
    /// this much history or the plot will never reach the left edge.
    public var capacity: Int
    public var thresholds: Thresholds

    public init(
        style: Style = .area,
        scale: ValueScale? = nil,
        width: CGFloat = 34,
        capacity: Int = 60,
        thresholds: Thresholds = .none
    ) {
        self.style = style
        self.scale = scale
        self.width = width
        self.capacity = capacity
        self.thresholds = thresholds
    }

    public func width(for input: CellInput, in context: RenderContext) -> CGFloat {
        (width + context.density.cellPadding * 2).rounded(.up)
    }

    public func severity(for input: CellInput) -> Severity {
        guard let value = input.severityInput, value.isFinite else { return .nominal }
        return thresholds.severity(for: value)
    }

    public func changeKey(for input: CellInput, in context: RenderContext) -> String {
        let resolved = resolvedScale(for: input).resolve(for: input.history)
        let pixels = Int((context.height - PlotArea.inset * 2) * context.scale)
        let hash = GraphGeometry.changeKey(
            for: input.history,
            scale: resolved,
            pixelHeight: pixels
        )
        return "\(style.rawValue)|\(hash)|\(severity(for: input))"
    }

    public func draw(
        _ input: CellInput,
        in cgContext: CGContext,
        rect: CGRect,
        context: RenderContext,
        severity: Severity
    ) {
        let plot = PlotArea.rect(in: rect, padding: context.density.cellPadding)
        guard plot.width > 0, plot.height > 0, !input.history.isEmpty else { return }

        let color = severity.color ?? context.nominalColor
        let resolved = resolvedScale(for: input).resolve(for: input.history)

        // A run of consecutive readings. NaN means the sampler had nothing to
        // report, and the line must break rather than dive to the floor and
        // invent a drop that never happened.
        var runs: [[CGPoint]] = []
        var current: [CGPoint] = []

        for (index, sample) in input.history.enumerated() {
            guard sample.isFinite else {
                if current.count > 1 { runs.append(current) }
                current.removeAll(keepingCapacity: true)
                continue
            }
            let fraction = GraphGeometry.fraction(Double(sample), in: resolved)
            current.append(
                CGPoint(
                    x: PlotArea.x(
                        forIndex: index,
                        count: input.history.count,
                        capacity: capacity,
                        in: plot
                    ),
                    y: plot.minY + plot.height * CGFloat(fraction)
                )
            )
        }
        if current.count > 1 { runs.append(current) }
        guard !runs.isEmpty else { return }

        if style == .area {
            // Filled at a fraction of the ink so the stroke still reads as the
            // value. Alpha survives template tinting, so this works in both
            // appearances without a second colour.
            cgContext.setFillColor(color.withAlphaComponent(0.28).cgColor)
            for run in runs {
                let path = CGMutablePath()
                path.move(to: CGPoint(x: run[0].x, y: plot.minY))
                path.addLines(between: run)
                path.addLine(to: CGPoint(x: run[run.count - 1].x, y: plot.minY))
                path.closeSubpath()
                cgContext.addPath(path)
            }
            cgContext.fillPath()
        }

        cgContext.setStrokeColor(color.cgColor)
        cgContext.setLineWidth(1.0)
        cgContext.setLineJoin(.round)
        cgContext.setLineCap(.round)
        for run in runs {
            cgContext.addLines(between: run)
            cgContext.strokePath()
        }
    }

    private func resolvedScale(for input: CellInput) -> ValueScale {
        scale ?? .default(for: input.range, unit: input.unit)
    }
}

/// Recent history as discrete bars, the classic CPU-meter look.
///
/// Reads differently from a line: bars say "these are samples", a line implies a
/// continuous signal between them. For something sampled once a second, bars are
/// arguably the more honest shape.
public struct HistogramRenderer: CellRenderer {
    public static var typeIdentifier: String { "graph.histogram" }

    public var scale: ValueScale?
    public var width: CGFloat
    public var barWidth: CGFloat
    public var barGap: CGFloat
    public var thresholds: Thresholds

    public init(
        scale: ValueScale? = nil,
        width: CGFloat = 34,
        barWidth: CGFloat = 2,
        barGap: CGFloat = 0.5,
        thresholds: Thresholds = .none
    ) {
        self.scale = scale
        self.width = width
        self.barWidth = barWidth
        self.barGap = barGap
        self.thresholds = thresholds
    }

    /// How many bars fit. The cell should request this much history; more is
    /// simply not drawn.
    ///
    /// Guarded rather than trusted. Imports are checked against
    /// `WidgetLimits`, but a hand-edited `layout.json` is not, and bars zero
    /// points wide made this `Int(infinity)`, which traps -- on every launch,
    /// since the layout is read at startup. The cap is the bus's hour of history.
    public var barCount: Int {
        let fitting = Double(width / (barWidth + barGap))
        guard fitting.isFinite, fitting >= 1 else { return 1 }
        return Int(min(fitting, 3600))
    }

    public func width(for input: CellInput, in context: RenderContext) -> CGFloat {
        (width + context.density.cellPadding * 2).rounded(.up)
    }

    public func severity(for input: CellInput) -> Severity {
        guard let value = input.severityInput, value.isFinite else { return .nominal }
        return thresholds.severity(for: value)
    }

    public func changeKey(for input: CellInput, in context: RenderContext) -> String {
        let window = Array(input.history.suffix(barCount))
        let resolved = resolvedScale(for: input).resolve(for: window)
        let pixels = Int((context.height - PlotArea.inset * 2) * context.scale)
        return "bars|\(GraphGeometry.changeKey(for: window, scale: resolved, pixelHeight: pixels))|\(severity(for: input))"
    }

    public func draw(
        _ input: CellInput,
        in cgContext: CGContext,
        rect: CGRect,
        context: RenderContext,
        severity: Severity
    ) {
        let plot = PlotArea.rect(in: rect, padding: context.density.cellPadding)
        guard plot.width > 0, plot.height > 0 else { return }

        let window = Array(input.history.suffix(barCount))
        guard !window.isEmpty else { return }

        let color = severity.color ?? context.nominalColor
        let resolved = resolvedScale(for: input).resolve(for: window)
        let pitch = barWidth + barGap

        cgContext.setFillColor(color.cgColor)
        for (index, sample) in window.enumerated() {
            guard sample.isFinite else { continue }
            let fraction = GraphGeometry.fraction(Double(sample), in: resolved)
            // Right-aligned, newest last, matching the line style.
            let x = plot.maxX - CGFloat(window.count - index) * pitch + barGap
            guard x >= plot.minX else { continue }

            // Never shorter than a hairline: a bar of height zero is
            // indistinguishable from missing data, and "almost nothing" and
            // "nothing at all" are different readings.
            let height = max(0.5, plot.height * CGFloat(fraction))
            cgContext.fill(CGRect(x: x, y: plot.minY, width: barWidth, height: height))
        }
    }

    private func resolvedScale(for input: CellInput) -> ValueScale {
        scale ?? .default(for: input.range, unit: input.unit)
    }
}
