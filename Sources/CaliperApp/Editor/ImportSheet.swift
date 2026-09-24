import RenderKit
import SchemaKit
import SensorKit
import SwiftUI

/// Shows an incoming widget rendered against **your** data, and what it cannot show.
///
/// Deliberately not the author's screenshot. A picture of someone else's machine
/// tells you how it looked for them; rendering it here tells you what you would
/// actually get -- including the gaps where your hardware differs.
struct ImportSheet: View {
    let widgets: [WidgetDocument]
    let source: String?
    let metrics: [MetricDescriptor]
    let preview: StripPreview
    let density: Density
    let onAdd: ([WidgetDocument]) -> Void
    let onCancel: () -> Void

    @State private var selection: Set<UUID> = []
    @State private var focused: UUID?
    @Environment(\.colorScheme) private var colorScheme

    private var focusedWidget: WidgetDocument? {
        widgets.first { $0.id == focused } ?? widgets.first
    }

    private var context: ResolutionContext {
        ResolutionContext(
            descriptors: metrics,
            coreGroups: CPUCoreSource().clusters.map(\.indices.count)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            HStack(spacing: 0) {
                if widgets.count > 1 {
                    list
                    Divider()
                }
                detail
            }

            Divider()
            footer
        }
        .frame(width: widgets.count > 1 ? 660 : 480, height: 420)
        .onAppear {
            selection = Set(widgets.map(\.id))
            focused = widgets.first?.id
        }
        .task(id: focused) {
            guard let widget = focusedWidget else { return }
            preview.update(document: widget, density: density)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Two separate keys rather than a ternary: a ternary of literals
            // is only a localized key if the type checker happens to choose
            // that overload, and the plural needs its own rules either way.
            Group {
                if widgets.count == 1 {
                    Text("Add \u{201C}\(widgets[0].name)\u{201D}?")
                } else {
                    Text("Add \(widgets.count) widgets?")
                }
            }
            .font(.headline)
            if let source {
                Text("From \(source)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var list: some View {
        List(selection: $focused) {
            ForEach(widgets) { widget in
                ImportRow(
                    widget: widget,
                    resolution: widget.resolve(in: context),
                    isIncluded: included(widget)
                )
                .tag(widget.id)
            }
        }
        .frame(width: 220)
    }

    @ViewBuilder
    private var detail: some View {
        if let widget = focusedWidget {
            let resolution = widget.resolve(in: context)

            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(colorScheme == .dark ? Color(white: 0.13) : Color(white: 0.96))
                        .frame(height: 32)
                    if let image = preview.image {
                        Image(nsImage: image)
                            .renderingMode(image.isTemplate ? .template : .original)
                            .foregroundStyle(colorScheme == .dark ? .white : .black)
                            .accessibilityLabel(Text("Preview"))
                            .accessibilityValue(Text(verbatim: preview.spokenDescription))
                    } else {
                        Text("Nothing in this widget can be shown here")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                }

                if resolution.isComplete {
                    Label("Everything in this widget works on this Mac.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                        .font(.callout)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(resolution.summary, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout.weight(.medium))

                        ForEach(resolution.issues) { issue in
                            Text("\u{2022} " + issue.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        Text(resolution.droppedCells > 0
                             ? "Cells that cannot be drawn are left out. The rest still work."
                             : "Missing readings show as a dash and keep their place, so the layout holds its shape.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                }

                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button {
                onAdd(widgets.filter { selection.contains($0.id) })
            } label: {
                if widgets.count > 1 {
                    Text("Add \(selection.count)")
                } else {
                    Text("Add")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selection.isEmpty)
        }
        .padding(16)
    }

    private func included(_ widget: WidgetDocument) -> Binding<Bool> {
        Binding(
            get: { selection.contains(widget.id) },
            set: { value in
                if value { selection.insert(widget.id) } else { selection.remove(widget.id) }
            }
        )
    }

}

/// One row of the multi-widget list.
///
/// A separate view rather than an inline closure: building the row inline left
/// the compiler unable to choose between `ForEach`'s value and binding
/// overloads, and the resulting errors pointed at `ForEach` rather than at
/// anything actually wrong.
private struct ImportRow: View {
    let widget: WidgetDocument
    let resolution: Resolution
    @Binding var isIncluded: Bool

    var body: some View {
        HStack {
            Toggle(isOn: $isIncluded) { Text(verbatim: widget.name) }
                .labelsHidden()
                .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 1) {
                Text(widget.name).lineLimit(1)
                Text(verbatim: resolution.isComplete
                     ? String(
                        localized: "\(widget.cells.count) cells",
                        comment: "Import sheet: how many cells a widget has")
                     : resolution.summary)
                    .font(.caption)
                    .foregroundStyle(resolution.isComplete ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            }
        }
    }
}
