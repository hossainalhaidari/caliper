import CoreGraphics
import Foundation
import LayoutEngine
import RenderKit
import SensorKit

/// What this particular Mac can offer a document.
public struct ResolutionContext: Sendable {
    public var descriptors: [MetricID: MetricDescriptor]
    /// Cores per performance cluster on this machine, for core-matrix cells
    /// that did not pin a layout.
    public var coreGroups: [Int]

    public init(descriptors: [MetricID: MetricDescriptor], coreGroups: [Int] = []) {
        self.descriptors = descriptors
        self.coreGroups = coreGroups
    }

    /// Convenience for the common case: whatever the bus currently offers.
    public init(descriptors: [MetricDescriptor], coreGroups: [Int] = []) {
        self.init(
            descriptors: Dictionary(descriptors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            coreGroups: coreGroups
        )
    }
}

/// Something in a document that this machine or this version cannot honour.
public struct ResolutionIssue: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// A style that shows data, with no data bound to it.
        case missingMetric(style: String)
        /// The hardware simply is not here -- a GPU sensor on a machine without
        /// one, a volume that was never mounted.
        case unknownMetric(MetricID)
        /// The style makes a claim the metric cannot support, e.g. a ring for an
        /// unbounded rate.
        case incompatibleStyle(style: String, metric: MetricID)
        /// A style from a newer version of the app.
        case unsupportedStyle(String)
    }

    public let id: UUID
    public let cell: UUID
    public let kind: Kind

    /// Whether the cell could still be drawn. An absent metric is survivable --
    /// the cell holds its width and shows a placeholder, so a shared layout keeps
    /// its shape. A style that cannot be built is not.
    public var isFatal: Bool {
        switch kind {
        case .unknownMetric: false
        case .missingMetric, .incompatibleStyle, .unsupportedStyle: true
        }
    }

    public var summary: String {
        switch kind {
        case .missingMetric(let style):
            String(
                localized: "\(style) needs a metric, and none is set",
                comment: "Import problem. The argument is a style's identifier, such as text.value")
        case .unknownMetric(let metric):
            String(
                localized: "\(metric.rawValue) is not available on this Mac",
                comment: "Import problem. The argument is a metric's identifier, such as gpu.usage")
        case .incompatibleStyle(let style, let metric):
            String(
                localized: "\(style) cannot show \(metric.rawValue), which has no fixed maximum",
                comment: "Import problem. A style's identifier, then a metric's identifier")
        case .unsupportedStyle(let type):
            String(
                localized: "\(type) is not a style this version understands",
                comment: "Import problem: a widget from a newer Caliper. The argument is a style's identifier")
        }
    }
}

/// A document turned into something drawable, plus everything that went wrong.
///
/// Not `Sendable`: it carries a `Widget`, whose renderers are existentials meant
/// to be used from the main actor where drawing happens. The *document* is
/// sendable; the resolved product deliberately is not.
public struct Resolution {
    public let widget: Widget
    public let issues: [ResolutionIssue]

    public var isComplete: Bool { issues.isEmpty }

    /// Cells that had to be dropped entirely.
    public var droppedCells: Int {
        Set(issues.filter(\.isFatal).map(\.cell)).count
    }

    /// One line for an import sheet or a warning badge.
    public var summary: String {
        guard !isComplete else {
            return String(localized: "Everything resolved.", comment: "Import report: nothing went wrong")
        }
        let missing = issues.filter { if case .unknownMetric = $0.kind { true } else { false } }.count
        let dropped = droppedCells
        var parts: [String] = []
        if missing > 0 {
            parts.append(String(
                localized: "\(missing) metrics unavailable",
                comment: "Import report: how many metrics this Mac does not have"))
        }
        if dropped > 0 {
            parts.append(String(
                localized: "\(dropped) cells could not be shown",
                comment: "Import report: how many cells were left out"))
        }
        return ListFormatter.localizedString(byJoining: parts)
    }
}

public extension WidgetDocument {

    /// Builds a renderable widget, reporting rather than hiding what did not fit.
    ///
    /// The guiding rule: **a widget authored on other hardware should degrade
    /// visibly, never silently.** A missing sensor keeps its cell -- reserved
    /// width, placeholder glyph -- so the layout the author designed still holds
    /// its shape and the gap is obviously a gap. Only a cell that cannot be
    /// drawn at all is dropped, and the caller is told how many.
    func resolve(in context: ResolutionContext) -> Resolution {
        var cells: [Cell] = []
        var issues: [ResolutionIssue] = []

        for document in self.cells {
            // Decorative cells have no metric, so there is nothing to resolve
            // and nothing to report as missing.
            let descriptor = document.metric.flatMap { context.descriptors[$0] }

            if descriptor == nil, let metric = document.metric {
                issues.append(
                    ResolutionIssue(id: UUID(), cell: document.id, kind: .unknownMetric(metric))
                )
            }

            // A data style with nothing bound to it would render a placeholder
            // for ever, which looks like a broken sensor rather than an
            // unfinished cell. Decorative styles legitimately have no metric.
            if document.metric == nil, !document.style.isDecorative {
                issues.append(
                    ResolutionIssue(
                        id: UUID(),
                        cell: document.id,
                        kind: .missingMetric(style: document.style.typeIdentifier)
                    )
                )
                continue
            }

            if case .unsupported(let type, _) = document.style {
                issues.append(
                    ResolutionIssue(id: UUID(), cell: document.id, kind: .unsupportedStyle(type))
                )
                continue
            }

            // Only enforce compatibility when the metric is actually known. An
            // absent metric has no range to check, and refusing it here would
            // turn a survivable gap into a dropped cell.
            if let descriptor, let metric = document.metric, !document.style.accepts(descriptor.range) {
                issues.append(
                    ResolutionIssue(
                        id: UUID(),
                        cell: document.id,
                        kind: .incompatibleStyle(
                            style: document.style.typeIdentifier,
                            metric: metric
                        )
                    )
                )
                continue
            }

            var style = document.style
            // A core matrix that did not pin a layout adopts this machine's, so
            // a widget from a 10-core Mac draws correctly on an 8-core one
            // instead of reproducing the author's core count.
            if case .coreMatrix(let options) = style, options.groups.isEmpty, !context.coreGroups.isEmpty {
                style = .coreMatrix(.init(groups: context.coreGroups))
            }

            guard let renderer = style.makeRenderer(thresholds: document.thresholds ?? .none) else {
                issues.append(
                    ResolutionIssue(
                        id: UUID(),
                        cell: document.id,
                        kind: .unsupportedStyle(style.typeIdentifier)
                    )
                )
                continue
            }

            // Series metrics that are not present are dropped rather than
            // rendered as gaps: a core matrix on an 8-core Mac should be eight
            // bars wide, not ten with two blanks.
            var series: [MetricID] = []
            for metric in document.series {
                if context.descriptors[metric] == nil {
                    issues.append(
                        ResolutionIssue(id: UUID(), cell: document.id, kind: .unknownMetric(metric))
                    )
                    continue
                }
                series.append(metric)
            }

            cells.append(
                Cell(
                    metric: document.metric,
                    renderer: renderer,
                    historyDepth: style.historyDepth,
                    adornment: document.adornment,
                    alertMetric: document.alertMetric,
                    series: series
                )
            )
        }

        return Resolution(
            widget: Widget(name: name, cells: cells, spacing: spacing.map { CGFloat($0) }),
            issues: issues
        )
    }
}
