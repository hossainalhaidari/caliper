import AppKit
import CoreGraphics
import RenderKit
import SensorKit

/// Lays a widget's cells out left to right and rasterises them into the single
/// image a status item can display.
///
/// Two behaviours here matter more than the layout arithmetic:
///
/// **It refuses to redraw.** Every cell contributes a change key; if the
/// concatenation is unchanged since the last frame, `compose` returns `nil` and
/// no pixels are touched. A menu bar showing CPU as whole percent genuinely
/// only changes a few times a minute while you type.
///
/// **It picks template vs colour for the whole strip.** AppKit templates are
/// all-or-nothing per image, so one alerting cell forces the entire strip into
/// explicit colours. The nominal cells then draw in `labelColor`, which is what
/// the template would have resolved to anyway -- the transition is invisible.
@MainActor
public final class StripComposer {
    private let canvas = BitmapCanvas()
    private var lastKey: String?

    /// Horizontal extent of each cell in the last composed strip, in points.
    ///
    /// Kept so a click on the status item can be attributed to the cell under
    /// the pointer. Without it the detail panel could only ever show everything,
    /// and "you clicked CPU, so here is CPU" is the whole idea.
    public private(set) var cellFrames: [CGRect] = []

    /// The strip as a screen reader should say it, as of the last redraw.
    ///
    /// The status item is one image, so without this VoiceOver finds a button
    /// with no value at all. Rebuilt only when the image is -- a frame that
    /// looks the same says the same -- so it costs nothing on the skipped ticks
    /// that are most of them.
    public private(set) var spokenDescription = ""

    public init() {}

    /// The widest strip this will rasterise, in points.
    ///
    /// Imports are refused well before this (`WidgetLimits` in SchemaKit), so
    /// this is the backstop for what never passed through one: a hand-edited
    /// `layout.json`, or a desktop widget whose type has been scaled up. Past it
    /// the strip is cut off rather than allocated -- a widget that shows its
    /// first two thousand points is a problem to fix, a hundred-megabyte bitmap
    /// per tick is a problem for the whole Mac.
    public static let maximumWidth: CGFloat = 2400

    /// Input for one frame. Assembled by the app layer from a bus snapshot.
    public struct Frame {
        public var values: [MetricID: Double]
        public var histories: [MetricID: [Float]]
        public var descriptors: [MetricID: MetricDescriptor]

        public init(
            values: [MetricID: Double],
            histories: [MetricID: [Float]] = [:],
            descriptors: [MetricID: MetricDescriptor]
        ) {
            self.values = values
            self.histories = histories
            self.descriptors = descriptors
        }
    }

