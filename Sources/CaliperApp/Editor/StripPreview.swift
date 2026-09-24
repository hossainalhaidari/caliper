import AppKit
import LayoutEngine
import MetricBus
import Observation
import RenderKit
import SchemaKit
import SensorKit

/// Renders a widget with live data for the editor.
///
/// Deliberately drives the real `StripComposer` rather than redrawing the strip
/// in SwiftUI shapes. A preview that is a second implementation is a preview
/// that can drift, and the moment it drifts it is worse than useless -- it
/// becomes a confident lie about what the menu bar will look like.
///
/// It subscribes only while the editor window is open, so having the editor
/// closed costs nothing.
@MainActor
@Observable
final class StripPreview {
    private(set) var image: NSImage?
    /// What VoiceOver says of the preview: the same words as the real strip.
    private(set) var spokenDescription = ""
    private(set) var issues: [ResolutionIssue] = []

    private let bus: MetricBus
    private let composer = StripComposer()
    private var subscription: MetricBus.Subscription?
    private var observer: UUID?
    private var widget: Widget?
    private var descriptors: [MetricID: MetricDescriptor] = [:]
    private var density: Density = .regular
    private var isRunning = false

    init(bus: MetricBus) {
        self.bus = bus
        for descriptor in bus.availableMetrics() { descriptors[descriptor.id] = descriptor }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        observer = bus.observe { [weak self] snapshot in
            MainActor.assumeIsolated { self?.render(values: snapshot.values) }
        }
        resubscribe()
    }

    func stop() {
        isRunning = false
        subscription?.cancel()
        subscription = nil
        if let observer { bus.removeObserver(observer) }
        observer = nil
    }

    func update(document: WidgetDocument, density: Density) {
        for descriptor in bus.availableMetrics() { descriptors[descriptor.id] = descriptor }

        let resolution = document.resolve(
            in: ResolutionContext(
                descriptors: descriptors,
                coreGroups: CPUCoreSource().clusters.map(\.indices.count)
            )
        )

        self.widget = resolution.widget
        self.issues = resolution.issues
        self.density = density

        composer.invalidate()
        resubscribe()
        render(values: currentValues())
    }

    private func resubscribe() {
        subscription?.cancel()
        guard isRunning, let widget, !widget.requiredMetrics.isEmpty else {
            subscription = nil
            return
        }
        subscription = bus.subscribe(to: widget.requiredMetrics)
        // Without this the preview sits blank for a tick every time a cell is
        // added, which in an editor reads as "the thing I just made is broken".
        bus.sampleNow()
    }

    private func currentValues() -> [MetricID: Double] {
        guard let widget else { return [:] }
        var values: [MetricID: Double] = [:]
        for metric in widget.requiredMetrics { values[metric] = bus.value(for: metric) }
        return values
    }

    private func render(values: [MetricID: Double]) {
        guard let widget, !widget.cells.isEmpty else {
            image = nil
            return
        }

        var histories: [MetricID: [Float]] = [:]
        for cell in widget.cells where cell.historyDepth > 0 {
            guard let metric = cell.metric else { continue }
            histories[metric] = bus.history(for: metric, count: cell.historyDepth)
        }

        let frame = StripComposer.Frame(
            values: values,
            histories: histories,
            descriptors: descriptors
        )

        if let fresh = composer.compose(widget, frame: frame, context: RenderContext(density: density)) {
            image = fresh
            spokenDescription = composer.spokenDescription
        }
    }
}
