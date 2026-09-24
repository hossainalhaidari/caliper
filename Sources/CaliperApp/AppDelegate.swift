import AppKit
import MetricBus
import SchemaKit
import SensorKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let bus = MetricBus()
    private let store = WidgetStore()
    private let visibility = VisibilityMonitor()

    private var statusItems: StatusItemManager?
    private var editor: EditorWindowController?
    private var alerts: AlertMonitor?
    private var desktop: DesktopWidgetManager?
    private let updates = UpdateService()

    /// Held so it can be told to re-enumerate when a volume is mounted.
    private let diskActivity = DiskActivitySource()
    private var mountObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        bus.register(ClockSource())
        bus.register(CPULoadSource())
        bus.register(CPUCoreSource())
        bus.register(MemorySource())
        bus.register(NetworkSource())
        bus.register(DiskCapacitySource())
        bus.register(diskActivity)

        // The private tier. Each of these probes at construction and publishes no
        // descriptors at all when its interface is missing, so a macOS release
        // that moves or renames these symbols removes the metrics from the picker
        // rather than filling the menu bar with permanent dashes.
        bus.register(GPUSource())
        bus.register(ThermalSource())
        bus.register(PowerSource())
        bus.register(BatterySource())
        bus.register(FanSource())

        // Before the status items, which put its menu entries in every strip's
        // dropdown.
        updates.start()

        let manager = StatusItemManager(bus: bus, store: store, updates: updates)
        manager.onEditRequested = { [weak self] in self?.showEditor() }
        manager.start()
        statusItems = manager

        visibility.onChange = { [weak self] isVisible in
            guard let self else { return }
            // Resuming re-primes every source's delta state, so the first
            // reading after wake covers the last second and not the last eight
            // hours of sleep.
            isVisible ? self.bus.start() : self.bus.stop()
        }

        let desktopManager = DesktopWidgetManager(bus: bus, store: store)
        desktopManager.start()
        desktop = desktopManager

        let monitor = AlertMonitor(bus: bus, store: store)
        monitor.start()
        alerts = monitor

        observeVolumeChanges()
        bus.start()

        handleDiagnosticArguments()
    }

    /// `--editor-cycle` reports footprint before, during, and after having the
    /// editor open.
    ///
    /// Opening a SwiftUI window costs real memory, and the interesting question
    /// is not how much but whether it comes back. Guessing was not good enough:
    /// an agent that grows permanently every time you glance at its settings is
    /// a different kind of app from one that does not.
    private func reportEditorCycle() {
        func footprint(_ stage: String) {
            let bytes = Self.physicalFootprint()
            let line = String(format: "%@: %.1f MB\n", stage, Double(bytes) / 1_048_576)
            FileHandle.standardError.write(Data(line.utf8))
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            footprint("before opening editor")

            showEditor()
            try? await Task.sleep(for: .seconds(5))
            footprint("editor open        ")

            editor?.close()
            try? await Task.sleep(for: .seconds(5))
            footprint("editor closed      ")

            NSApp.terminate(nil)
        }
    }

    private static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// `--dump-editor <path>` renders the editor window and exits.
    ///
    /// A development affordance, not a feature: it is how the editor gets
    /// reviewed without Screen Recording permission. It waits for real readings
    /// first, because an editor screenshot full of placeholder dashes says
    /// nothing about whether the thing works.
    private func handleDiagnosticArguments() {
        let arguments = CommandLine.arguments

        if arguments.contains("--editor-cycle") {
            reportEditorCycle()
            return
        }

        if let flag = arguments.firstIndex(of: "--dump-live-panel"), arguments.count > flag + 1 {
            let path = arguments[flag + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                self.statusItems?.openPanelForDiagnostics()
                try? await Task.sleep(for: .seconds(4))
                let result: (ok: Bool, geometry: String) =
                    self.statusItems?.dumpLivePanel(to: path) ?? (ok: false, geometry: "none")
                FileHandle.standardError.write(Data("\(result.geometry)\n".utf8))
                FileHandle.standardError.write(Data((result.ok ? "wrote \(path)\n" : "dump failed\n").utf8))
                NSApp.terminate(nil)
            }
            return
        }

        if let flag = arguments.firstIndex(of: "--dump-panel"), arguments.count > flag + 1 {
            let path = arguments[flag + 1]
            let group = arguments.count > flag + 2 ? arguments[flag + 2] : "CPU"
            let wait = arguments.count > flag + 3 ? Int(arguments[flag + 3]) ?? 8 : 8
            Task { @MainActor in
                // Wait for real readings: a panel full of dashes shows nothing
                // about whether the layout works.
                try? await Task.sleep(for: .seconds(wait))
                let ok = self.statusItems?.dumpPanel(group: group, to: path) ?? false
                FileHandle.standardError.write(Data((ok ? "wrote \(path)\n" : "dump failed\n").utf8))
                NSApp.terminate(nil)
            }
            return
        }

        guard let flag = arguments.firstIndex(of: "--dump-editor"),
              arguments.count > flag + 1 else { return }
        let path = arguments[flag + 1]

        showEditor()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            let ok = self.editor?.dump(to: path) ?? false
            FileHandle.standardError.write(Data((ok ? "wrote \(path)\n" : "dump failed\n").utf8))
            NSApp.terminate(nil)
        }
    }

    /// Finder double-click, `open` from the shell, and anything else that hands
    /// the app a file.
    ///
    /// An agent app can still be a document handler; it just has to bring itself
    /// forward, since it has no windows of its own to inherit focus from.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        showEditor()
        editor?.offer(url: url)
    }

    /// Relaunching the app opens the editor.
    ///
    /// The usual way in is right-clicking a status item, and there may not be
    /// one: every widget can be on the desktop, or hidden. Without this the app
    /// would be running with no way to reach its own settings.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        showEditor()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        bus.stop()
        // Debounced saves may still be pending; the app is going away, so flush.
        store.saveNow()
    }

    private func showEditor() {
        if editor == nil {
            editor = EditorWindowController(store: store, bus: bus)
        }
        editor?.show()
    }

    /// Hardware that appears after launch has to be picked up explicitly --
    /// nothing polls for it, because polling for a rare event is exactly the
    /// kind of background work this app is trying not to do.
    private func observeVolumeChanges() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.diskActivity.rescanDevices()
                    self.bus.refreshDescriptors()
                    self.statusItems?.refresh()
                }
            }
            mountObservers.append(token)
        }
    }
}
