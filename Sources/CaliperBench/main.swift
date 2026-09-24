import AppKit
import Foundation
import LayoutEngine
import SchemaKit
import MetricBus
import RenderKit
import SensorKit

/// The M0 performance budget.
///
/// This exists at M0 rather than "once things settle" on purpose. "Fast and
/// resource efficient" is a claim, and a claim with no number attached is one
/// nobody ever has to be accountable to. With a number, every future milestone
/// either stays inside it or has to argue for a change -- and regressions get
/// caught by the commit that caused them instead of by a user's fan.
enum Budget {
    /// Percent of one core, averaged over a soak. For reference, the base tick
    /// costs a few microseconds; the headroom is for rendering and AppKit.
    static let cpuPercent = 0.3
    /// Physical footprint, as Activity Monitor reports it.
    static let footprintBytes: UInt64 = 30 * 1_048_576

    /// The budget once the editor has been opened, which is a different app.
    ///
    /// Opening the SwiftUI editor costs about 20 MB and **does not give it
    /// back**: measured at 12.7 MB before, 33.5 MB with the window open, and
    /// 32.8 MB after closing it and releasing the entire view hierarchy. The
    /// 0.7 MB difference is all that was ever reclaimable -- the rest is
    /// SwiftUI's own frameworks, and dyld cannot unload a framework once it is
    /// in.
    ///
    /// Recorded as a second budget rather than by raising the first. The number
    /// that matters for a menu bar agent is what it costs sitting there all day,
    /// and most sessions never open the editor at all. Quietly relaxing the
    /// resident budget to make this pass would have thrown away the only figure
    /// worth defending.
    static let editingCPUPercent = 0.5
    static let editingFootprintBytes: UInt64 = 45 * 1_048_576
}

// MARK: - Micro-benchmarks

/// Per-source sampling cost, in both wall time and CPU time.
///
/// Reporting only one number misleads, and did. The thermal source spends 44 ms
/// per full sweep but only 1.6 ms of it on the CPU -- the rest is blocking IPC.
/// Judged on wall time alone it looks like it would destroy the CPU budget;
/// judged on CPU time alone it looks free. Both readings matter, for different
/// reasons:
///
/// - **CPU** is what drains the battery and what the budget is written against.
/// - **Wall** is queue occupancy. Every source shares one serial queue, so a
///   source that blocks for 44 ms delays everything else by 44 ms.
///
/// Treat these as *relative* figures, not absolute ones. Samples here run
/// back-to-back, which measurably overstates sources that talk to the kernel:
/// `PowerSource` reports 1.2 ms here but costs about 0.15 ms in the running app,
/// measured by difference between a power-only and a CPU-only widget. The
/// authority for what the app actually costs is `caliper-bench watch` against the
/// real process; this table is for comparing sources with each other and for
/// catching something that has become a thousand times worse than its
/// neighbours, which is exactly what it did for the thermal source.
@MainActor
func benchmarkSources(iterations: Int = 300) {
    print("\n  per-source cost (relative; see `watch` for what the app really uses)")
    for source in allSources() {
        let descriptors = source.descriptors
        guard !descriptors.isEmpty else {
            let name = "\(type(of: source))".padding(toLength: 20, withPad: " ", startingAt: 0)
            print("  \(name) unavailable on this Mac")
            continue
        }

        source.activate()
        var sink = SampleSink()
        for _ in 0..<20 {
            sink.reset()
            source.sample(into: &sink, context: SampleContext(elapsed: 1))
        }

        let cpuBefore = Format.processCPUSeconds()
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            sink.reset()
            source.sample(into: &sink, context: SampleContext(elapsed: 1))
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        let cpu = Format.processCPUSeconds() - cpuBefore
        source.deactivate()

        let name = "\(type(of: source))".padding(toLength: 20, withPad: " ", startingAt: 0)
        let wallEach = Format.microseconds(elapsed / Double(iterations))
        let cpuEach = Format.microseconds(cpu / Double(iterations))
        print("  \(name) wall \(wallEach.padding(toLength: 12, withPad: " ", startingAt: 0)) cpu \(cpuEach.padding(toLength: 11, withPad: " ", startingAt: 0)) \(descriptors.count) metrics, .\(source.cadence)")
    }
}

