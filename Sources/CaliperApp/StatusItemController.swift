import AppKit
import LayoutEngine
import MetricBus
import RenderKit
import SensorKit

/// Owns one menu bar item and keeps its image in sync with the bus.
@MainActor
final class StatusItemController: NSObject {
    let statusItem: NSStatusItem
    private let composer = StripComposer()
    private let bus: MetricBus
    private var subscription: MetricBus.Subscription?
    private var observerToken: UUID?

    private var widget: Widget
    private var descriptors: [MetricID: MetricDescriptor] = [:]
    private var context: RenderContext

    /// The dropdown only refreshes while it is actually on screen. An open menu
    /// is the one time per-tick UI work is worth doing; a closed one is the
    /// other 99.9% of the time.
    /// Named `detailPanel` rather than `panel`: AppKit already has selectors by
    /// that name reachable from `NSObject`, and the collision produces errors
    /// pointing at the call sites rather than at the property.
    private let detailPanel: DetailPanelController
    private(set) var contextMenu: NSMenu?
    private var appearanceObservation: NSKeyValueObservation?

    private var detailSubscription: MetricBus.Subscription?

    /// Invoked when the user picks Edit Widgets. Set by the manager rather than
    /// wired to a global, so a controller has no opinion about who owns windows.
    var onEditRequested: (() -> Void)?

    /// Shared with every other status item: one updater for the app, whatever
    /// number of items are in the menu bar. The update items are hidden when it
    /// is missing or not `isAvailable` -- a development build, which has no feed.
    private let updates: UpdateService?

    private var loginItem: NSMenuItem?
    private var updateItem: NSMenuItem?
    private var automaticUpdateItem: NSMenuItem?

    /// Whether anyone can see this item. Set once, after `super.init`, because
    /// it reads the status item's window.
    private(set) var occlusion: OcclusionWatcher?

    /// Hidden for long enough that sampling for it has stopped.
    var isSuspended: Bool { occlusion?.isVisible == false }

