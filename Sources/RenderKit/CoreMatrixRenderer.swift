import AppKit
import CoreGraphics
import SensorKit

/// One small bar per core, grouped by performance cluster.
///
/// The grouping is the whole point. Ten anonymous bars tell you the machine is
/// busy; two visibly separate groups tell you *which kind* of busy -- work
/// parked on the efficiency cores is the scheduler doing its job quietly, the
/// same load on the performance cores is something demanding attention. On a
/// heterogeneous CPU those are different facts, and a flat row hides the
/// difference.
///
/// Group sizes are passed in rather than discovered here, because a renderer
/// that queried sysctl would no longer be a pure function of its input and
/// could not be snapshot-tested or reconstructed from a shared document.
public struct CoreMatrixRenderer: CellRenderer {
    public static var typeIdentifier: String { "matrix.cores" }

    /// Core counts per cluster, in draw order. `[6, 4]` is a 6-efficiency,
    /// 4-performance Apple Silicon layout. `[]` draws one undivided run.
    public var groups: [Int]
    public var barWidth: CGFloat
    public var barGap: CGFloat
    public var groupGap: CGFloat
    public var thresholds: Thresholds

    public init(
        groups: [Int] = [],
        barWidth: CGFloat = 2.5,
        barGap: CGFloat = 1,
        groupGap: CGFloat = 4,
        thresholds: Thresholds = .none
    ) {
        self.groups = groups
        self.barWidth = barWidth
        self.barGap = barGap
        self.groupGap = groupGap
        self.thresholds = thresholds
    }

    public static func accepts(_ range: MetricRange) -> Bool { range.isBounded }

    /// The cell's own metric is the first core; `series` carries the rest.
    private func values(_ input: CellInput) -> [Double?] {
        [input.value] + input.series
    }

    private func contentWidth(_ count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let bars = CGFloat(count) * barWidth + CGFloat(count - 1) * barGap
        let gaps = CGFloat(max(0, groups.filter { $0 > 0 }.count - 1)) * (groupGap - barGap)
        return bars + max(0, gaps)
    }

    public func width(for input: CellInput, in context: RenderContext) -> CGFloat {
        (contentWidth(values(input).count) + context.density.cellPadding * 2).rounded(.up)
    }

    public func severity(for input: CellInput) -> Severity {
        // Judged on the busiest core, not the average: one pinned core is the
        // thing worth noticing, and averaging it across ten hides it.
        let peak = values(input).compactMap { $0 }.filter(\.isFinite).max()
        guard let peak else { return .nominal }
        return thresholds.severity(for: peak)
    }

    public func changeKey(for input: CellInput, in context: RenderContext) -> String {
        let rows = Int((context.height - PlotArea.inset * 2) * context.scale)
        var hasher = Hasher()
        for value in values(input) {
            guard let value, value.isFinite else {
                hasher.combine(Int.min)
                continue
            }
            hasher.combine(Int(value / 100 * Double(max(1, rows))))
        }
        return "cores|\(hasher.finalize())|\(severity(for: input))"
    }

    public func draw(
        _ input: CellInput,
        in cgContext: CGContext,
        rect: CGRect,
        context: RenderContext,
        severity: Severity
    ) {
        let plot = PlotArea.rect(in: rect, padding: context.density.cellPadding)
        guard plot.height > 0 else { return }

        let readings = values(input)
        guard !readings.isEmpty else { return }

        let color = severity.color ?? context.nominalColor
        let trackColor = color.withAlphaComponent(0.22).cgColor
        let fillColor = color.cgColor

        // Which core index starts a new cluster.
        var boundaries: Set<Int> = []
        var cursorIndex = 0
        for size in groups.dropLast() where size > 0 {
            cursorIndex += size
            boundaries.insert(cursorIndex)
        }

        var x = plot.minX
        for (index, value) in readings.enumerated() {
            if boundaries.contains(index) { x += groupGap - barGap }

            let track = CGRect(x: x, y: plot.minY, width: barWidth, height: plot.height)
            cgContext.setFillColor(trackColor)
            cgContext.fill(track)

            if let value, value.isFinite, value > 0 {
                let height = max(0.5, plot.height * CGFloat(value / 100))
                cgContext.setFillColor(fillColor)
                cgContext.fill(CGRect(x: x, y: plot.minY, width: barWidth, height: height))
            }

            x += barWidth + barGap
        }
    }
}
