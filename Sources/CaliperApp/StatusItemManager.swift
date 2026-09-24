import AppKit
import LayoutEngine
import MetricBus
import Observation
import RenderKit
import SchemaKit
import SensorKit

/// Keeps the menu bar in step with the stored layout.
///
/// One `NSStatusItem` per enabled widget, so macOS lets each be dragged to its
/// own position -- CPU on the left, network by the clock. A single combined item
/// would be simpler to manage and would take that away, since macOS can only
/// move whole items.
@MainActor
final class StatusItemManager {
    private let bus: MetricBus
    private let store: WidgetStore
    private let updates: UpdateService?
    private(set) var controllers: [UUID: StatusItemController] = [:]

    var onEditRequested: (() -> Void)?

    init(bus: MetricBus, store: WidgetStore, updates: UpdateService? = nil) {
        self.bus = bus
        self.store = store
        self.updates = updates
    }

    func start() {
        sync()
        observeStore()
    }

    /// Rebuilds the resolution context from scratch.
    ///
    /// Cheap, and it has to be current: an external drive mounted a moment ago
    /// adds metrics, and a widget referencing them should start working without
    /// a relaunch.
    private func context() -> ResolutionContext {
        ResolutionContext(
            descriptors: bus.availableMetrics(),
            coreGroups: CPUCoreSource().clusters.map(\.indices.count)
        )
    }

    private func sync() {
        let context = context()
        // A widget lives on one surface: given a desktop placement it is a
        // panel, otherwise it is a status item. `isEnabled` says whether it is
        // shown at all, which is a separate question from where.
        let enabled = store.document.widgets.filter { $0.isEnabled && $0.desktop == nil }
        let wanted = Set(enabled.map(\.id))

        for (id, controller) in controllers where !wanted.contains(id) {
            controller.remove()
            controllers[id] = nil
        }

        for document in enabled {
            let resolution = document.resolve(in: context)

            if let existing = controllers[document.id] {
                existing.setWidget(resolution.widget)
                existing.setDensity(store.document.density)
                continue
            }

            let controller = StatusItemController(
                bus: bus,
                widget: resolution.widget,
                density: store.document.density,
                updates: updates
            )
            controller.onEditRequested = { [weak self] in self?.onEditRequested?() }
            controllers[document.id] = controller
        }
    }

    /// Re-arms after every change, because observation tracking fires once.
    private func observeStore() {
        withObservationTracking {
            _ = store.revision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.sync()
                self?.observeStore()
            }
        }
    }

    /// Diagnostics only.
    func openPanelForDiagnostics() {
        controllers.values.first?.openPanelForDiagnostics()
    }

    func dumpLivePanel(to path: String) -> (ok: Bool, geometry: String) {
        controllers.values.first?.dumpLivePanel(to: path) ?? (false, "no status item")
    }

    /// Diagnostics only.
    func dumpPanel(group: String, to path: String) -> Bool {
        controllers.values.first?.dumpPanel(group: group, to: path) ?? false
    }

    /// Called when hardware appears or disappears, so widgets bound to metrics
    /// that just became available start resolving.
    func refresh() {
        sync()
    }
}