func benchmarkSampler(iterations: Int = 100_000) {
    let source = CPULoadSource()
    source.activate()
    var sink = SampleSink()

    // Warm up: first call faults in the Mach trap path.
    for _ in 0..<1000 {
        sink.reset()
        source.sample(into: &sink, context: SampleContext(elapsed: 1.0))
    }

    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
        sink.reset()
        source.sample(into: &sink, context: SampleContext(elapsed: 1.0))
    }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000


    source.deactivate()
    print("  sampler   \(Format.microseconds(elapsed / Double(iterations)))/sample  (\(iterations) iterations)")
}

@MainActor
func benchmarkRender(iterations: Int = 20_000) {
    let widget = Widget(
        name: "bench",
        cells: [
            Cell(
                metric: CPULoadSource.total,
                renderer: TextValueRenderer(thresholds: Thresholds(elevated: 70, critical: 90)),
                label: "CPU"
            )
        ]
    )
    let descriptors = [
        CPULoadSource.total: MetricDescriptor(
            id: CPULoadSource.total,
            displayName: "CPU Usage",
            group: "CPU",
            unit: .percent,
            range: .percentage
        )
    ]
    let composer = StripComposer()
    let context = RenderContext(density: .regular, scale: 2.0)

    func frame(_ value: Double) -> StripComposer.Frame {
        StripComposer.Frame(values: [CPULoadSource.total: value], descriptors: descriptors)
    }

    for index in 0..<200 {
        autoreleasepool { _ = composer.compose(widget, frame: frame(Double(index % 100)), context: context) }
    }

    // Worst case: every frame shows a different number, so nothing is skipped.
    //
    // Each iteration gets its own autorelease pool. Without one, tens of
    // thousands of CGImage and NSImage temporaries pile up until the loop ends
    // -- which measures nothing useful and, more to the point, poisons the
    // footprint reading that the soak below depends on. In the app the main
    // run loop drains a pool every cycle, so per-iteration is the faithful
    // simulation, not a trick to flatter the number.
    var start = DispatchTime.now().uptimeNanoseconds
    for index in 0..<iterations {
        autoreleasepool {
            _ = composer.compose(widget, frame: frame(Double(index % 100)), context: context)
        }
    }
    var elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    print("  render    \(Format.microseconds(elapsed / Double(iterations)))/frame   (value changed every frame)")

    // Realistic case: the value is stable, so the change key matches and the
    // rasteriser is never entered. This is what most ticks actually cost.
    _ = composer.compose(widget, frame: frame(42), context: context)
    start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
        autoreleasepool { _ = composer.compose(widget, frame: frame(42), context: context) }
    }
    elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    print("  render    \(Format.microseconds(elapsed / Double(iterations)))/frame   (unchanged, redraw skipped)")

    // The same cell wearing an icon instead of a caption.
    //
    // Measured separately because it is a different amount of work, not a
    // rounding difference on the same work: a caption is a text run the layout
    // already measures, while a symbol is an `NSImage` built from a name and a
    // point size, asked for once to reserve the width and again to draw it.
    // The default strip in this benchmark has no icon, so without this the one
    // adornment most real widgets use was the one nothing measured.
    let iconWidget = Widget(
        name: "bench-icon",
        cells: [
            Cell(
                metric: CPULoadSource.total,
                renderer: TextValueRenderer(thresholds: Thresholds(elevated: 70, critical: 90)),
                adornment: .symbol("cpu")
            )
        ]
    )
    let iconComposer = StripComposer()
    for index in 0..<200 {
        autoreleasepool {
            _ = iconComposer.compose(iconWidget, frame: frame(Double(index % 100)), context: context)
        }
    }

    start = DispatchTime.now().uptimeNanoseconds
    for index in 0..<iterations {
        autoreleasepool {
            _ = iconComposer.compose(iconWidget, frame: frame(Double(index % 100)), context: context)
        }
    }
    elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    print("  render    \(Format.microseconds(elapsed / Double(iterations)))/frame   (icon, value changed every frame)")
}