    /// Returns a fresh image, or `nil` when nothing visible changed.
    public func compose(
        _ widget: Widget,
        frame: Frame,
        context: RenderContext
    ) -> NSImage? {
        let inputs = widget.cells.map { cell in
            makeInput(for: cell, frame: frame)
        }

        let severities = zip(widget.cells, inputs).map { cell, input in
            cell.renderer.severity(for: input)
        }

        var key = context.density.rawValue + "@\(context.scale)"
        for (cell, input) in zip(widget.cells, inputs) {
            // The adornment is part of the key because it can change without any
            // value changing -- renaming a label in the editor must redraw.
            key += "|" + cell.adornment.changeKey
            key += "|" + cell.renderer.changeKey(for: input, in: context)
        }
        // Frames are recomputed only when something actually changed.
        //
        // Cell widths are independent of their values by construction -- that is
        // the invariant that keeps the strip from reflowing, and it is enforced
        // by tests across every style. So a tick that produces no visible change
        // cannot have moved a cell either, and the cached frames stay correct.
        //
        // Measuring them anyway cost real time: each adornment and each value
        // slot is a Core Text line, and doing that on every skipped tick took the
        // no-op path from 1.6 to 9.8 microseconds.
        guard key != lastKey else { return nil }
        lastKey = key
        updateFrames(widget, inputs: inputs, context: context)
        spokenDescription = StripDescription.describe(
            widget, inputs: inputs, severities: severities, descriptors: frame.descriptors
        )

        // Adornment first, then the renderer's own width. The renderer's leading
        // padding doubles as the gap between them.
        let adornmentWidths = widget.cells.map {
            AdornmentPainter.advance($0.adornment, in: context)
        }
        let widths = zip(zip(widget.cells, inputs), adornmentWidths).map { pair, adornment in
            adornment + pair.0.renderer.width(for: pair.1, in: context)
        }
        let spacing = widget.spacing ?? context.density.cellSpacing
        let totalWidth = widths.reduce(0, +)
            + spacing * CGFloat(max(0, widget.cells.count - 1))
        guard totalWidth > 0 else { return nil }

        // Emoji are colour glyphs; a template image would flatten them into
        // silhouettes, so one emoji anywhere forces the whole strip to carry
        // resolved colours -- the same path an alerting cell already takes.
        let hasEmoji = widget.cells.contains { $0.adornment.forcesColour }
        let isTemplate = severities.allSatisfy { $0 == .nominal } && !hasEmoji
        let size = CGSize(width: min(totalWidth, Self.maximumWidth), height: context.height)

        guard let cgImage = canvas.makeImage(size: size, scale: context.scale, draw: { cgContext in
            var x: CGFloat = 0
            for index in widget.cells.indices where x < size.width {
                let cell = widget.cells[index]
                let adornmentWidth = adornmentWidths[index]

                if adornmentWidth > 0 {
                    AdornmentPainter.draw(
                        cell.adornment,
                        in: cgContext,
                        rect: CGRect(
                            x: x + context.density.cellPadding,
                            y: 0,
                            width: adornmentWidth,
                            height: context.height
                        ),
                        context: context,
                        color: severities[index].color ?? context.nominalColor,
                        isNominal: severities[index] == .nominal
                    )
                }

                cell.renderer.draw(
                    inputs[index],
                    in: cgContext,
                    rect: CGRect(
                        x: x + adornmentWidth,
                        y: 0,
                        width: widths[index] - adornmentWidth,
                        height: context.height
                    ),
                    context: context,
                    severity: severities[index]
                )
                // Colour's second channel, for anyone who cannot tell orange
                // from red from grey. See `SeverityMark`.
                SeverityMark.draw(
                    severities[index],
                    in: cgContext,
                    rect: CGRect(x: x, y: 0, width: widths[index], height: context.height),
                    inset: context.density.cellPadding
                )
                x += widths[index] + spacing
            }
        }) else { return nil }

        let image = NSImage(cgImage: cgImage, size: size)
        image.isTemplate = isTemplate
        return image
    }

    private func updateFrames(_ widget: Widget, inputs: [CellInput], context: RenderContext) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        for (cell, input) in zip(widget.cells, inputs) {
            let width = AdornmentPainter.advance(cell.adornment, in: context)
                + cell.renderer.width(for: input, in: context)
            frames.append(CGRect(x: x, y: 0, width: width, height: context.height))
            x += width + context.density.cellSpacing
        }
        cellFrames = frames
    }

    /// The cell under a point, in strip coordinates.
    public func cellIndex(at point: CGPoint) -> Int? {
        // Generous: the gaps between cells belong to the nearest one, so a click
        // in the spacing does nothing surprising.
        cellFrames.enumerated().min { first, second in
            abs(first.element.midX - point.x) < abs(second.element.midX - point.x)
        }?.offset
    }

    /// Forces the next `compose` to redraw. Call after anything that changes
    /// appearance without changing data -- appearance switches, density
    /// changes, moving to a display with a different backing scale.
    public func invalidate() {
        lastKey = nil
    }

    private func makeInput(for cell: Cell, frame: Frame) -> CellInput {
        // An unknown metric is not an error: it is a widget authored on
        // hardware this Mac does not have. It renders as a placeholder dash at
        // full reserved width, so a shared layout keeps its shape instead of
        // collapsing. M4 turns this into an explicit import-time report.
        // A decorative cell has no metric, so there is nothing to look up and
        // nothing to report as unresolvable.
        let descriptor = cell.metric.flatMap { frame.descriptors[$0] }
        let history = cell.metric.flatMap { frame.histories[$0] } ?? []

        return CellInput(
            value: cell.metric.flatMap { frame.values[$0] },
            history: cell.historyDepth > 0 ? history : [],
            unit: descriptor?.unit ?? .count,
            range: descriptor?.range ?? .unbounded(min: 0),
            adornment: cell.adornment,
            alertValue: cell.alertMetric.flatMap { frame.values[$0] },
            series: cell.series.map { frame.values[$0] }
        )
    }
}
