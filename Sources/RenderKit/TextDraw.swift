import AppKit
import CoreGraphics
import CoreText

/// Core Text plumbing shared by the styles that draw text.
///
/// Core Text rather than `NSAttributedString.draw`: at 11pt in a 22pt strip,
/// redrawn every second, the difference between placing a `CTLine` yourself and
/// going through AppKit's string drawing is both measurable and, more
/// importantly, controllable -- baseline placement here is derived from font
/// metrics rather than from whatever the layout manager decides.
enum TextDraw {

    static func line(_ text: String, font: NSFont, color: NSColor) -> CTLine {
        CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        )
    }

    static func measure(_ text: String, font: NSFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(text, font: font, color: .black), nil, nil, nil))
    }

    /// Draws with the baseline placed by font metrics, and returns the advance.
    ///
    /// Centring on metrics rather than on the glyphs' bounding box is what keeps
    /// the baseline still when the text changes: "9%" and "40%" have different
    /// ink extents but identical ascender and descender, so metric centring
    /// cannot move and optical centring would.
    @discardableResult
    static func draw(
        _ text: String,
        font: NSFont,
        color: NSColor,
        at x: CGFloat,
        in rect: CGRect,
        context cgContext: CGContext
    ) -> CGFloat {
        let ctLine = line(text, font: font, color: color)
        let textHeight = font.ascender - font.descender
        let baseline = rect.minY + ((rect.height - textHeight) / 2) - font.descender

        cgContext.textPosition = CGPoint(x: x, y: baseline.rounded())
        CTLineDraw(ctLine, cgContext)

        return CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
    }
}
