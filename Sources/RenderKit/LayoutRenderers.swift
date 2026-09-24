import AppKit
import CoreGraphics
import SensorKit

/// Blank space of a fixed width.
///
/// A cell rather than a property of its neighbours, because spacing in a strip
/// is not uniform in practice: you want a wide gap between CPU and network and
/// none at all between download and upload. Modelling it as a cell means it
/// drags, reorders, copies and serialises like everything else, and the layout
/// code needs no concept of it whatsoever.
public struct SpacerRenderer: CellRenderer {
    public static var typeIdentifier: String { "layout.spacer" }

    public var width: CGFloat

    public init(width: CGFloat = 8) {
        self.width = width
    }

    public func width(for input: CellInput, in context: RenderContext) -> CGFloat {
        max(0, width)
    }

    /// Constant: a spacer has nothing to show and can never need redrawing.
    public func changeKey(for input: CellInput, in context: RenderContext) -> String {
        "spacer|\(width)"
    }

    public func draw(
        _ input: CellInput,
        in cgContext: CGContext,
        rect: CGRect,
        context: RenderContext,
        severity: Severity
    ) {}
}

/// A hairline rule between cells.
///
/// Drawn at low opacity and inset from the top and bottom, so it reads as a
/// separator rather than as a thin bar chart. It follows the strip's ink colour,
/// which means it tints with the menu bar like everything else.
public struct DividerRenderer: CellRenderer {
    public static var typeIdentifier: String { "layout.divider" }

    public var thickness: CGFloat
    /// Vertical inset from the cell's full height.
    public var inset: CGFloat
    public var opacity: CGFloat

    public init(thickness: CGFloat = 1, inset: CGFloat = 5, opacity: CGFloat = 0.28) {
        self.thickness = thickness
        self.inset = inset
        self.opacity = opacity
    }

    public func width(for input: CellInput, in context: RenderContext) -> CGFloat {
        (thickness + context.density.cellPadding * 2).rounded(.up)
    }

    public func changeKey(for input: CellInput, in context: RenderContext) -> String {
        "divider|\(thickness)|\(inset)|\(opacity)"
    }

    public func draw(
        _ input: CellInput,
        in cgContext: CGContext,
        rect: CGRect,
        context: RenderContext,
        severity: Severity
    ) {
        let colour = (severity.color ?? context.nominalColor).withAlphaComponent(opacity)
        cgContext.setFillColor(colour.cgColor)
        cgContext.fill(
            CGRect(
                x: rect.midX - thickness / 2,
                y: rect.minY + inset,
                width: thickness,
                height: max(0, rect.height - inset * 2)
            )
        )
    }
}
