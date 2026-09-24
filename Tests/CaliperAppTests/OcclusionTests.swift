import AppKit
import RenderKit
import SchemaKit
import Testing
@testable import CaliperApp

@MainActor
@Suite("Out of sight")
struct OcclusionTests {

    // MARK: - The watcher's decision

    @Test("hiding waits out the grace period; showing does not")
    func graceIsOneWay() async {
        let screen = StandInWindow()
        let watcher = OcclusionWatcher(grace: .milliseconds(100), window: { nil })
        var changes: [Bool] = []
        watcher.onChange = { changes.append($0) }

        screen.set(showing: false, for: watcher)
        // A Space switch hides a window for a moment. That must not count.
        #expect(watcher.isVisible)
        screen.set(showing: true, for: watcher)
        try? await Task.sleep(for: .milliseconds(250))
        #expect(watcher.isVisible)
        #expect(changes.isEmpty)

        screen.set(showing: false, for: watcher)
        #expect(await eventually { !watcher.isVisible })
        screen.set(showing: true, for: watcher)
        // Straight back: there is someone looking.
        #expect(watcher.isVisible)
        #expect(changes == [false, true])
    }

    @Test("repeats are not reported, and a second hide does not restart the clock")
    func noRepeats() async {
        let screen = StandInWindow()
        let watcher = OcclusionWatcher(grace: .milliseconds(50), window: { nil })
        var changes: [Bool] = []
        watcher.onChange = { changes.append($0) }

        screen.set(showing: true, for: watcher)
        screen.set(showing: false, for: watcher)
        screen.set(showing: false, for: watcher)
        #expect(await eventually { !watcher.isVisible })
        screen.set(showing: false, for: watcher)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(changes == [false])
    }

    @Test("a window that has never been on screen reads as hidden, unless it cannot be")
    func readsTheWindow() async {
        // Never ordered in, so no pixel of it is visible.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 20),
                              styleMask: .borderless, backing: .buffered, defer: true)

        let watcher = OcclusionWatcher(grace: .milliseconds(20), window: { window })
        watcher.evaluate()
        #expect(await eventually { !watcher.isVisible })

        // Several menu bars: a hidden window is not a hidden item.
        let mirrored = OcclusionWatcher(grace: .milliseconds(20), window: { window }, canBeHidden: { false })
        mirrored.evaluate()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(mirrored.isVisible)

        // No window yet is not evidence of anything, so it keeps working.
        let early = OcclusionWatcher(grace: .milliseconds(20), window: { nil })
        early.evaluate()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(early.isVisible)
    }

    // MARK: - What it switches off

    @Test("a hidden status item stops the hardware behind it being read, and starts it again")
    func statusItemSuspends() async throws {
        let (bus, probe) = probeBus()
        let controller = StatusItemController(
            bus: bus, widget: probeWidget(), updates: UpdateService(info: [:]),
            occlusionGrace: .milliseconds(20)
        )
        defer { controller.remove() }
        #expect(probe.isActive)
        let watcher = try #require(controller.occlusion)
        let screen = StandInWindow()

        screen.set(showing: false, for: watcher)
        #expect(await eventually { controller.isSuspended })
        #expect(await eventually { !probe.isActive })

        // Editing the widget while it is hidden redraws it once but does not
        // start sampling for it.
        controller.setWidget(probeWidget(name: "Renamed"))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!probe.isActive)

        screen.set(showing: true, for: watcher)
        #expect(!controller.isSuspended)
        #expect(await eventually { probe.isActive })
    }

    @Test("a removed status item cannot be woken by a late occlusion change")
    func removedStaysRemoved() async {
        let (bus, probe) = probeBus()
        let controller = StatusItemController(
            bus: bus, widget: probeWidget(), updates: UpdateService(info: [:]),
            occlusionGrace: .milliseconds(20)
        )
        let watcher = controller.occlusion
        controller.remove()
        #expect(controller.occlusion == nil)
        #expect(await eventually { !probe.isActive })

        let screen = StandInWindow()
        if let watcher {
            screen.set(showing: false, for: watcher)
            try? await Task.sleep(for: .milliseconds(100))
            screen.set(showing: true, for: watcher)
        }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!probe.isActive)
    }

    @Test("a hidden desktop widget stops sampling too")
    func desktopWidgetSuspends() async throws {
        let (bus, probe) = probeBus()
        let window = DesktopWidgetWindow(bus: bus, placement: DesktopPlacement(), occlusionGrace: .milliseconds(20))
        defer { window.close() }
        window.update(widget: probeWidget(), placement: DesktopPlacement())
        #expect(probe.isActive)

        let watcher = try #require(window.occlusion)
        let screen = StandInWindow()
        screen.set(showing: false, for: watcher)
        #expect(await eventually { !probe.isActive })
        screen.set(showing: true, for: watcher)
        #expect(await eventually { probe.isActive })
    }

    @Test("an alert keeps its metric sampled while the strip showing it is hidden")
    func alertsOutliveTheStrip() async throws {
        // The point of suspending per surface rather than stopping the bus: a
        // CPU pinned during a film is still noticed.
        let (bus, probe) = probeBus()
        let store = temporaryStore([probeDocument(thresholds: Thresholds(elevated: 50, critical: 90))])
        let alerts = AlertMonitor(bus: bus, store: store)
        alerts.start()

        let controller = StatusItemController(
            bus: bus, widget: probeWidget(), updates: UpdateService(info: [:]),
            occlusionGrace: .milliseconds(20)
        )
        defer { controller.remove() }
        let screen = StandInWindow()
        screen.set(showing: false, for: try #require(controller.occlusion))
        #expect(await eventually { controller.isSuspended })

        try? await Task.sleep(for: .milliseconds(100))
        #expect(probe.isActive)
    }
}
