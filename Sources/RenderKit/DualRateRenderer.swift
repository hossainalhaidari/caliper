import AppKit
import CoreGraphics
import SensorKit

/// Two rates stacked in one cell, at half height each.
///
/// This exists to fix a real problem rather than to add a style. Two separate
/// throughput cells each reserve room for their own worst case -- "888 MB/s"
/// twice over -- which made the default strip 279pt wide, most of it empty. One
/// cell sharing a single width reservation is roughly a third of that, because
/// the two rows overlap rather than add.
///
/// It also reads better: download and upload are one fact about one link, and
/// putting them in one frame says so.
public struct DualRateRenderer: CellRenderer {
    public static var typeIdentifier: String { "text.dual-rate" }

    public var formatter: ValueFormatter
    public var thresholds: Thresholds
    /// Glyphs for the upper and lower rows.
    public var symbols: (upper: String, lower: String)
    public var symbolGap: CGFloat = 2

    public init(
        formatter: ValueFormatter = ValueFormatter(decimals: 0),
        thresholds: Thresholds = .none,
        symbols: (upper: String, lower: String) = ("\u{2193}", "\u{2191}")
    ) {
        self.formatter = formatter
        self.thresholds = thresholds
        self.symbols = symbols
    }

    /// Small enough for two rows in 22pt, large enough to stay legible on a
    /// Retina display. Below about 0.7 of the body size the digits start to
    /// close up at these weights.
    private func font(_ context: RenderContext) -> NSFont {
        NSFont.monospacedDigitSystemFont(
            ofSize: (context.font.pointSize * 0.72).rounded(),
            weight: .regular
        )
    }

    private func slots(for input: CellInput, in context: RenderContext) -> (symbol: CGFloat, number: CGFloat, suffix: CGFloat) {
        let font = font(context)
        let widest = formatter.widestComponents(for: input.unit, range: input.range)
        return (
            symbol: max(
                TextDraw.measure(symbols.upper, font: font),
                TextDraw.measure(symbols.lower, font: font)
            ),
            number: TextDraw.measure(widest.number, font: font),
            suffix: TextDraw.measure(widest.suffix, font: font)
        )
    }

    public func width(for input: CellInput, in context: RenderContext) -> CGFloat {
        let slots = slots(for: input, in: context)
        // One reservation for both rows: the widest either can ever be, not the
        // sum of what each can be.
        return (slots.symbol + symbolGap + slots.number + slots.suffix
                + context.density.cellPadding * 2).rounded(.up)
    }

    public func severity(for input: CellInput) -> Severity {
        let candidates = ([input.severityInput] + input.series).compactMap { $0 }.filter(\.isFinite)
        guard let peak = candidates.max() else { return .nominal }
        return thresholds.severity(for: peak)
    }

    public func changeKey(for input: CellInput, in context: RenderContext) -> String {
        let upper = text(for: input.value, input: input)
        let lower = text(for: input.series.first ?? nil, input: input)
        return "dual|\(upper.joined)|\(lower.joined)|\(severity(for: input))"
    }

    public func draw(
        _ input: CellInput,
        in cgContext: CGContext,
        rect: CGRect,
        context: RenderContext,
        severity: Severity
    ) {
        let color = severity.color ?? context.nominalColor
        let font = font(context)
        let slots = slots(for: input, in: context)
        let origin = rect.minX + context.density.cellPadding

        // Split the cell exactly in half; each row is metric-centred within its
        // own half, so the two baselines are symmetric about the middle.
        let upperRect = CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        let lowerRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)

        drawRow(
            symbol: symbols.upper,
            parts: text(for: input.value, input: input),
            in: upperRect, origin: origin, slots: slots,
            font: font, color: color, context: cgContext
        )
        drawRow(
            symbol: symbols.lower,
            parts: text(for: input.series.first ?? nil, input: input),
            in: lowerRect, origin: origin, slots: slots,
            font: font, color: color, context: cgContext
        )
    }

    private func text(for value: Double?, input: CellInput) -> ValueFormatter.Components {
        value.map { formatter.components(for: $0, unit: input.unit) }
            ?? ValueFormatter.Components(number: ValueFormatter.placeholder, suffix: "")
    }

    private func drawRow(
        symbol: String,
        parts: ValueFormatter.Components,
        in rect: CGRect,
        origin: CGFloat,
        slots: (symbol: CGFloat, number: CGFloat, suffix: CGFloat),
        font: NSFont,
        color: NSColor,
        context cgContext: CGContext
    ) {
        // The arrow is a quiet second layer, like a label -- it identifies the
        // row without competing with the number for attention.
        TextDraw.draw(
            symbol, font: font, color: color.withAlphaComponent(0.55),
            at: origin, in: rect, context: cgContext
        )

        let numberX = origin + slots.symbol + symbolGap
        let numberWidth = TextDraw.measure(parts.number, font: font)
        TextDraw.draw(
            parts.number, font: font, color: color,
            at: numberX + (slots.number - numberWidth), in: rect, context: cgContext
        )

        guard !parts.suffix.isEmpty else { return }
        TextDraw.draw(
            parts.suffix, font: font, color: color,
            at: numberX + slots.number, in: rect, context: cgContext
        )
    }
}
