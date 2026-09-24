import AppKit
import RenderKit
import SchemaKit
import SensorKit
import Testing
@testable import CaliperApp

@MainActor
@Suite("Status items")
struct StatusItemTests {

    @Test("the menu has what the docs promise, and no update items without a feed")
    func menu() throws {
        let (bus, _) = probeBus()
        let controller = StatusItemController(bus: bus, widget: probeWidget(), updates: UpdateService(info: [:]))
        defer { controller.remove() }

        let titles = try #require(controller.contextMenu).items.filter { !$0.isSeparatorItem }.map(\.title)
        var expected = ["Edit Widgets\u{2026}"]
        if LoginItem.isSupported { expected.append("Launch at Login") }
        expected += ["About Caliper", "Quit Caliper"]
        #expect(titles == expected)
        // A development build has no feed; offering a check it cannot make
        // would put up Sparkle's misconfiguration alert.
        #expect(!titles.contains("Check for Updates\u{2026}"))
    }

    @Test("every item carries a keyboard route to quit and edit")
    func keyEquivalents() throws {
        let (bus, _) = probeBus()
        let controller = StatusItemController(bus: bus, widget: probeWidget(), updates: UpdateService(info: [:]))
        defer { controller.remove() }

        let items = try #require(controller.contextMenu).items
        #expect(items.first { $0.title == "Quit Caliper" }?.keyEquivalent == "q")
        #expect(items.first { $0.title == "Edit Widgets\u{2026}" }?.keyEquivalent == ",")
    }

    @Test("VoiceOver hears the widget's name, and the new one after an edit")
    func accessibilityLabel() throws {
        let (bus, _) = probeBus()
        let controller = StatusItemController(bus: bus, widget: probeWidget(name: "Probe"), updates: UpdateService(info: [:]))
        defer { controller.remove() }
        let button = try #require(controller.statusItem.button)

        #expect(button.accessibilityLabel() == "Probe")
        controller.setWidget(probeWidget(name: "Renamed"))
        #expect(button.accessibilityLabel() == "Renamed")
        // Reserved width from the first frame, before any reading arrives.
        #expect(button.image != nil)
    }

    @Test("one item per enabled menu bar widget, kept in step with the store")
    func managerFollowsTheStore() async {
        let (bus, _) = probeBus()
        let shown = probeDocument(name: "Shown")
        let hidden = probeDocument(name: "Hidden", isEnabled: false)
        let onDesktop = probeDocument(name: "Desk", desktop: DesktopPlacement())
        let store = temporaryStore([shown, hidden, onDesktop])

        let manager = StatusItemManager(bus: bus, store: store)
        manager.start()
        #expect(Set(manager.controllers.keys) == [shown.id])

        store.updateWidget(id: hidden.id) { $0.isEnabled = true }
        #expect(await eventually { Set(manager.controllers.keys) == [shown.id, hidden.id] })

        // An item kept, not rebuilt: macOS remembers where the user put it.
        let kept = manager.controllers[shown.id]
        store.updateWidget(id: shown.id) { $0.name = "Still Shown" }
        #expect(await eventually { manager.controllers[shown.id]?.statusItem.button?.accessibilityLabel() == "Still Shown" })
        #expect(manager.controllers[shown.id] === kept)

        store.edit { $0.widgets = [] }
        #expect(await eventually { manager.controllers.isEmpty })
    }

    @Test("desktop widgets get a window each, and lose it when hidden")
    func desktopManagerFollowsTheStore() async {
        let (bus, _) = probeBus()
        let placed = probeDocument(name: "Desk", desktop: DesktopPlacement())
        let store = temporaryStore([placed, probeDocument(name: "Bar")])

        let manager = DesktopWidgetManager(bus: bus, store: store)
        manager.start()
        #expect(Set(manager.windows.keys) == [placed.id])

        store.updateWidget(id: placed.id) { $0.isEnabled = false }
        #expect(await eventually { manager.windows.isEmpty })
    }
}

@MainActor
@Suite("Alerts")
struct AlertMonitorTests {

