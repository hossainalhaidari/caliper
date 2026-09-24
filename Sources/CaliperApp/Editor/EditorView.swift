import AppKit
import RenderKit
import SchemaKit
import SensorKit
import SwiftUI

struct EditorView: View {
    let store: WidgetStore
    let preview: StripPreview
    let importPreview: StripPreview
    let coordinator: ImportCoordinator
    let metrics: [MetricDescriptor]

    @State private var selectedWidget: UUID?
    @State private var selectedCell: UUID?

    private var widgets: [WidgetDocument] { store.document.widgets }

    private var currentWidget: WidgetDocument? {
        guard let selectedWidget else { return widgets.first }
        return widgets.first { $0.id == selectedWidget } ?? widgets.first
    }

    var body: some View {
        NavigationSplitView {
            WidgetSidebar(
                store: store,
                coordinator: coordinator,
                selection: $selectedWidget,
                selectedCell: $selectedCell
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            if let widget = currentWidget {
                detail(for: widget)
            } else {
                ContentUnavailableView(
                    "No Widgets",
                    systemImage: "menubar.rectangle",
                    description: Text("Add a widget to put something in your menu bar.")
                )
            }
        }
        .task(id: previewKey) {
            guard let widget = currentWidget else { return }
            preview.update(document: widget, density: store.document.density)
        }
        .sheet(isPresented: presentingImport) {
            ImportSheet(
                widgets: coordinator.offered,
                source: coordinator.source,
                metrics: metrics,
                preview: importPreview,
                density: store.document.density,
                onAdd: { accepted in
                    store.edit { $0.widgets.append(contentsOf: accepted) }
                    selectedWidget = accepted.first?.id
                    selectedCell = nil
                    coordinator.dismiss()
                },
                onCancel: { coordinator.dismiss() }
            )
        }
        .alert(
            "Could not import",
            isPresented: Binding(
                get: { coordinator.failure != nil },
                set: { if !$0 { coordinator.failure = nil } }
            )
        ) {
            Button("OK", role: .cancel) { coordinator.failure = nil }
        } message: {
            Text(coordinator.failure ?? "")
        }
    }

    private var presentingImport: Binding<Bool> {
        Binding(
            get: { coordinator.isPresenting },
            set: { if !$0 { coordinator.dismiss() } }
        )
    }

    /// Anything that can change what the preview should show. Rebuilding on a
    /// key rather than diffing documents keeps this honest -- a field added to
    /// the schema later cannot be forgotten here.
    private var previewKey: String {
        "\(store.revision)|\(currentWidget?.id.uuidString ?? "")|\(store.document.density.rawValue)"
    }

    @ViewBuilder
    private func detail(for widget: WidgetDocument) -> some View {
        VStack(spacing: 0) {
            PreviewBar(preview: preview, density: store.document.density)

            CellStrip(
                widget: widget,
                metrics: metrics,
                selection: $selectedCell,
                store: store
            )

            Divider()

            if let cellID = selectedCell,
               let index = widget.cells.firstIndex(where: { $0.id == cellID }) {
                CellInspector(
                    cell: widget.cells[index],
                    metrics: metrics,
                    onChange: { updated in
                        store.updateWidget(id: widget.id) { document in
                            guard let position = document.cells.firstIndex(where: { $0.id == updated.id })
                            else { return }
                            document.cells[position] = updated
                        }
                    }
                )
                .id(cellID)
            } else {
                VStack(spacing: 6) {
                    Text("Select a cell to edit it")
                        .foregroundStyle(.secondary)
                    Text("Drag cells to reorder them.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    WidgetExport.copyToPasteboard(widget)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copy this widget as JSON, ready to paste into a message")
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    WidgetExport.save(widget)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Save this widget as a file you can send")
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    coordinator.offerPasteboard()
                } label: {
                    Label("Paste", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("v", modifiers: .command)
                .help("Add a widget from JSON on the clipboard")
            }

            ToolbarItem(placement: .automatic) {
                Stepper(
                    "Gap \(Int(widget.spacing ?? Double(store.document.density.cellSpacing)))",
                    value: spacingBinding(widget),
                    in: WidgetLimits.spacing,
                    step: 1
                )
                .help("Space between cells in this widget")
            }

            ToolbarItem(placement: .automatic) {
                Picker("Density", selection: densityBinding) {
                    ForEach(Density.allCases, id: \.self) { density in
                        Text(verbatim: density.title).tag(density)
                    }
                }
                .pickerStyle(.segmented)
                .help("How much room cells give themselves")
            }
        }
    }

    /// Per widget, defaulting to the density's own spacing until touched.
    private func spacingBinding(_ widget: WidgetDocument) -> Binding<Double> {
        Binding(
            get: { widget.spacing ?? Double(store.document.density.cellSpacing) },
            set: { value in
                store.updateWidget(id: widget.id) { $0.spacing = value }
            }
        )
    }

    private var densityBinding: Binding<Density> {
        Binding(
            get: { store.document.density },
            set: { value in store.edit { $0.density = value } }
        )
    }
}

// MARK: - Sidebar

private struct WidgetSidebar: View {
    let store: WidgetStore
    let coordinator: ImportCoordinator
    @Binding var selection: UUID?
    @Binding var selectedCell: UUID?

    /// Which row is being renamed, if any.
    @State private var renaming: UUID?
    @FocusState private var renameFocus: UUID?

    var body: some View {
        List(selection: $selection) {
            Section("Widgets") {
                ForEach(store.document.widgets) { widget in
                    HStack {
                        // Shows and hides the widget wherever it lives -- the
                        // menu bar for most, the desktop for a placed one. It
                        // must not move a widget between the two: that is what
                        // "Show On" in the context menu is for.
                        // Hidden, but still what VoiceOver calls the checkbox --
                        // an empty label left it announcing only "checkbox".
                        Toggle(isOn: enabled(widget)) { Text(verbatim: widget.name) }
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .help(visibilityHelp(widget))

                        if renaming == widget.id {
                            TextField("Name", text: nameBinding(widget))
                                .textFieldStyle(.plain)
                                .focused($renameFocus, equals: widget.id)
                                .onSubmit { finishRenaming(widget) }
                                // Escape leaves the name as typed rather than
                                // reverting; every keystroke has already been
                                // committed, so there is nothing to roll back to.
                                .onExitCommand { finishRenaming(widget) }
                        } else {
                            Text(widget.name)
                                .lineLimit(1)
                                .foregroundStyle(widget.isEnabled ? .primary : .secondary)
                                // Double-click to rename, as everywhere else in
                                // macOS. The context menu carries the same action
                                // for anyone who does not think to try it.
                                .onTapGesture(count: 2) { beginRenaming(widget) }
                        }

                        Spacer()

                        if widget.desktop != nil {
                            Image(systemName: "macwindow.on.rectangle")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .help("Lives on the desktop rather than the menu bar")
                        }

                        Text(widget.cells.count, format: .number)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .tag(widget.id)
                    .contextMenu {
                        Button("Rename\u{2026}") { beginRenaming(widget) }
                        Divider()
                        // A picker rather than a checkbox, because the two are
                        // alternatives: a widget is drawn in one place or the
                        // other, never both.
                        Picker("Show On", selection: onDesktop(widget)) {
                            Text("Menu Bar").tag(false)
                            Text("Desktop").tag(true)
                        }
                        if widget.desktop != nil {
                            Picker("Desktop Layer", selection: desktopLevel(widget)) {
                                Text("Behind windows").tag(DesktopPlacement.Level.desktop)
                                Text("Floating above").tag(DesktopPlacement.Level.floating)
                            }
                        }
                        Divider()
                        Button("Copy as JSON") { WidgetExport.copyToPasteboard(widget) }
                        Button("Export\u{2026}") { WidgetExport.save(widget) }
                        Divider()
                        Button("Duplicate") { duplicate(widget) }
                        Button("Delete", role: .destructive) { delete(widget) }
                    }
                }
                .onMove { source, destination in
                    store.edit { $0.widgets.move(fromOffsets: source, toOffset: destination) }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            // Dropping a file straight onto the list of widgets is the most
            // direct gesture there is, and it costs nothing once the open panel
            // path exists.
            guard let url = urls.first else { return false }
            coordinator.offer(url: url)
            return true
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 2) {
                Button {
                    add()
                } label: {
                    Image(systemName: "plus")
                }
                .help("New widget")

                Button {
                    if let selection, let widget = store.widget(id: selection) { delete(widget) }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                .help("Delete widget")

                Spacer()

                Button {
                    openWidgetFile()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Import a widget from a file")
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func openWidgetFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImportCoordinator.readableTypes
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a widget to add.", comment: "Message at the top of the Import open panel")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        coordinator.offer(url: url)
    }

    /// What the row's checkbox is about to do, which depends on where the
    /// widget is drawn.
    private func visibilityHelp(_ widget: WidgetDocument) -> String {
        guard widget.isEnabled else {
            return String(localized: "Hidden", comment: "Tooltip on a widget's checkbox: it is not shown anywhere")
        }
        return widget.desktop == nil
            ? String(localized: "Shown in the menu bar", comment: "Tooltip on a widget's checkbox")
            : String(localized: "Shown on the desktop", comment: "Tooltip on a widget's checkbox")
    }

    private func onDesktop(_ widget: WidgetDocument) -> Binding<Bool> {
        Binding(
            get: { widget.desktop != nil },
            set: { value in
                store.updateWidget(id: widget.id) { document in
                    document.desktop = value ? DesktopPlacement() : nil
                }
            }
        )
    }

    private func desktopLevel(_ widget: WidgetDocument) -> Binding<DesktopPlacement.Level> {
        Binding(
            get: { widget.desktop?.level ?? .desktop },
            set: { value in
                store.updateWidget(id: widget.id) { $0.desktop?.level = value }
            }
        )
    }

    private func nameBinding(_ widget: WidgetDocument) -> Binding<String> {
        Binding(
            get: { widget.name },
            set: { value in
                store.updateWidget(id: widget.id) {
                    $0.name = WidgetLimits.truncated(value, to: WidgetLimits.nameLength)
                }
            }
        )
    }

    private func beginRenaming(_ widget: WidgetDocument) {
        selection = widget.id
        renaming = widget.id
        // Focus has to be set after the field exists, which is the next runloop
        // turn -- setting it in the same update simply does not take.
        DispatchQueue.main.async { renameFocus = widget.id }
    }

    private func finishRenaming(_ widget: WidgetDocument) {
        renaming = nil
        renameFocus = nil

        store.updateWidget(id: widget.id) { document in
            document.name = WidgetEditing.sanitisedName(document.name)
        }
    }

    private func enabled(_ widget: WidgetDocument) -> Binding<Bool> {
        Binding(
            get: { widget.isEnabled },
            set: { value in store.updateWidget(id: widget.id) { $0.isEnabled = value } }
        )
    }

    private func add() {
        let widget = WidgetDocument(
            name: String(localized: "New Widget", comment: "Name of a widget just added with the + button"),
            cells: []
        )
        store.edit { $0.widgets.append(widget) }
        selection = widget.id
        selectedCell = nil
        // Straight into renaming, the way a new folder in Finder behaves. The
        // placeholder name is never what anyone wants to keep.
        beginRenaming(widget)
    }

    private func duplicate(_ widget: WidgetDocument) {
        let copy = WidgetEditing.duplicate(widget)
        store.edit { $0.widgets.append(copy) }
        selection = copy.id
    }

    private func delete(_ widget: WidgetDocument) {
        store.edit { $0.widgets.removeAll { $0.id == widget.id } }
        if selection == widget.id { selection = store.document.widgets.first?.id }
        selectedCell = nil
    }
}

// MARK: - Live preview

private struct PreviewBar: View {
    let preview: StripPreview
    let density: Density

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(colorScheme == .dark ? Color(white: 0.13) : Color(white: 0.96))
                    .frame(height: 30)

                if let image = preview.image {
                    // Template images are tinted by the host; SwiftUI does the
                    // same job AppKit does in the real menu bar.
                    Image(nsImage: image)
                        .renderingMode(image.isTemplate ? .template : .original)
                        .foregroundStyle(colorScheme == .dark ? .white : .black)
                        .accessibilityLabel(Text("Preview"))
                        .accessibilityValue(Text(verbatim: preview.spokenDescription))
                } else {
                    Text("Nothing to show yet")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)

            if !preview.issues.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(preview.issues.map(\.summary).joined(separator: " \u{00B7} "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
    }
}

// MARK: - Cell strip

private struct CellStrip: View {
    let widget: WidgetDocument
    let metrics: [MetricDescriptor]
    @Binding var selection: UUID?
    let store: WidgetStore

    @State private var isAdding = false

    private var isFull: Bool { widget.cells.count >= WidgetLimits.cellsPerWidget }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(widget.cells) { cell in
                    CellChip(
                        cell: cell,
                        metrics: metrics,
                        isSelected: selection == cell.id
                    )
                    .onTapGesture { selection = cell.id }
                    .draggable(cell.id.uuidString)
                    .dropDestination(for: String.self) { items, _ in
                        move(items.first, before: cell.id)
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) { delete(cell) }
                    }
                }

                Button {
                    isAdding = true
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 26, height: 40)
                }
                .buttonStyle(.bordered)
                // The limit an import applies. Past it a widget could not be
                // shared, and would be wider than most menu bars anyway.
                .disabled(isFull)
                .help(isFull
                      ? Text("A widget can have at most \(WidgetLimits.cellsPerWidget) cells.")
                      : Text("Add a cell"))
                .popover(isPresented: $isAdding, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Layout pieces first: they need no metric, so they do
                        // not belong in a list of metrics.
                        HStack(spacing: 8) {
                            Button("Spacer") { addLayout(.spacer()) }
                            Button("Divider") { addLayout(.divider()) }
                        }
                        .padding(12)

                        Divider()

                        MetricPicker(metrics: metrics, title: "Add a cell") { descriptor in
                            add(descriptor)
                            isAdding = false
                        }
                    }
                    .frame(width: 320)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .scrollIndicators(.hidden)
    }

    private func move(_ draggedID: String?, before target: UUID) -> Bool {
        guard let draggedID, let dragged = UUID(uuidString: draggedID), dragged != target
        else { return false }

        store.updateWidget(id: widget.id) { document in
            _ = WidgetEditing.reorder(cells: &document.cells, moving: dragged, onto: target)
        }
        return true
    }

    private func addLayout(_ style: CellStyle) {
        let cell = CellDocument(style: style)
        store.updateWidget(id: widget.id) { $0.cells.append(cell) }
        selection = cell.id
        isAdding = false
    }

    private func add(_ descriptor: MetricDescriptor) {
        let cell = WidgetEditing.makeCell(for: descriptor)
        store.updateWidget(id: widget.id) { $0.cells.append(cell) }
        selection = cell.id
    }

    private func delete(_ cell: CellDocument) {
        store.updateWidget(id: widget.id) { $0.cells.removeAll { $0.id == cell.id } }
        if selection == cell.id { selection = nil }
    }
}

private struct CellChip: View {
    let cell: CellDocument
    let metrics: [MetricDescriptor]
    let isSelected: Bool

    private var descriptor: MetricDescriptor? {
        cell.metric.flatMap { id in metrics.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(cell.style.displayName)
                .font(.caption.weight(.medium))
            Text(descriptor?.displayName ?? cell.metric?.rawValue
                 ?? String(localized: "Layout", comment: "Cell chip: a spacer or divider, which shows no metric"))
                .font(.caption2)
                .foregroundStyle(descriptor == nil ? .orange : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 96, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
        }
    }
}
