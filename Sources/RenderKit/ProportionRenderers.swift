import AppKit
import CoreGraphics
import SensorKit

/// Shapes that show a part of a known whole.
///
/// All three refuse unbounded metrics. A ring that is 3% full when your network
/// is doing 3 MB/s is not a rough approximation -- it is a claim about a maximum
/// that does not exist. Refusing the binding in the editor is kinder than
/// drawing a shape that can never be read correctly.
private enum Proportion {
    static func accepts(_ range: MetricRange) -> Bool { range.isBounded }

    /// Track alpha. Low enough to read as a groove rather than a second value,
    /// high enough to show the shape when the value is near zero -- otherwise an
    /// idle donut looks like a rendering failure.
    static let trackAlpha: CGFloat = 0.22

    /// Draws the no-reading placeholder: the same en dash a text cell shows.
    ///
    /// An empty ring and a ring reading 0% are the same picture, so a sensor
    /// this Mac does not have looked exactly like a sensor reporting that
    /// nothing is happening. A dashed track was the first attempt and is far too
    /// quiet at sixteen points.
    ///
    /// Borrowing the text placeholder instead means the app has **one** glyph
    /// for "no reading" across every style. Somebody who has learnt what the
    /// dash means in one cell already knows what it means in all of them, which
    /// is worth more than a shape-specific idiom.
    static func drawUnavailable(
        in cgContext: CGContext,
        rect: CGRect,
        color: NSColor,
        context: RenderContext
    ) {
        let text = ValueFormatter.placeholder
        let width = TextDraw.measure(text, font: context.font)
        TextDraw.draw(
            text,
            font: context.font,
            color: color.withAlphaComponent(0.6),
            at: rect.midX - width / 2,
            in: rect,
            context: cgContext
        )
    }
}

/// A ring that fills clockwise from the top.
public struct DonutRenderer: CellRenderer {
    public static var typeIdentifier: String { "gauge.donut" }

    public var scale: ValueScale?
    public var thresholds: Thresholds
    /// Ring thickness as a fraction of diameter.
    public var thicknessRatio: CGFloat

    public init(
        scale: ValueScale? = nil,
        thresholds: Thresholds = .none,
        thicknessRatio: CGFloat = 0.2
    ) {
        self.scale = scale
        self.thresholds = thresholds
        self.thicknessRatio = thicknessRatio
    }

    public static func accepts(_ range: MetricRange) -> Bool { Proportion.accepts(range) }

    private func diameter(in context: RenderContext) -> CGFloat {
        // Proportional rather than a flat 16pt cap. In the 22pt menu bar this
        // still resolves to 16, but a desktop widget is drawn at a larger height
        // and a ring frozen at menu bar size would look like a mistake.
        min(context.height - 6, context.height * 0.75)
    }

    public func width(for input: CellInput, in context: RenderContext) -> CGFloat {
        (diameter(in: context) + context.density.cellPadding * 2).rounded(.up)
    }

    public func severity(for input: CellInput) -> Severity {
        guard let value = input.severityInput, value.isFinite else { return .nominal }
        return thresholds.severity(for: value)
    }

    public func changeKey(for input: CellInput, in context: RenderContext) -> String {
        let resolved = (scale ?? .default(for: input.range, unit: input.unit)).resolve(for: [])
        // Quantised to whole degrees: a ring cannot show finer than that at
        // 16pt, so anything more precise is a redraw nobody can see.
        let degrees = input.value.map {
            Int(GraphGeometry.fraction($0, in: resolved) * 360)
        } ?? -1
        return "donut|\(degrees)|\(severity(for: input))"
    }

    public func draw(
        _ input: CellInput,
        in cgContext: CGContext,
        rect: CGRect,
        context: RenderContext,
        severity: Severity
    ) {
        let size = diameter(in: context)
        let lineWidth = max(2, size * thicknessRatio)
        let radius = (size - lineWidth) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let color = severity.color ?? context.nominalColor

        cgContext.setLineWidth(lineWidth)
        cgContext.setLineCap(.butt)

        guard let value = input.value, value.isFinite else {
            Proportion.drawUnavailable(in: cgContext, rect: rect, color: color, context: context)
            return
        }

        cgContext.setStrokeColor(color.withAlphaComponent(Proportion.trackAlpha).cgColor)
        cgContext.addArc(
            center: center, radius: radius,
            startAngle: 0, endAngle: .pi * 2, clockwise: false
        )
        cgContext.strokePath()
        let resolved = (scale ?? .default(for: input.range, unit: input.unit)).resolve(for: [])
        let fraction = GraphGeometry.fraction(value, in: resolved)
        guard fraction > 0 else { return }

        // Twelve o'clock is .pi/2 in a y-up context, and clockwise means
        // decreasing angle.
        let start = CGFloat.pi / 2
        cgContext.setStrokeColor(color.cgColor)
        cgContext.addArc(
            center: center, radius: radius,
            startAngle: start,
            endAngle: start - .pi * 2 * CGFloat(fraction),
            clockwise: true
        )
        cgContext.strokePath()
    }
}

/// A 270-degree dial, open at the bottom.
///
/// The gap is what distinguishes it from the donut at a glance: an arc has a
/// visible start and end, so "nearly full" and "just started" are
/// distinguishable without reading the number.
public struct ArcGaugeRenderer: CellRenderer {
    public static var typeIdentifier: String { "gauge.arc" }

    public var scale: ValueScale?
    public var thresholds: Thresholds

    /// Where the dial begins, measured in a y-up context: up and to the left.
    private static let startAngle = CGFloat.pi * 1.25
    private static let sweep = CGFloat.pi * 1.5

