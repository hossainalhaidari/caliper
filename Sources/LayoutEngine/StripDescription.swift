import Foundation
import RenderKit
import SensorKit

/// Says what a strip shows, in words, for VoiceOver.
///
/// Pure, so it is tested like the renderers are: the interesting part is
/// deciding what each cell is *called* and how many of its numbers are worth
/// reading out, and none of that needs a status item to check.
enum StripDescription {
    /// Beyond this many values in one cell -- a core matrix is ten -- reading
    /// each out is a list nobody can hold, so the cell is summarised instead.
    static let listedValues = 3

    static func describe(
        _ widget: Widget,
        inputs: [CellInput],
        severities: [Severity],
        descriptors: [MetricID: MetricDescriptor]
    ) -> String {
        var phrases: [String] = []
        for index in widget.cells.indices {
            let cell = widget.cells[index]
            guard let phrase = describe(
                cell, input: inputs[index], severity: severities[index], descriptors: descriptors
            ) else { continue }
            phrases.append(phrase)
        }
        return ListFormatter.localizedString(byJoining: phrases)
    }

    static func describe(
        _ cell: Cell,
        input: CellInput,
        severity: Severity,
        descriptors: [MetricID: MetricDescriptor]
    ) -> String? {
        // A spacer or a divider shows nothing, so it says nothing.
        let metrics = [cell.metric].compactMap { $0 } + cell.series
        guard let first = metrics.first else { return nil }

        let name = self.name(of: cell, metric: first, descriptors: descriptors)
        let value = self.value(of: cell, input: input, metrics: metrics, descriptors: descriptors)

        return switch severity {
        case .nominal:
            String(
                localized: "\(name) \(value)",
                comment: "VoiceOver: one cell of the menu bar strip. A metric's name, then its reading")
        case .elevated:
            String(
                localized: "\(name) high at \(value)",
                comment: "VoiceOver: a cell past its warning threshold. A metric's name, then its reading")
        case .critical:
            String(
                localized: "\(name) critical at \(value)",
                comment: "VoiceOver: a cell past its critical threshold. A metric's name, then its reading")
        }
    }

    /// The caption when the cell has one, because that is the name its owner
    /// chose and the one they see. An icon or emoji says nothing a screen reader
    /// could use, so those cells fall back to the metric's own name.
    private static func name(
        of cell: Cell,
        metric: MetricID,
        descriptors: [MetricID: MetricDescriptor]
    ) -> String {
        if case .text(let caption) = cell.adornment,
           !caption.trimmingCharacters(in: .whitespaces).isEmpty {
            return caption
        }
        return descriptors[metric]?.displayName ?? metric.rawValue
    }

    private static func value(
        of cell: Cell,
        input: CellInput,
        metrics: [MetricID],
        descriptors: [MetricID: MetricDescriptor]
    ) -> String {
        let noReading = String(
            localized: "no reading",
            comment: "VoiceOver: a cell whose metric has not reported a value, shown as a dash")

        if metrics.count == 1 {
            if let spoken = cell.renderer.spokenValue(for: input) { return spoken }
            guard let value = input.value, value.isFinite else { return noReading }
            return format(value, unit: input.unit)
        }

        // Every value, in the same order as `metrics`.
        let values = (cell.metric == nil ? [] : [input.value]) + input.series
        let readings = zip(metrics, values).compactMap { metric, value -> (MetricID, Double)? in
            guard let value, value.isFinite else { return nil }
            return (metric, value)
        }
        guard !readings.isEmpty else { return noReading }

        if metrics.count <= listedValues {
            return ListFormatter.localizedString(byJoining: readings.map { metric, value in
                let unit = descriptors[metric]?.unit ?? input.unit
                let name = descriptors[metric]?.displayName ?? metric.rawValue
                let reading = format(value, unit: unit)
                return String(
                    localized: "\(name) \(reading)",
                    comment: "VoiceOver: one of several readings in a single cell, such as download and upload")
            })
        }

        let numbers = readings.map(\.1)
        let average = format(numbers.reduce(0, +) / Double(numbers.count), unit: input.unit)
        let highest = format(numbers.max() ?? 0, unit: input.unit)
        return String(
            localized: "average \(average), highest \(highest)",
            comment: "VoiceOver: a cell with many readings, such as one per processor core")
    }

    private static func format(_ value: Double, unit: MetricUnit) -> String {
        ValueFormatter(decimals: 0, showsUnit: true).string(for: value, unit: unit)
    }
}
