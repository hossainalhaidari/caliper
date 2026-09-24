import AppKit
import CoreGraphics

/// The shape that says a cell is alerting, drawn under it alongside the colour.
///
/// Colour alone is not enough of a signal. Orange and red are the two hues
/// the most common colour-vision deficiencies confuse with each other and with
/// the menu bar's own grey, so for a lot of people "elevated", "critical" and
/// "fine" looked the same. The underline carries the same three states as a
/// shape: none, dashed, solid.
///
/// Under the cell rather than around it because it cannot cost width -- cell
/// widths are fixed by construction, which is what keeps the strip from
/// reflowing -- and because the bottom edge is the one place every style
/// leaves empty.
public enum SeverityMark {
    /// Thickness in points. Above a pixel at 1x, so it survives an external
    /// display, and thin enough to read as an annotation rather than a border.
    static let thickness: CGFloat = 1.5
    /// Dash and gap lengths of the elevated mark.
    static let dash: [CGFloat] = [3, 2]

    /// Draws the mark for `severity` along the bottom of `rect`. Nothing for a
    /// nominal cell.
    public static func draw(
        _ severity: Severity,
        in cgContext: CGContext,
        rect: CGRect,
        inset: CGFloat
    ) {
        guard let color = severity.color else { return }
        let y = rect.minY + thickness / 2 + 0.5
        let start = rect.minX + inset
        let end = rect.maxX - inset
        guard end > start else { return }

        cgContext.saveGState()
        defer { cgContext.restoreGState() }

        cgContext.setStrokeColor(color.cgColor)
        cgContext.setLineWidth(thickness)
        cgContext.setLineCap(.butt)
        if severity == .elevated {
            cgContext.setLineDash(phase: 0, lengths: dash)
        }
        cgContext.move(to: CGPoint(x: start, y: y))
        cgContext.addLine(to: CGPoint(x: end, y: y))
        cgContext.strokePath()
    }
}