    @Test("a metric watched twice gets one tracker, with the tighter thresholds")
    func tighterThresholdsWin() {
        let (bus, probe) = probeBus()
        let store = temporaryStore([
            probeDocument(name: "A", thresholds: Thresholds(elevated: 60, critical: 95)),
            probeDocument(name: "B", thresholds: Thresholds(elevated: 70, critical: 90)),
        ])
        let monitor = AlertMonitor(bus: bus, store: store)
        monitor.start()

        #expect(monitor.thresholds == [ProbeSource.metric: Thresholds(elevated: 60, critical: 90)])
        #expect(probe.isActive)
    }

    @Test("a disabled widget's thresholds are not watched, and nothing is sampled for them")
    func disabledWidgetsAreIgnored() async {
        let (bus, probe) = probeBus()
        let watched = probeDocument(thresholds: Thresholds(elevated: 50, critical: nil))
        let store = temporaryStore([watched])
        let monitor = AlertMonitor(bus: bus, store: store)
        monitor.start()
        #expect(probe.isActive)

        store.updateWidget(id: watched.id) { $0.isEnabled = false }
        #expect(await eventually { monitor.thresholds.isEmpty })
        #expect(await eventually { !probe.isActive })
    }
}

@MainActor
@Suite("Importing")
struct ImportCoordinatorTests {

    @Test("an import gets fresh identities at the door")
    func reidentifies() throws {
        let document = probeDocument()
        let coordinator = ImportCoordinator()
        coordinator.offer(data: try WidgetTransfer.export(document), from: "a test")

        #expect(coordinator.isPresenting)
        #expect(coordinator.source == "a test")
        #expect(coordinator.failure == nil)
        let offered = try #require(coordinator.offered.first)
        #expect(offered.id != document.id)
        #expect(offered.cells.map(\.id) != document.cells.map(\.id))
    }

    @Test("an oversized widget is refused with the reason, and nothing is offered")
    func refusesOversized() throws {
        var huge = probeDocument(name: "Wall")
        huge.cells = Array(repeating: huge.cells[0], count: 300)
        let coordinator = ImportCoordinator()
        coordinator.offer(data: try huge.encoded(), from: "a test")

        #expect(!coordinator.isPresenting)
        let failure = try #require(coordinator.failure)
        #expect(failure.contains("300"))
    }

    @Test("a file too large to be a widget is refused before it is read")
    func refusesLargeFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caliperwidget")
        try Data(count: WidgetLimits.fileSize * 2).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let coordinator = ImportCoordinator()
        coordinator.offer(url: url)
        #expect(!coordinator.isPresenting)
        #expect(coordinator.failure == WidgetTransfer.Failure.tooLarge(
            .fileTooLarge(bytes: WidgetLimits.fileSize * 2)).localizedDescription)
    }

    @Test("a failure clears what was on offer")
    func failureReplacesOffer() throws {
        let coordinator = ImportCoordinator()
        coordinator.offer(data: try WidgetTransfer.export(probeDocument()), from: "first")
        coordinator.offer(data: Data("not json".utf8), from: "second")
        #expect(!coordinator.isPresenting)
        #expect(coordinator.failure != nil)
    }
}

@MainActor
@Suite("Sleep and lock")
struct VisibilityMonitorTests {

    @Test("any one of sleep, display sleep and lock hides everything, until all have cleared")
    func combinesSignals() async {
        // Private centres: posting the lock notification for real would tell
        // every app on this Mac that the screen had locked.
        let workspace = NotificationCenter()
        let distributed = NotificationCenter()
        let monitor = VisibilityMonitor(workspace: workspace, distributed: distributed)
        var changes: [Bool] = []
        monitor.onChange = { changes.append($0) }

        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        #expect(await eventually { !monitor.isVisible })

        distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        // Awake but still locked: nobody can see anything yet.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!monitor.isVisible)

        distributed.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        #expect(await eventually { monitor.isVisible })
        #expect(changes == [false, true])
    }
}

@Suite("Updates")
struct UpdateServiceTests {

    @Test("only a build with both a feed and a key updates itself")
    func configuration() {
        #expect(UpdateService.isConfigured(["SUFeedURL": "https://x/appcast.xml", "SUPublicEDKey": "abc="]))
        #expect(!UpdateService.isConfigured([:]))
        #expect(!UpdateService.isConfigured(["SUFeedURL": "https://x/appcast.xml"]))
        // bundle.sh leaves a blank value in a development build.
        #expect(!UpdateService.isConfigured(["SUFeedURL": "  ", "SUPublicEDKey": "abc="]))
    }
}
