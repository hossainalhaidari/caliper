import AppKit
import Foundation
import LayoutEngine
import MetricBus
import RenderKit
import SchemaKit
import SensorKit
@testable import CaliperApp

/// A source that says whether the bus is currently reading it.
///
/// Whether hardware is being read is the thing the app layer's plumbing
/// exists to decide -- a hidden strip stops it, an alert keeps it going -- and
/// activation is where that decision becomes visible.
final class ProbeSource: MetricSource, @unchecked Sendable {
    static let metric: MetricID = "probe.value"

    private let lock = NSLock()
    private var _isActive = false
    private var _activations = 0

    var isActive: Bool { lock.withLock { _isActive } }
    var activations: Int { lock.withLock { _activations } }

    var cadence: Cadence { .live }

    var descriptors: [MetricDescriptor] {
        [MetricDescriptor(id: Self.metric, displayName: "Probe", group: "Test", unit: .percent, range: .percentage)]
    }

    func activate() {
        lock.withLock {
            _isActive = true
            _activations += 1
        }
    }

    func deactivate() { lock.withLock { _isActive = false } }

    func sample(into sink: inout SampleSink, context: SampleContext) {
        sink.emit(Self.metric, 42)
    }
}

/// A bus with only the probe on it, never started: the tests drive it by
/// subscribing, which is what activates a source.
func probeBus() -> (MetricBus, ProbeSource) {
    let bus = MetricBus()
    let probe = ProbeSource()
    bus.register(probe)
    return (bus, probe)
}

/// A widget of one text cell showing the probe.
func probeWidget(name: String = "Probe") -> Widget {
    Widget(name: name, cells: [
        Cell(metric: ProbeSource.metric, renderer: TextValueRenderer(), label: "P"),
    ])
}

/// The same, as a document, with thresholds when asked for.
func probeDocument(
    name: String = "Probe",
    thresholds: Thresholds? = nil,
    isEnabled: Bool = true,
    desktop: DesktopPlacement? = nil
) -> WidgetDocument {
    WidgetDocument(
        name: name,
        cells: [CellDocument(metric: ProbeSource.metric, style: .text(), label: "P", thresholds: thresholds)],
        isEnabled: isEnabled,
        desktop: desktop
    )
}

/// A store in a directory of its own, so no test reads or writes the real
/// `~/Library/Application Support` layout.
@MainActor
func temporaryStore(_ widgets: [WidgetDocument]) -> WidgetStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CaliperAppTests-\(UUID().uuidString)", isDirectory: true)
    let store = WidgetStore(url: directory.appendingPathComponent("layout.json"))
    store.edit { $0.widgets = widgets }
    return store
}

/// A window a test can show and hide at will, for an `OcclusionWatcher` to read.
///
/// Every watcher re-reads its window on every occlusion change in the process --
/// including other tests' windows -- so a test cannot simply tell one it is
/// hidden. It has to make the window it reads *be* hidden.
@MainActor
final class StandInWindow {
    /// Never ordered in, so no pixel of it is ever visible.
    private let hidden = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 40, height: 20),
        styleMask: .borderless, backing: .buffered, defer: true
    )

    var isShowing = true

    /// No window reads as visible: nothing says otherwise.
    var window: NSWindow? { isShowing ? nil : hidden }

    /// Shows or hides it, and has `watcher` look.
    func set(showing: Bool, for watcher: OcclusionWatcher) {
        isShowing = showing
        watcher.window = { [unowned self] in self.window }
        watcher.evaluate()
    }
}

/// Waits for something that happens on another queue or a later turn of the
/// main actor -- a subscription released on the bus's queue, an observation
/// that fires in a `Task`. Polling with a deadline rather than sleeping a fixed
/// time: a loaded CI runner is slow, and a fixed sleep is either flaky or slow
/// everywhere.
@MainActor
func eventually(within timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}
