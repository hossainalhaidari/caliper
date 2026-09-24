import AppKit
import MetricBus
import Observation
import SchemaKit
import SensorKit

/// Keeps desktop panels in step with the stored layout.
///
/// The same shape as `StatusItemManager`, and for the same reason: the document
/// is the source of truth, and every surface derives from it. A widget shown in
/// both places is one definition rendered twice, so they cannot drift.
@MainActor
final class DesktopWidgetManager {
    private let bus: MetricBus
    private let store: WidgetStore
    private(set) var windows: [UUID: DesktopWidgetWindow] = [:]

    init(bus: MetricBus, store: WidgetStore) {
        self.bus = bus
        self.store = store
    }

    func start() {
        sync()
        observeStore()
    }

    private func context() -> ResolutionContext {
        ResolutionContext(
            descriptors: bus.availableMetrics(),
            coreGroups: CPUCoreSource().clusters.map(\.indices.count)
        )
    }

    private func sync() {
        let context = context()
        // Hidden means hidden here too. Dropping the placement instead would
        // work, but it would throw away where the panel sits, so showing it
        // again would put it back at the default corner rather than where it
        // was left.
        let placed = store.document.widgets.filter { $0.desktop != nil && $0.isEnabled }
        let wanted = Set(placed.map(\.id))

        for (id, window) in windows where !wanted.contains(id) {
            window.close()
            windows[id] = nil
        }

        for document in placed {
            guard let placement = document.desktop else { continue }
            let widget = document.resolve(in: context).widget

            if let existing = windows[document.id] {
                existing.update(widget: widget, placement: placement)
                continue
            }

            let window = DesktopWidgetWindow(bus: bus, placement: placement)
            // Dragging writes the position straight back to the document, so it
            // survives a relaunch without a separate "save position" step.
            window.onMove = { [weak self] origin in
                self?.store.updateWidget(id: document.id) { widget in
                    widget.desktop?.x = origin.x
                    widget.desktop?.y = origin.y
                }
            }
            window.update(widget: widget, placement: placement)
            window.show()
            windows[document.id] = window
        }
    }

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
}
