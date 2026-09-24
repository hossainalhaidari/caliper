import RenderKit
import SchemaKit
import SensorKit
import SwiftUI

/// Edits one cell.
///
/// Changes are applied immediately rather than behind an OK button, because the
/// live preview above is the feedback -- an editor where you have to commit to
/// see the result is not direct manipulation, it is a form.
struct CellInspector: View {
    let cell: CellDocument
    let metrics: [MetricDescriptor]
    let onChange: (CellDocument) -> Void

    @State private var pickingMetric = false
    @State private var pickingAlertMetric = false
    @State private var pickingSeries = false

    private var descriptor: MetricDescriptor? {
        cell.metric.flatMap { id in metrics.first { $0.id == id } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !cell.style.isDecorative { binding }
                styleSection
                if !cell.style.isDecorative {
                    appearance
                    alerting
                    if cell.style.isMultiValued { seriesSection }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Sections

    private var binding: some View {
        Section {
            LabeledContent("Metric") {
                Button {
                    pickingMetric = true
                } label: {
                    HStack {
                        Text(descriptor?.displayName ?? cell.metric?.rawValue
                             ?? String(localized: "None", comment: "Cell inspector: no metric, or no threshold"))
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                }
                .popover(isPresented: $pickingMetric, arrowEdge: .bottom) {
                    MetricPicker(metrics: metrics, title: "Metric", accepting: cell.style) { picked in
                        var updated = cell
                        updated.metric = picked.id

                        // Binding a timestamp to a plain number cell would show
                        // seconds since 1970. The style follows the metric, but
                        // only from the default -- a style the user deliberately
                        // chose is left alone.
                        if picked.unit == .timestamp, case .text = updated.style {
                            updated.style = .clock()
                            updated.label = nil
                        }

                        onChange(updated)
                        pickingMetric = false
                    }
                }
            }

            if descriptor == nil {
                Label(
                    "This metric is not available on this Mac. The cell keeps its width and shows a dash.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }
        } header: {
            header("Data")
        }
    }

    private var styleSection: some View {
        Section {
            Picker("Style", selection: styleBinding) {
                ForEach(Array(CellStyle.catalogue.enumerated()), id: \.offset) { _, style in
                    Text(style.displayName)
                        .tag(style.typeIdentifier + style.displayName)
                }
            }
            .pickerStyle(.menu)

            if let descriptor, !cell.style.accepts(descriptor.range) {
                // The editor states the reason rather than merely disabling the
                // choice, because "why can't I pick this" is the question a
                // greyed-out control always provokes.
                Label(
                    "\(cell.style.displayName) needs a metric with a fixed maximum. \(descriptor.displayName) has none, so there is no whole for it to be part of.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }

            styleOptions
        } header: {
            header("Style")
        }
    }

    @ViewBuilder
    private var styleOptions: some View {
        switch cell.style {
        case .text(let options):
            Stepper(
                "Decimal places: \(options.decimals)",
                value: intBinding(
                    get: { options.decimals },
                    set: { .text(.init(decimals: $0, showsUnit: options.showsUnit)) }
                ),
                in: WidgetLimits.decimals
            )
            Toggle("Show unit", isOn: boolBinding(
                get: { options.showsUnit },
                set: { .text(.init(decimals: options.decimals, showsUnit: $0)) }
            ))

        case .history(let options):
            Picker("Shape", selection: historyModeBinding(options)) {
                Text("Filled").tag(CellStyle.HistoryOptions.Mode.area)
                Text("Line").tag(CellStyle.HistoryOptions.Mode.line)
            }
            .pickerStyle(.segmented)

            Stepper(
                "Width: \(Int(options.width))pt",
                value: doubleBinding(
                    get: { options.width },
                    set: { .history(.init(mode: options.mode, width: $0, capacity: options.capacity)) }
                ),
                in: WidgetLimits.graphWidth,
                step: 2
            )

            Stepper(
                "History: \(options.capacity)s",
                value: intBinding(
                    get: { options.capacity },
                    set: { .history(.init(mode: options.mode, width: options.width, capacity: $0)) }
                ),
                in: WidgetLimits.graphHistory,
                step: 10
            )

        case .dualRate(let options):
            Stepper(
                "Decimal places: \(options.decimals)",
                value: intBinding(
                    get: { options.decimals },
                    set: { .dualRate(.init(decimals: $0)) }
                ),
                in: WidgetLimits.rateDecimals
            )

        case .bar(let options):
            Stepper(
                "Width: \(Int(options.width))pt",
                value: doubleBinding(
                    get: { options.width },
                    set: { .bar(.init(width: $0, thickness: options.thickness)) }
                ),
                in: WidgetLimits.barWidth,
                step: 2
            )

        case .clock(let options):
            ClockOptionsEditor(options: options) { updated in
                var cell = self.cell
                cell.style = .clock(updated)
                onChange(cell)
            }

        case .spacer(let options):
            Stepper(
                "Width: \(Int(options.width))pt",
                value: doubleBinding(
                    get: { options.width },
                    set: { .spacer(.init(width: $0)) }
                ),
                in: WidgetLimits.spacerWidth,
                step: 2
            )

        case .divider(let options):
            Stepper(
                "Height inset: \(Int(options.inset))pt",
                value: doubleBinding(
                    get: { options.inset },
                    set: { .divider(.init(thickness: options.thickness, inset: $0)) }
                ),
                in: WidgetLimits.dividerInset
            )

        case .histogram, .donut, .arc, .coreMatrix, .unsupported:
            EmptyView()
        }
    }

    private var appearance: some View {
        Section {
            AdornmentPicker(cell: cell, onChange: onChange)
        } header: {
            header("Appearance")
        }
    }

    private var alerting: some View {
        Section {
            LabeledContent("Alert on") {
                Button {
                    pickingAlertMetric = true
                } label: {
                    Text(alertMetricName)
                }
                .popover(isPresented: $pickingAlertMetric, arrowEdge: .bottom) {
                    VStack(spacing: 0) {
                        alertChoice(
                            "None",
                            detail: "Never alerts. Clears the thresholds too."
                        ) {
                            var updated = cell
                            updated.alertMetric = nil
                            // The alert *is* the thresholds -- a cell with none
                            // is permanently nominal. Leaving them behind would
                            // mean choosing "None" and still getting colour and
                            // notifications off the displayed value.
                            updated.thresholds = nil
                            onChange(updated)
                        }

                        Divider()

                        alertChoice(
                            "Same as displayed metric",
                            detail: "Keeps the thresholds, judges them against the value shown."
                        ) {
                            var updated = cell
                            updated.alertMetric = nil
                            onChange(updated)
                        }

                        Divider()

                        MetricPicker(metrics: metrics, title: "Alert on") { picked in
                            var updated = cell
                            updated.alertMetric = picked.id
                            onChange(updated)
                            pickingAlertMetric = false
                        }
                    }
                    .frame(width: 320)
                }
            }

            Text("The value you watch and the value you show can differ. Memory is the usual case: show how full it is, but colour it by what the kernel actually thinks of the pressure.")
                .font(.callout)
                .foregroundStyle(.tertiary)

            thresholdField("Warn at", keyPath: \.elevated)
            thresholdField("Critical at", keyPath: \.critical)

            Text("Colour only appears when a threshold is crossed. A cell with none stays quiet forever.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        } header: {
            header("Alerting")
        }
    }

    private var seriesSection: some View {
        Section {
            ForEach(Array(cell.series.enumerated()), id: \.offset) { index, metric in
                HStack {
                    Text(metrics.first { $0.id == metric }?.displayName ?? metric.rawValue)
                        .font(.callout)
                    Spacer()
                    Button {
                        var updated = cell
                        updated.series.remove(at: index)
                        onChange(updated)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }

            Button("Add metric\u{2026}") { pickingSeries = true }
                .popover(isPresented: $pickingSeries, arrowEdge: .bottom) {
                    MetricPicker(metrics: metrics, title: "Add to this cell") { picked in
                        var updated = cell
                        updated.series.append(picked.id)
                        onChange(updated)
                        pickingSeries = false
                    }
                }
        } header: {
            header("Additional metrics")
        }
    }

    // MARK: - Helpers

    private func header(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.headline)
            .padding(.top, 4)
    }

    /// One of the fixed rows above the metric list in the "Alert on" popover.
    private func alertChoice(
        _ title: LocalizedStringKey,
        detail: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            pickingAlertMetric = false
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(10)
    }

    /// What the "Alert on" row reads.
    ///
    /// A cell with no thresholds reads "None" rather than "Displayed metric":
    /// with nothing to cross, naming a metric would claim an alert that cannot
    /// fire. A metric chosen explicitly still shows by name, so picking one
    /// before typing the numbers looks like it did something.
    private var alertMetricName: String {
        if let alert = cell.alertMetric {
            return metrics.first { $0.id == alert }?.displayName ?? alert.rawValue
        }
        return cell.thresholds == nil
            ? String(localized: "None", comment: "Cell inspector: no metric, or no threshold")
            : String(localized: "Displayed metric", comment: "Cell inspector: the cell alerts on the value it shows")
    }

    private func thresholdField(
        _ title: LocalizedStringKey,
        keyPath: WritableKeyPath<Thresholds, Double?>
    ) -> some View {
        LabeledContent(title) {
            TextField("None", value: thresholdBinding(keyPath), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
        }
    }

    private func thresholdBinding(_ keyPath: WritableKeyPath<Thresholds, Double?>) -> Binding<Double?> {
        Binding(
            get: { cell.thresholds?[keyPath: keyPath] },
            set: { value in
                var updated = cell
                var thresholds = updated.thresholds ?? .none
                thresholds[keyPath: keyPath] = value
                // An all-empty threshold set is stored as absent, so a quiet
                // cell round-trips through JSON as quiet rather than as
                // "thresholds: {}".
                updated.thresholds = (thresholds.elevated == nil && thresholds.critical == nil)
                    ? nil : thresholds
                onChange(updated)
            }
        )
    }

    private var styleBinding: Binding<String> {
        Binding(
            get: { cell.style.typeIdentifier + cell.style.displayName },
            set: { tag in
                guard let style = CellStyle.catalogue.first(where: { $0.typeIdentifier + $0.displayName == tag })
                else { return }
                var updated = cell
                updated.style = style

                // A clock reads the time, so it binds itself. Making the user
                // hunt for "time.epoch" in the metric picker after choosing
                // "Clock" would be asking them to do the obvious thing by hand.
                if case .clock = style { updated.metric = ClockSource.epoch }

                onChange(updated)
            }
        )
    }

    private func historyModeBinding(_ options: CellStyle.HistoryOptions) -> Binding<CellStyle.HistoryOptions.Mode> {
        Binding(
            get: { options.mode },
            set: { mode in
                var updated = cell
                updated.style = .history(.init(mode: mode, width: options.width, capacity: options.capacity))
                onChange(updated)
            }
        )
    }

    private func intBinding(
        get: @escaping @Sendable () -> Int,
        set: @escaping (Int) -> CellStyle
    ) -> Binding<Int> {
        Binding(
            get: get,
            set: { value in
                var updated = cell
                updated.style = set(value)
                onChange(updated)
            }
        )
    }

    private func doubleBinding(
        get: @escaping @Sendable () -> Double,
        set: @escaping (Double) -> CellStyle
    ) -> Binding<Double> {
        Binding(
            get: get,
            set: { value in
                var updated = cell
                updated.style = set(value)
                onChange(updated)
            }
        )
    }

    private func boolBinding(
        get: @escaping @Sendable () -> Bool,
        set: @escaping (Bool) -> CellStyle
    ) -> Binding<Bool> {
        Binding(
            get: get,
            set: { value in
                var updated = cell
                updated.style = set(value)
                onChange(updated)
            }
        )
    }
}