// MARK: - Soak

/// Holds the soak's render state on the main actor.
///
/// `Widget` and `RenderContext` are deliberately not `Sendable` -- they carry
/// AppKit types and are meant to be touched from one actor only. Putting them
/// behind a `@MainActor` class is how the observer closure gets at them without
/// weakening either type just to satisfy a benchmark.
@MainActor
final class SoakRenderer {
    private let widget: Widget
    private let descriptors: [MetricID: MetricDescriptor]
    private let composer = StripComposer()
    private let context = RenderContext()

    private(set) var ticks = 0
    private(set) var redraws = 0

    init(widget: Widget, descriptors: [MetricID: MetricDescriptor]) {
        self.widget = widget
        self.descriptors = descriptors
    }

    func handle(_ snapshot: Snapshot) {
        ticks += 1
        autoreleasepool {
            let frame = StripComposer.Frame(values: snapshot.values, descriptors: descriptors)
            if composer.compose(widget, frame: frame, context: context) != nil {
                redraws += 1
            }
        }
    }
}

@MainActor
func soak(seconds: Int) {
    print("\n  soaking the full pipeline for \(seconds)s at 1 Hz...")

    let bus = MetricBus()
    for source in allSources() { bus.register(source) }
    let subscription = bus.subscribe(to: CPULoadSource.total, CPULoadSource.user, CPULoadSource.system)

    let widget = Widget(
        name: "soak",
        cells: [
            Cell(metric: CPULoadSource.total, renderer: TextValueRenderer(), label: "CPU")
        ]
    )
    var descriptors: [MetricID: MetricDescriptor] = [:]
    for descriptor in bus.availableMetrics() { descriptors[descriptor.id] = descriptor }

    let renderer = SoakRenderer(widget: widget, descriptors: descriptors)

    bus.observe { snapshot in
        MainActor.assumeIsolated { renderer.handle(snapshot) }
    }
    bus.start()

    guard let start = ProcessProbe.read(pid: getpid()) else {
        print("  ! could not read own resource usage")
        exit(2)
    }

    RunLoop.main.run(until: Date().addingTimeInterval(Double(seconds)))

    guard let end = ProcessProbe.read(pid: getpid()) else { exit(2) }
    bus.stop()
    subscription.cancel()

    // The redraw ratio is the headline efficiency number: it is the fraction of
    // ticks that actually reached the rasteriser.
    print("")
    print("    ticks       \(renderer.ticks)")
    print("    redraws     \(renderer.redraws)  (\(renderer.ticks > 0 ? renderer.redraws * 100 / renderer.ticks : 0)% of ticks)")

    report(start: start, end: end, ticks: nil, label: "self")
}

@MainActor
func watch(pid: pid_t, seconds: Int, editing: Bool = false) {
    print("\n  watching pid \(pid) for \(seconds)s...")
    guard let start = ProcessProbe.read(pid: pid) else {
        print("  ! pid \(pid) is not readable (wrong user, or not running)")
        exit(2)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(Double(seconds)))
    guard let end = ProcessProbe.read(pid: pid) else {
        print("  ! pid \(pid) went away")
        exit(2)
    }
    report(start: start, end: end, ticks: nil, label: "pid \(pid)", editing: editing)
}

func report(
    start: ProcessProbe.Reading,
    end: ProcessProbe.Reading,
    ticks: Int?,
    label: String,
    editing: Bool = false
) {
    let cpu = ProcessProbe.utilization(from: start, to: end)
    let footprint = end.footprintBytes

    let cpuBudget = editing ? Budget.editingCPUPercent : Budget.cpuPercent
    let memoryBudget = editing ? Budget.editingFootprintBytes : Budget.footprintBytes
    let cpuOK = cpu <= cpuBudget
    let memoryOK = footprint <= memoryBudget

    print("")
    print("  \(label)")
    if let ticks { print("    ticks       \(ticks)") }
    if editing { print("    (editing budget: the editor has been opened this session)") }
    print("    cpu         \(String(format: "%.3f", cpu))%  (budget \(cpuBudget)%)  \(cpuOK ? "PASS" : "FAIL")")
    print("    footprint   \(Format.megabytes(footprint))  (budget \(Format.megabytes(memoryBudget)))  \(memoryOK ? "PASS" : "FAIL")")
    print("")

    if !(cpuOK && memoryOK) {
        print("  BUDGET EXCEEDED")
        exit(1)
    }
}

