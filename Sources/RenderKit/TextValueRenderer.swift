import AppKit
import CoreGraphics
import CoreText

/// A number, optionally with a short label.
///
/// The plainest possible cell, and the one that has to be perfect: it is what
/// most people will actually put in their menu bar, and it is on screen for
/// every waking hour. Everything expensive about it is precomputed.
public struct TextValueRenderer: CellRenderer {
    public static var typeIdentifier: String { "text.value" }

    public var formatter: ValueFormatter
    public var thresholds: Thresholds

    public init(
        formatter: ValueFormatter = ValueFormatter(),
        thresholds: Thresholds = .none
    ) {
        self.formatter = formatter
        self.thresholds = thresholds
    }

    /// Adornments are not counted here.
    ///
    /// The compositor reserves and draws them, for every style alike. A renderer
    /// that also handled them would double-count the width.
    public func width(for input: CellInput, in context: RenderContext) -> CGFloat {
        let slots = slots(for: input, in: context)
        return (slots.number + slots.suffix + context.density.cellPadding * 2).rounded(.up)
    }

    /// Widths of the number and unit columns, each sized to its own worst case.
    private func slots(
        for input: CellInput,
        in context: RenderContext
    ) -> (number: CGFloat, suffix: CGFloat) {
        let widest = formatter.widestComponents(for: input.unit, range: input.range)
        return (
            number: TextDraw.measure(widest.number, font: context.font),
            suffix: TextDraw.measure(widest.suffix, font: context.font)
        )
    }

    public func changeKey(for input: CellInput, in context: RenderContext) -> String {
        let text = input.value.map { formatter.string(for: $0, unit: input.unit) } ?? "\u{2013}"
        // Severity is part of the key: crossing a threshold changes the colour
        // without necessarily changing the digits, and that still needs a redraw.
        return "\(text)|\(severity(for: input))"
    }

    public func severity(for input: CellInput) -> Severity {
        guard let value = input.severityInput, value.isFinite else { return .nominal }
        return thresholds.severity(for: value)
    }

    /// The digits the cell shows, with the unit always spoken: a hidden "%"
    /// saves width in the menu bar, and a screen reader has no width to save.
    public func spokenValue(for input: CellInput) -> String? {
        guard let value = input.value, value.isFinite else { return nil }
        return ValueFormatter(decimals: formatter.decimals, showsUnit: true)
            .string(for: value, unit: input.unit)
    }

    public func draw(
        _ input: CellInput,
        in cgContext: CGContext,
        rect: CGRect,
        context: RenderContext,
        severity: Severity
    ) {
        let color = severity.color ?? context.nominalColor
        let cursor = rect.minX + context.density.cellPadding

        let parts = input.value.map { formatter.components(for: $0, unit: input.unit) }
            ?? ValueFormatter.Components(number: ValueFormatter.placeholder, suffix: "")
        let slots = slots(for: input, in: context)

        // Number right-aligned in its own column: with tabular figures, a value
        // shrinking from 100% to 99% moves its leading edge and nothing else.
        let numberWidth = TextDraw.measure(parts.number, font: context.font)
        TextDraw.draw(
            parts.number,
            font: context.font,
            color: color,
            at: cursor + (slots.number - numberWidth),
            in: rect,
            context: cgContext
        )

        // Unit left-aligned at a fixed offset, so the "%" and the "MB/s" sit at
        // the same x whatever the magnitude -- which is what makes a strip of
        // several cells read as a small table rather than a run-on sentence.
        guard !parts.suffix.isEmpty else { return }
        TextDraw.draw(
            parts.suffix,
            font: context.font,
            color: color,
            at: cursor + slots.number,
            in: rect,
            context: cgContext
        )
    }

    // MARK: - Core Text

}