    init(
        bus: MetricBus,
        widget: Widget,
        density: Density = .regular,
        updates: UpdateService? = nil,
        occlusionGrace: Duration = OcclusionWatcher.defaultGrace
    ) {
        self.bus = bus
        self.widget = widget
        self.updates = updates
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.context = RenderContext(density: density)
        self.detailPanel = DetailPanelController(bus: bus)
        super.init()

        for descriptor in bus.availableMetrics() {
            descriptors[descriptor.id] = descriptor
        }

        let item = statusItem
        let watcher = OcclusionWatcher(
            grace: occlusionGrace,
            window: { item.button?.window },
            canBeHidden: { Self.hasOneMenuBar }
        )
        watcher.onChange = { [weak self] visible in self?.setSuspended(!visible) }
        occlusion = watcher
        // Once the item is in the menu bar. An item that arrives already behind
        // the notch never changes state, so no notification would ever say so.
        Task { @MainActor [weak watcher] in watcher?.evaluate() }

        buildMenu()
        applyAccessibilityLabel()
        // Reserve the item's width immediately so it does not visibly jump from
        // nothing to full size a second after launch.
        render(values: [:])

        subscribe()
        observerToken = bus.observe { [weak self] snapshot in
            MainActor.assumeIsolated {
                self?.apply(snapshot)
            }
        }

        // Template images survive appearance changes on their own, but a strip
        // in the alerting (coloured) state resolves `labelColor` at draw time
        // and would otherwise keep yesterday's colour until its value moved.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.composer.invalidate()
                self?.refreshScale()
            }
        }
    }

    deinit {
        // Nonisolated cleanup: both are plain value/reference handles.
        subscription?.cancel()
    }

    /// Diagnostics only: opens the panel for real, then reports and captures it.
    func openPanelForDiagnostics() {
        guard let button = statusItem.button else { return }
        detailPanel.show(relativeTo: button, metric: widget.cells.first?.metric)
    }

    func dumpLivePanel(to path: String) -> (ok: Bool, geometry: String) {
        (detailPanel.dumpLive(to: path), detailPanel.liveGeometry)
    }

    /// Diagnostics only: renders the detail panel offscreen.
    func dumpPanel(group: String, to path: String) -> Bool {
        detailPanel.dump(group: group, to: path)
    }

    /// Points this item at a different widget, as the editor produces one.
    ///
    /// Re-subscribing rather than rebuilding the controller keeps the item's
    /// position in the menu bar. macOS assigns that when a status item is
    /// created and remembers it per item, so tearing one down and making a new
    /// one on every keystroke in the editor would make the user's carefully
    /// arranged menu bar jump around while they typed.
    func setWidget(_ widget: Widget) {
        self.widget = widget
        applyAccessibilityLabel()
        // Still redrawn below while suspended, once, so the item has the right
        // width the moment it comes back into view.
        if !isSuspended { subscribe() }
        composer.invalidate()
        render(values: currentValues())
    }

    func setDensity(_ density: Density) {
        guard density != context.density else { return }
        context = RenderContext(density: density, scale: context.scale)
        composer.invalidate()
        render(values: currentValues())
    }

    /// Removes the item from the menu bar. Without this the item lingers until
    /// the controller is deallocated, which is not deterministic enough when a
    /// widget is deleted in the editor.
    func remove() {
        // First, so a late occlusion change cannot subscribe a removed item
        // again. The callback too: a pending check may still hold the watcher.
        occlusion?.onChange = nil
        occlusion = nil
        subscription?.cancel()
        subscription = nil
        if let observerToken { bus.removeObserver(observerToken) }
        observerToken = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// The widget's name, which is how its owner tells one status item from
    /// the next, and a hint at what the two clicks do.
    private func applyAccessibilityLabel() {
        guard let button = statusItem.button else { return }
        button.setAccessibilityLabel(widget.name)
        button.setAccessibilityHelp(String(
            localized: "Click for details. Control-click for more options.",
            comment: "VoiceOver hint on a menu bar item"))
    }

    private func subscribe() {
        subscription?.cancel()
        subscription = bus.subscribe(to: widget.requiredMetrics)
        // Delta-based sources have just been re-primed, so ask for a reading
        // rather than leaving the new cells blank until the next tick.
        bus.sampleNow()
    }

    // MARK: - Out of sight

    /// Whether a hidden window means a hidden item.
    ///
    /// macOS shows status items in the menu bar of every display, but an item
    /// has one window, on the display whose menu bar is active; the others
    /// show a copy of it. With more than one menu bar, a full-screen film on
    /// one display hides that window while the copy next door is in plain
    /// view, and suspending would freeze a strip somebody may be reading. So
    /// only a Mac with one menu bar -- which is most laptops on battery, the
    /// case this is for -- suspends.
    private static var hasOneMenuBar: Bool {
        NSScreen.screens.count <= 1 || !NSScreen.screensHaveSeparateSpaces
    }

    /// Stops sampling for this item while nobody can see it, and starts again
    /// the moment somebody can.
    ///
    /// The subscription is what makes the bus read hardware for these cells,
    /// so dropping it stops the sampling as well as the drawing; the bus's
    /// timer keeps ticking, but a tick with no subscribers reads nothing.
    /// Alerts hold their own subscription, so a threshold breached during a
    /// film is still noticed. The image is left as it was: nobody can see it,
    /// and the reading `subscribe` asks for replaces it on the way back.
    private func setSuspended(_ suspended: Bool) {
        if suspended {
            subscription?.cancel()
            subscription = nil
        } else {
            subscribe()
        }
    }

    // MARK: - Updating

    private func apply(_ snapshot: Snapshot) {
        // Other surfaces' readings still arrive while this one is suspended.
        guard !isSuspended else { return }
        render(values: snapshot.values)
    }

    private func render(values: [MetricID: Double]) {
        refreshScale()

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

        // Dynamic colours -- `labelColor` above all -- resolve against whatever
        // appearance is current at the moment the CTLine is built, and this
        // runs from a bus callback rather than inside a draw cycle, so nothing
        // has established one. Left alone it silently resolves to the wrong
        // side of light/dark, which is invisible until a cell alerts and the
        // strip stops being a template: then the nominal cells are drawn white
        // on a white menu bar.
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        var rendered: NSImage?
        appearance.performAsCurrentDrawingAppearance {
            rendered = composer.compose(widget, frame: frame, context: context)
        }

        // nil means "visually identical to what is already up there".
        guard let rendered else { return }
        statusItem.button?.image = rendered
        // The strip is one image, so this is the only way VoiceOver learns what
        // it shows. The name was set with the widget; the readings change here.
        statusItem.button?.setAccessibilityValue(composer.spokenDescription)
    }

    private func refreshScale() {
        // Never assume 2.0. Dragging the window to a 1x external display or a
        // Pro Display changes this, and rendering at the wrong scale is
        // immediately visible as blur.
        guard let scale = statusItem.button?.window?.backingScaleFactor,
              scale != context.scale else { return }
        context.scale = scale
        composer.invalidate()
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()

        let edit = NSMenuItem(
            title: String(localized: "Edit Widgets\u{2026}", comment: "Menu item: open the widget editor"),
            action: #selector(requestEdit),
            keyEquivalent: ","
        )
        edit.target = self
        menu.addItem(edit)

        if LoginItem.isSupported {
            menu.addItem(.separator())

            let login = NSMenuItem(
                title: String(localized: "Launch at Login", comment: "Menu item: start Caliper when you log in"),
                action: #selector(toggleLaunchAtLogin),
                keyEquivalent: ""
            )
            login.target = self
            menu.addItem(login)
            loginItem = login
        }

        if updates?.isAvailable == true {
            menu.addItem(.separator())

            let check = NSMenuItem(
                title: String(localized: "Check for Updates\u{2026}", comment: "Menu item: look for a new version now"),
                action: #selector(actOnUpdates),
                keyEquivalent: ""
            )
            check.target = self
            menu.addItem(check)
            updateItem = check

            // A checkmark rather than a settings window. This is the only thing
            // in the app that touches the network, so the switch for it belongs
            // where someone would look for it -- next to the thing it governs.
            let automatic = NSMenuItem(
                title: String(localized: "Check Automatically", comment: "Menu item: look for a new version once a day"),
                action: #selector(toggleAutomaticUpdates),
                keyEquivalent: ""
            )
            automatic.target = self
            menu.addItem(automatic)
            automaticUpdateItem = automatic
        }

        menu.addItem(.separator())

        let about = NSMenuItem(
            title: String(localized: "About Caliper", comment: "Menu item: open the About window"),
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(
            title: String(localized: "Quit Caliper", comment: "Menu item: quit this app"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)

        contextMenu = menu

        // Deliberately not `statusItem.menu`. Assigning a menu makes every click
        // open it, and then a left click can never do anything else. Handling
        // the click directly is what lets the panel know *which cell* was hit.
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func handleClick() {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent

        let wantsMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if wantsMenu {
            detailPanel.close()
            refreshMenuState()
            if let contextMenu {
                contextMenu.popUp(
                    positioning: nil,
                    at: NSPoint(x: 0, y: button.bounds.height + 4),
                    in: button
                )
            }
            return
        }

        // A second click closes it, which is what every other menu bar item does.
        guard !detailPanel.isOpen else {
            detailPanel.close()
            return
        }

        detailPanel.show(relativeTo: button, metric: metricUnderPointer(in: button, event: event))
    }

    /// Which cell the pointer was over, translated to the metric it shows.
    ///
    /// The status item is one image, so this is the only way to know what was
    /// clicked -- and without it the panel could only ever show everything,
    /// which is precisely the dense-table design it exists to avoid.
    private func metricUnderPointer(in button: NSStatusBarButton, event: NSEvent?) -> MetricID? {
        guard let event else { return widget.cells.first?.metric }
        let point = button.convert(event.locationInWindow, from: nil)

        // The image is centred in the button, so strip coordinates are offset by
        // however much padding AppKit added around it.
        let imageWidth = button.image?.size.width ?? button.bounds.width
        let inset = (button.bounds.width - imageWidth) / 2
        let stripPoint = CGPoint(x: point.x - inset, y: point.y)

        guard let index = composer.cellIndex(at: stripPoint), widget.cells.indices.contains(index)
        else { return widget.cells.first?.metric }
        return widget.cells[index].metric
    }

    @objc private func requestEdit() {
        onEditRequested?()
    }

    /// Read as the menu opens rather than kept in step: a menu nobody is looking
    /// at has no state worth maintaining, and this is the moment it becomes
    /// visible. Both switches belong to someone else -- the login item to
    /// macOS, the update check to Sparkle -- and either can change behind the
    /// app's back.
    private func refreshMenuState() {
        loginItem?.state = LoginItem.isEnabled ? .on : .off

        guard let updates, updates.isAvailable else { return }
        if let version = updates.waitingVersion {
            updateItem?.title = String(
                localized: "Update to \(version)\u{2026}",
                comment: "Menu item: an update has been found. The argument is its version, such as 0.2.0")
        } else {
            updateItem?.title = String(
                localized: "Check for Updates\u{2026}", comment: "Menu item: look for a new version now")
        }
        automaticUpdateItem?.state = updates.checksAutomatically ? .on : .off
    }

    @objc private func showAbout() {
        AboutPanel.show()
    }

    @objc private func toggleLaunchAtLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    @objc private func actOnUpdates() {
        updates?.checkForUpdates()
    }

    @objc private func toggleAutomaticUpdates() {
        guard let updates else { return }
        updates.setChecksAutomatically(!updates.checksAutomatically)
    }

    /// Latest values for everything the strip shows, for a redraw outside the
    /// normal snapshot flow.
    private func currentValues() -> [MetricID: Double] {
        var values: [MetricID: Double] = [:]
        for metric in widget.requiredMetrics {
            values[metric] = bus.value(for: metric)
        }
        return values
    }
}