// MARK: - Preview

/// Samples live data, renders the default strip, and writes it to a PNG.
///
/// Waits for real readings rather than rendering placeholders: rate metrics need
/// two samples before they mean anything, so a preview taken immediately would
/// show a strip full of dashes and tell you nothing about the layout.
@MainActor
func preview(path: String, seconds: Int = 3) {
    // A faster tick than the app uses, purely so the preview fills a 60-sample
    // graph window in seconds instead of a minute. Rates are then measured over
    // 250ms and read noisier than they would in the menu bar; everything else is
    // identical to what the app renders.
    var configuration = MetricBus.Configuration()
    configuration.baseInterval = 0.25

    let bus = MetricBus(configuration: configuration)
    for source in allSources() { bus.register(source) }

    var descriptors: [MetricID: MetricDescriptor] = [:]
    for descriptor in bus.availableMetrics() { descriptors[descriptor.id] = descriptor }

    let resolution = WidgetDocument.overview().resolve(
        in: ResolutionContext(
            descriptors: descriptors,
            coreGroups: CPUCoreSource().clusters.map(\.indices.count)
        )
    )
    if !resolution.isComplete { print("  ! \(resolution.summary)") }
    let widget = resolution.widget

    let subscription = bus.subscribe(to: widget.requiredMetrics)

    bus.start()
    print("  sampling for \(seconds)s...")
    RunLoop.main.run(until: Date().addingTimeInterval(Double(seconds)))
    bus.stop()

    var values: [MetricID: Double] = [:]
    for metric in widget.requiredMetrics { values[metric] = bus.value(for: metric) }

    // Graph cells read their window from the bus, exactly as the status item
    // does. Omitting this renders the strip with every graph blank, which is
    // how the first version of this tool quietly hid the graph entirely.
    var histories: [MetricID: [Float]] = [:]
    for cell in widget.cells where cell.historyDepth > 0 {
        guard let metric = cell.metric else { continue }
        histories[metric] = bus.history(for: metric, count: cell.historyDepth)
    }
    subscription.cancel()

    let composer = StripComposer()
    let context = RenderContext()
    let frame = StripComposer.Frame(values: values, histories: histories, descriptors: descriptors)

    func compose(in appearance: NSAppearance?) -> NSImage? {
        // Invalidate between passes: the change key covers data and geometry,
        // not appearance, so without this the second pass would be skipped as
        // "unchanged" and both rows would show the same rendering.
        composer.invalidate()
        var result: NSImage?
        (appearance ?? NSAppearance(named: .aqua))?.performAsCurrentDrawingAppearance {
            result = composer.compose(widget, frame: frame, context: context)
        }
        return result
    }

    guard let darkImage = compose(in: NSAppearance(named: .darkAqua)),
          let lightImage = compose(in: NSAppearance(named: .aqua)) else {
        print("  ! nothing to render")
        exit(2)
    }
    let image = darkImage

    do {
        try PreviewRenderer.write(dark: darkImage, light: lightImage, to: path)
        let depth = histories.values.map(\.count).max() ?? 0
        print("  history: \(depth) samples")
        let rendered = values
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key)=\(String(format: "%.1f", $0.value))" }
        print("  values: \(rendered.joined(separator: "  "))")
        print("  size:   \(Int(image.size.width))x\(Int(image.size.height))pt, template=\(image.isTemplate)")
        print("  wrote:  \(path)")
    } catch {
        print("  ! \(error)")
        exit(2)
    }
}

// MARK: - Sensor listing