    public init(scale: ValueScale? = nil, thresholds: Thresholds = .none) {
        self.scale = scale
        self.thresholds = thresholds
    }

    public static func accepts(_ range: MetricRange) -> Bool { Proportion.accepts(range) }

    private func diameter(in context: RenderContext) -> CGFloat {
        min(context.height - 5, context.height * 0.78)
    }

    public func width(for input: CellInput, in context: RenderContext) -> CGFloat {
        (diameter(in: context) + context.density.cellPadding * 2).rounded(.up)
    }

    public func severity(for input: CellInput) -> Severity {
        guard let value = input.severityInput, value.isFinite else { return .nominal }
        return thresholds.severity(for: value)
    }

    public func changeKey(for input: CellInput, in context: RenderContext) -> String {
        let resolved = (scale ?? .default(for: input.range, unit: input.unit)).resolve(for: [])
        let degrees = input.value.map {
            Int(GraphGeometry.fraction($0, in: resolved) * 270)
        } ?? -1
        return "arc|\(degrees)|\(severity(for: input))"
    }

    public func draw(
        _ input: CellInput,
        in cgContext: CGContext,
        rect: CGRect,
        context: RenderContext,
        severity: Severity
    ) {
        let size = diameter(in: context)
        let lineWidth = max(2, size * 0.18)
        let radius = (size - lineWidth) / 2
        // Nudged up so the open bottom does not make the dial look like it is
        // sitting too low in the cell.
        let center = CGPoint(x: rect.midX, y: rect.midY - 1)
        let color = severity.color ?? context.nominalColor

        cgContext.setLineWidth(lineWidth)
        cgContext.setLineCap(.round)

        guard let value = input.value, value.isFinite else {
            Proportion.drawUnavailable(in: cgContext, rect: rect, color: color, context: context)
            return
        }

        cgContext.setStrokeColor(color.withAlphaComponent(Proportion.trackAlpha).cgColor)
        cgContext.addArc(
            center: center, radius: radius,
            startAngle: Self.startAngle,
            endAngle: Self.startAngle - Self.sweep,
            clockwise: true
        )
        cgContext.strokePath()
        let resolved = (scale ?? .default(for: input.range, unit: input.unit)).resolve(for: [])
        let fraction = GraphGeometry.fraction(value, in: resolved)
        guard fraction > 0 else { return }

        cgContext.setStrokeColor(color.cgColor)
        cgContext.addArc(
            center: center, radius: radius,
            startAngle: Self.startAngle,
            endAngle: Self.startAngle - Self.sweep * CGFloat(fraction),
            clockwise: true
        )
        cgContext.strokePath()
    }
}

/// A horizontal track that fills left to right.
///
/// The most compact of the three and the easiest to compare across cells,
/// because two bars stacked in a strip share a baseline and a length.
public struct BarRenderer: CellRenderer {
    public static var typeIdentifier: String { "gauge.bar" }

    public var scale: ValueScale?
    public var thresholds: Thresholds
    public var width: CGFloat
    public var thickness: CGFloat

    public init(
        scale: ValueScale? = nil,
        thresholds: Thresholds = .none,
        width: CGFloat = 24,
        thickness: CGFloat = 6
    ) {
        self.scale = scale
        self.thresholds = thresholds
        self.width = width
        self.thickness = thickness
    }

    public static func accepts(_ range: MetricRange) -> Bool { Proportion.accepts(range) }

    public func width(for input: CellInput, in context: RenderContext) -> CGFloat {
        (width + context.density.cellPadding * 2).rounded(.up)
    }

    public func severity(for input: CellInput) -> Severity {
        guard let value = input.severityInput, value.isFinite else { return .nominal }
        return thresholds.severity(for: value)
    }

    public func changeKey(for input: CellInput, in context: RenderContext) -> String {
        let resolved = (scale ?? .default(for: input.range, unit: input.unit)).resolve(for: [])
        let pixels = input.value.map {
            Int(GraphGeometry.fraction($0, in: resolved) * width * context.scale)
        } ?? -1
        return "bar|\(pixels)|\(severity(for: input))"
    }

    public func draw(
        _ input: CellInput,
        in cgContext: CGContext,
        rect: CGRect,
        context: RenderContext,
        severity: Severity
    ) {
        let color = severity.color ?? context.nominalColor
        let track = CGRect(
            x: rect.minX + context.density.cellPadding,
            y: rect.midY - thickness / 2,
            width: width,
            height: thickness
        )
        let radius = thickness / 2

        let path = CGPath(roundedRect: track, cornerWidth: radius, cornerHeight: radius, transform: nil)

        guard let value = input.value, value.isFinite else {
            Proportion.drawUnavailable(in: cgContext, rect: rect, color: color, context: context)
            return
        }

        cgContext.setFillColor(color.withAlphaComponent(Proportion.trackAlpha).cgColor)
        cgContext.addPath(path)
        cgContext.fillPath()
        let resolved = (scale ?? .default(for: input.range, unit: input.unit)).resolve(for: [])
        let fraction = GraphGeometry.fraction(value, in: resolved)
        guard fraction > 0 else { return }

        // Never narrower than the cap diameter, so a small value renders as a
        // dot rather than as a sliver the rounded corners cannot express.
        let filled = CGRect(
            x: track.minX,
            y: track.minY,
            width: max(thickness, track.width * CGFloat(fraction)),
            height: track.height
        )
        cgContext.setFillColor(color.cgColor)
        cgContext.addPath(CGPath(roundedRect: filled, cornerWidth: radius, cornerHeight: radius, transform: nil))
        cgContext.fillPath()
    }
}
