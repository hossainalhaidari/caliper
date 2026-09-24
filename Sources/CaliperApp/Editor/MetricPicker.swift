import SchemaKit
import SensorKit
import SwiftUI

/// A searchable list of the metrics **this Mac actually has**.
///
/// Built from the bus's live descriptors rather than a hardcoded catalogue, so
/// it cannot offer a sensor that does not exist here. That is the same
/// information M4's import step uses to report what a shared widget cannot show
/// -- one source of truth for "what is available", used at both ends.
struct MetricPicker: View {
    let metrics: [MetricDescriptor]
    var title: LocalizedStringKey = "Metric"
    /// Restricts the list to metrics a particular style can honestly draw.
    var accepting: CellStyle?
    let onPick: (MetricDescriptor) -> Void

    @State private var query = ""

    private var groups: [(name: String, metrics: [MetricDescriptor])] {
        let filtered = metrics.filter { descriptor in
            if let accepting, !accepting.accepts(descriptor.range) { return false }
            guard !query.isEmpty else { return true }
            return descriptor.displayName.localizedCaseInsensitiveContains(query)
                || descriptor.id.rawValue.localizedCaseInsensitiveContains(query)
        }

        // Grouped by the stable key, headed and ordered by the name a person
        // reads -- which sorts differently once it is not English.
        let grouped = Dictionary(grouping: filtered, by: \.group)
        return grouped
            .map { key, members in
                (
                    MetricDescriptor.title(ofGroup: key),
                    members.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
                )
            }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)

            Divider()

            if groups.isEmpty {
                Text(accepting == nil
                     ? "No metrics match."
                     : "No metric on this Mac can be shown this way.")
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.name) { group in
                        Section {
                            ForEach(group.metrics) { descriptor in
                                Button {
                                    onPick(descriptor)
                                } label: {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(descriptor.displayName)
                                        Text(descriptor.id.rawValue)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.tertiary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Text(verbatim: group.name)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 320, height: 380)
    }
}