/// Registers every source and prints what this Mac can actually report.
///
/// The quickest way to see the effect of the capability probes: anything absent
/// from this listing is absent from the editor's picker too, because both read
/// the same descriptors.
@MainActor
func listSensors(seconds: Int) {
    var configuration = MetricBus.Configuration()
    configuration.baseInterval = 0.5
    let bus = MetricBus(configuration: configuration)

    for source in allSources() { bus.register(source) }

    let descriptors = bus.availableMetrics()
    let subscription = bus.subscribe(to: Set(descriptors.map(\.id)))
    bus.start()
    // Forces the slow sources -- disk capacity at 30s, temperatures at 5s -- to
    // report once immediately, rather than leaving them blank for the length of
    // their own cadence.
    bus.sampleNow()
    print("  sampling for \(seconds)s...")
    RunLoop.main.run(until: Date().addingTimeInterval(Double(seconds)))
    bus.stop()

    let formatter = ValueFormatter(decimals: 1)
    let grouped = Dictionary(grouping: descriptors, by: \.group)

    for group in grouped.keys.sorted() {
        let metrics = grouped[group]!.sorted { $0.id.rawValue < $1.id.rawValue }
        print("\n  \(group)  (\(metrics.count))")
        for descriptor in metrics {
            let value = bus.value(for: descriptor.id)
            let text = value.map { formatter.string(for: $0, unit: descriptor.unit) } ?? "--"
            let padded = descriptor.id.rawValue.padding(toLength: 40, withPad: " ", startingAt: 0)
            print("    \(padded) \(text)")
        }
    }
    subscription.cancel()
}

@MainActor
func allSources() -> [any MetricSource] {
    [
        ClockSource(), CPULoadSource(), CPUCoreSource(), MemorySource(), NetworkSource(),
        DiskCapacitySource(), DiskActivitySource(),
        GPUSource(), ThermalSource(), PowerSource(), BatterySource(), FanSource(),
    ]
}

// MARK: - Inspecting a shared widget

/// Parses a shared widget, resolves it against this Mac, and reports.
///
/// The command-line equivalent of the import sheet, running the same parse and
/// the same resolution. It exists because the sheet is SwiftUI and cannot be
/// captured headlessly -- but the logic underneath it can be exercised and
/// looked at, which is the part that decides whether a shared widget works.
@MainActor
func inspect(path: String, previewPath: String?) {
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url) else {
        print("  ! could not read \(path)")
        exit(2)
    }

    let payload: WidgetTransfer.Payload
    do {
        payload = try WidgetTransfer.parse(data)
    } catch {
        print("  ! \(error.localizedDescription)")
        exit(2)
    }

    let bus = MetricBus()
    for source in allSources() { bus.register(source) }

    let context = ResolutionContext(
        descriptors: bus.availableMetrics(),
        coreGroups: CPUCoreSource().clusters.map(\.indices.count)
    )

    for document in payload.widgets {
        let resolution = document.resolve(in: context)
        print("")
        let width = Int(WidgetLimits.worstCaseWidth(of: document).rounded(.up))
        print("  \(document.name)  --  \(document.cells.count) cells, at most \(width)pt wide")
        if let author = document.author { print("  by \(author)") }

        if resolution.isComplete {
            print("  OK: everything in this widget works on this Mac.")
        } else {
            print("  \(resolution.summary)")
            for issue in resolution.issues {
                print("    \(issue.isFatal ? "dropped" : "degraded"): \(issue.summary)")
            }
        }
    }

    guard let previewPath, let document = payload.widgets.first else { return }

    var configuration = MetricBus.Configuration()
    configuration.baseInterval = 0.25
    let liveBus = MetricBus(configuration: configuration)
    for source in allSources() { liveBus.register(source) }

    let resolution = document.resolve(
        in: ResolutionContext(
            descriptors: liveBus.availableMetrics(),
            coreGroups: CPUCoreSource().clusters.map(\.indices.count)
        )
    )
    let widget = resolution.widget
    let subscription = liveBus.subscribe(to: widget.requiredMetrics)
    liveBus.start()
    print("\n  sampling for 20s to fill the graphs...")
    RunLoop.main.run(until: Date().addingTimeInterval(20))
    liveBus.stop()

    var values: [MetricID: Double] = [:]
    for metric in widget.requiredMetrics { values[metric] = liveBus.value(for: metric) }
    var histories: [MetricID: [Float]] = [:]
    for cell in widget.cells where cell.historyDepth > 0 {
        guard let metric = cell.metric else { continue }
        histories[metric] = liveBus.history(for: metric, count: cell.historyDepth)
    }
    subscription.cancel()

    var descriptors: [MetricID: MetricDescriptor] = [:]
    for descriptor in liveBus.availableMetrics() { descriptors[descriptor.id] = descriptor }

    let composer = StripComposer()
    let frame = StripComposer.Frame(values: values, histories: histories, descriptors: descriptors)

    func compose(_ name: NSAppearance.Name) -> NSImage? {
        composer.invalidate()
        var result: NSImage?
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            result = composer.compose(widget, frame: frame, context: RenderContext())
        }
        return result
    }

    guard let dark = compose(.darkAqua), let light = compose(.aqua) else {
        print("  ! nothing to render")
        return
    }
    try? PreviewRenderer.write(dark: dark, light: light, to: previewPath)
    print("  wrote:  \(previewPath)")
}

