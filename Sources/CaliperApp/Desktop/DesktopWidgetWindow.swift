import AppKit
import LayoutEngine
import MetricBus
import RenderKit
import SchemaKit
import SensorKit

/// Draws a widget's strip at desktop size.
final class DesktopWidgetView: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { false }

    // One image, so one element: named after the widget, its value the readings
    // the strip shows. Without these VoiceOver skips the panel entirely.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let origin = NSPoint(
            x: (bounds.width - image.size.width) / 2,
            y: (bounds.height - image.size.height) / 2
        )

        // Template images carry no colour of their own, so on the desktop -- where
        // there is no menu bar to inherit from -- they are tinted explicitly
        // against the panel's own material.
        guard image.isTemplate else {
            image.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            return
        }
        NSColor.labelColor.set()
        let rect = NSRect(origin: origin, size: image.size)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        rect.fill(using: .sourceAtop)
    }
}

/// A floating panel showing one widget on the desktop.
///
/// A borderless `NSPanel` rather than a WidgetKit widget, because WidgetKit is
/// timeline-based and budgeted -- it cannot update every second, and its
/// extension is sandboxed away from the private sensor interfaces M5 depends on.
/// A live CPU graph is simply not something that API can express.
///
/// Drawn with the same `StripComposer` as the menu bar, so a widget looks the
/// same in both places and there is no second renderer to keep in step.
@MainActor
final class DesktopWidgetWindow: NSObject {
    private let panel: NSPanel
    private let view = DesktopWidgetView()
    private let composer = StripComposer()
    private let bus: MetricBus

    private var subscription: MetricBus.Subscription?
    private var observer: UUID?
    private var widget: Widget?
    private var descriptors: [MetricID: MetricDescriptor] = [:]
    private var placement: DesktopPlacement
    /// Until the panel has been sized and placed, `didMove` notifications are
    /// AppKit settling the window rather than the user dragging it, and writing
    /// them back would overwrite the stored position with an arbitrary one.
    private var hasPositioned = false

    /// Called after the user drags the panel, so the new position is saved.
    var onMove: ((CGPoint) -> Void)?

    /// Whether any of the panel can be seen: a desktop widget is covered by
    /// windows for most of the day, and absent from a full-screen Space.
    private(set) var occlusion: OcclusionWatcher?

    /// Hidden for long enough that sampling for it has stopped.
    var isSuspended: Bool { occlusion?.isVisible == false }

