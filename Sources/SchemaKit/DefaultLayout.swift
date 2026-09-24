import Foundation
import RenderKit
import SensorKit

public extension WidgetDocument {

    /// The strip a fresh install starts with.
    ///
    /// A document rather than code, so the first thing the editor opens is an
    /// ordinary widget the user can take apart -- not a special case that
    /// behaves differently from anything they can build themselves.
    static func overview() -> WidgetDocument {
        WidgetDocument(
            name: String(localized: "Overview", comment: "Name of the widget a first launch starts with"),
            cells: [
                CellDocument(
                    metric: CPULoadSource.total,
                    style: .text(.init(decimals: 0)),
                    label: String(localized: "CPU", comment: "Metric group: the processor as a whole"),
                    thresholds: Thresholds(elevated: 70, critical: 90)
                ),
                CellDocument(
                    metric: CPULoadSource.total,
                    style: .history(.init(mode: .area, capacity: 60)),
                    thresholds: Thresholds(elevated: 70, critical: 90)
                ),

                // Shows "used" and alerts on pressure. A healthy Mac reads a
                // busy-looking 78% while the kernel is perfectly happy, so the
                // number people expect and the number that is true have to be
                // allowed to disagree.
                CellDocument(
                    metric: MemorySource.usagePercent,
                    style: .donut,
                    alertMetric: MemorySource.pressure,
                    thresholds: Thresholds(
                        elevated: MemorySource.Pressure.warning.rawValue,
                        critical: MemorySource.Pressure.critical.rawValue
                    )
                ),

                CellDocument(
                    metric: NetworkSource.downloadRate,
                    style: .dualRate(.init(decimals: 0)),
                    series: [NetworkSource.uploadRate]
                ),
            ]
        )
    }
}

public extension LayoutDocument {
    static func initial() -> LayoutDocument {
        LayoutDocument(widgets: [.overview()])
    }
}