// MARK: - Entry

func findCaliperProcess() -> pid_t? {
    NSWorkspace.shared.runningApplications.first {
        $0.bundleIdentifier == "de.alhaidari.caliper"
            || $0.executableURL?.lastPathComponent == "Caliper"
    }?.processIdentifier
}

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "all"
let duration = arguments.count > 1 ? Int(arguments[1]) ?? 30 : 30

print("\ncaliper-bench  --  resident budget: \(Budget.cpuPercent)% cpu, \(Format.megabytes(Budget.footprintBytes)) footprint")
print("                 after editing:   \(Budget.editingCPUPercent)% cpu, \(Format.megabytes(Budget.editingFootprintBytes)) footprint\n")

switch command {
case "micro":
    benchmarkSampler()
    benchmarkRender()
    benchmarkSources()

case "soak":
    benchmarkSampler()
    benchmarkRender()
    soak(seconds: duration)

case "preview":
    preview(
        path: arguments.count > 1 ? arguments[1] : "strip.png",
        seconds: arguments.count > 2 ? Int(arguments[2]) ?? 3 : 3
    )

case "sensors":
    listSensors(seconds: arguments.count > 1 ? Int(arguments[1]) ?? 4 : 4)

case "inspect":
    guard arguments.count > 1 else {
        print("  usage: caliper-bench inspect <file.caliperwidget> [preview.png]")
        exit(2)
    }
    inspect(path: arguments[1], previewPath: arguments.count > 2 ? arguments[2] : nil)

case "icon":
    do {
        let out = arguments.count > 1 ? arguments[1] : "build/AppIcon.iconset"
        try IconForge.write(to: out)
        print("  wrote:  \(out)")
    } catch {
        print("  ! \(error)")
        exit(2)
    }

case "gallery":
    do {
        try Gallery.write(to: arguments.count > 1 ? arguments[1] : "gallery.png")
        print("  wrote:  \(arguments.count > 1 ? arguments[1] : "gallery.png")")
    } catch {
        print("  ! \(error)")
        exit(2)
    }

case "watch":
    // `watch <pid>` or bare `watch` to find a running Caliper.
    let editing = arguments.contains("--editing")
    if arguments.count > 1, let explicit = pid_t(arguments[1]) {
        let seconds = arguments.count > 2 ? Int(arguments[2]) ?? 30 : 30
        watch(pid: explicit, seconds: seconds, editing: editing)
    } else if let found = findCaliperProcess() {
        watch(pid: found, seconds: duration, editing: editing)
    } else {
        print("  ! no running Caliper process found; pass a pid explicitly")
        exit(2)
    }

default:
    benchmarkSampler()
    benchmarkRender()
    soak(seconds: duration)
}