    init(
        bus: MetricBus,
        placement: DesktopPlacement,
        occlusionGrace: Duration = OcclusionWatcher.defaultGrace
    ) {
        self.bus = bus
        self.placement = placement

        panel = NSPanel(
            contentRect: NSRect(x: placement.x, y: placement.y, width: 200, height: placement.height + 16),
            // Non-activating: clicking the widget must not pull the app forward
            // and steal focus from whatever you were actually doing.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        // Present on every Space, and not something the window manager should
        // cycle to or hide when the app is hidden.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false

        let material = NSVisualEffectView()
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 10
        material.layer?.masksToBounds = true

        material.addSubview(view)
        panel.contentView = material

        apply(level: placement.level)

        for descriptor in bus.availableMetrics() { descriptors[descriptor.id] = descriptor }

        // Unlike a status item, a panel is a real window on one display, so its
        // occlusion is the whole truth about whether it can be seen.
        let panel = self.panel
        let watcher = OcclusionWatcher(grace: occlusionGrace, window: { panel.isVisible ? panel : nil })
        watcher.onChange = { [weak self] visible in self?.setSuspended(!visible) }
        occlusion = watcher

        NotificationCenter.default.addObserver(
            self, selector: #selector(panelMoved),
            name: NSWindow.didMoveNotification, object: panel
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func show() {
        panel.orderFront(nil)
        observer = bus.observe { [weak self] snapshot in
            MainActor.assumeIsolated {
                guard let self, !self.isSuspended else { return }
                self.render(values: snapshot.values)
            }
        }
        bus.sampleNow()
        // A panel shown already covered never changes state, so ask once.
        Task { @MainActor [weak occlusion] in occlusion?.evaluate() }
    }

    func close() {
        // As `StatusItemController.remove`: nothing may resubscribe it now.
        occlusion?.onChange = nil
        occlusion = nil
        subscription?.cancel()
        subscription = nil
        if let observer { bus.removeObserver(observer) }
        observer = nil
        panel.orderOut(nil)
    }

    func update(widget: Widget, placement: DesktopPlacement) {
        self.widget = widget
        if placement.level != self.placement.level { apply(level: placement.level) }
        self.placement = placement

        subscription?.cancel()
        subscription = nil
        // Redrawn even while suspended, once, so the panel has its new size.
        if !isSuspended { subscribe() }
        composer.invalidate()
        render(values: currentValues())
    }

    private func subscribe() {
        guard let widget else { return }
        subscription?.cancel()
        subscription = bus.subscribe(to: widget.requiredMetrics)
        bus.sampleNow()
    }

    /// As `StatusItemController.setSuspended`: the subscription goes, so the
    /// hardware behind these cells stops being read, and comes back with a
    /// fresh reading the moment any of the panel is uncovered.
    private func setSuspended(_ suspended: Bool) {
        if suspended {
            subscription?.cancel()
            subscription = nil
        } else {
            subscribe()
        }
    }

    private func apply(level: DesktopPlacement.Level) {
        // The choice itself lives on the model, where it is covered by a test --
        // see `DesktopPlacement.Level.windowLevel` for why "desktop" is not the
        // desktop level.
        panel.level = NSWindow.Level(rawValue: level.windowLevel)
    }

    @objc private func panelMoved() {
        guard hasPositioned else { return }
        onMove?(CGPoint(x: panel.frame.minX, y: panel.frame.minY))
    }

    /// Puts the panel where the document says, clamped to a screen that exists.
    ///
    /// A position saved while an external display was attached is off-screen
    /// once it is unplugged, and an invisible widget is indistinguishable from a
    /// broken one. Clamping to the visible frame means the worst case is a
    /// widget in the wrong corner rather than a widget nobody can find.
    private func positionIfNeeded() {
        guard !hasPositioned else { return }

        var origin = CGPoint(x: placement.x, y: placement.y)
        let size = panel.frame.size
        let screens = NSScreen.screens.map(\.visibleFrame)
        let target = NSRect(origin: origin, size: size)

        if !screens.contains(where: { $0.intersects(target) }) {
            let fallback = NSScreen.main?.visibleFrame ?? .zero
            origin = CGPoint(x: fallback.minX + 40, y: fallback.maxY - size.height - 40)
        }

        panel.setFrameOrigin(origin)
        hasPositioned = true

        // Save the clamped position, so a widget rescued from a vanished display
        // stays where it was rescued to.
        if origin.x != placement.x || origin.y != placement.y {
            onMove?(origin)
        }
    }

    private func currentValues() -> [MetricID: Double] {
        guard let widget else { return [:] }
        var values: [MetricID: Double] = [:]
        for metric in widget.requiredMetrics { values[metric] = bus.value(for: metric) }
        return values
    }

    private func render(values: [MetricID: Double]) {
        guard let widget, !widget.cells.isEmpty else { return }

        var histories: [MetricID: [Float]] = [:]
        for cell in widget.cells where cell.historyDepth > 0 {
            guard let metric = cell.metric else { continue }
            histories[metric] = bus.history(for: metric, count: cell.historyDepth)
        }

        let height = CGFloat(placement.height)
        let context = RenderContext(
            density: .roomy,
            scale: panel.backingScaleFactor,
            height: height,
            // Scaled from the drawing height rather than the density preset, so
            // the type grows with the widget instead of staying menu-bar sized.
            font: .monospacedDigitSystemFont(ofSize: (height * 0.42).rounded(), weight: .regular)
        )

        let frame = StripComposer.Frame(values: values, histories: histories, descriptors: descriptors)
        guard let image = composer.compose(widget, frame: frame, context: context) else { return }

        view.image = image
        view.setAccessibilityLabel(widget.name)
        view.setAccessibilityValue(composer.spokenDescription)

        let size = NSSize(width: image.size.width + 24, height: image.size.height + 16)
        if panel.frame.size != size {
            panel.setContentSize(size)
            view.frame = NSRect(origin: .zero, size: size)
        }
        // After sizing, never before: the origin is meaningless until the panel
        // knows how big it is.
        positionIfNeeded()
    }
}
