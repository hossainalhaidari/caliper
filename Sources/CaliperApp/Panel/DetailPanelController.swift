import AppKit
import MetricBus
import RenderKit
import SensorKit

/// Owns the detail popover and keeps it fed while it is open.
///
/// Scoped rather than exhaustive: you clicked a cell, so the panel opens on that
/// cell's group and everything else is a chip in the footer. The alternative --
/// one dense table of every metric -- is what most system monitors do, and it
/// answers no question in particular.
///
/// Grouping comes from `MetricDescriptor.group`, so a source added later appears
/// here with no panel code changed at all.
@MainActor
final class DetailPanelController: NSObject, NSPopoverDelegate {
    private let bus: MetricBus
    private let popover = NSPopover()
    private let view = DetailPanelView()

    private var descriptors: [MetricID: MetricDescriptor] = [:]
    private var grouped: [String: [MetricDescriptor]] = [:]
    private var subscription: MetricBus.Subscription?
    /// What the current subscription covers, so it is only rebuilt when the set
    /// actually changes.
    private var subscribedMetrics: Set<MetricID> = []

    /// Sampled only while the panel is open. A full sweep of 650 processes costs
    /// about 2.7ms -- fine for something on screen, indefensible once a second
    /// forever -- which is why this lives here rather than on the bus.
    private let processes = ProcessSampler()
    private var observer: UUID?
    private var focusedGroup: String?

    /// Metrics whose group has nothing worth a second row are folded in here
    /// rather than shown as a one-line panel.
    private static let rowLimit = 5

    /// How processes are ranked for a group, if at all.
    ///
    /// Disk and network are absent deliberately: per-process figures for those
    /// need interfaces this app does not use, and a list that quietly measured
    /// something else would be worse than no list.
    private static func ranking(for group: String) -> ProcessSampler.Ranking? {
        switch group {
        case "CPU", "CPU Cores": .cpu
        case "Memory": .memory
        default: nil
        }
    }

    init(bus: MetricBus) {
        self.bus = bus
        super.init()

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        // The content sits on the *same* material the popover's own frame uses,
        // so the two are one continuous surface. Filling the content opaquely
        // instead left a visible seam: NSPopover draws a 13pt translucent border
        // around its content, and an opaque rectangle inside that border shows
        // the desktop in the gap.
        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.autoresizingMask = [.width, .height]

        // Pinned rather than autoresized: a mask resizes proportionally from
        // whatever frame the view happened to start with, and starting at zero
        // leaves it filling nothing. Constraints state the intent directly --
        // the content is the backdrop.
        view.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            view.topAnchor.constraint(equalTo: backdrop.topAnchor),
            view.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])

        let controller = NSViewController()
        controller.view = backdrop
        popover.contentViewController = controller

        view.onSelectGroup = { [weak self] group in self?.focus(group) }
    }

    /// Opens against a status item button, scoped to a metric.
    func show(relativeTo button: NSStatusBarButton, metric: MetricID?) {
        refreshCatalogue()

        let group = metric.flatMap { descriptors[$0]?.group } ?? grouped.keys.sorted().first
        guard let group else { return }

        focusedGroup = group
        preferredMetric = metric
        rebuild()

        // Take a CPU baseline the moment the panel opens, so the first list a
        // second later is real rather than a column of zeros.
        processes.refresh()

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)

        // Sampling starts when the panel opens and stops when it closes. A panel
        // nobody is looking at has no business keeping a sensor awake.
        observer = bus.observe { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        bus.sampleNow()
    }

    func close() {
        popover.performClose(nil)
    }

    var isOpen: Bool { popover.isShown }

    func popoverDidClose(_ notification: Notification) {
        subscription?.cancel()
        subscription = nil
        subscribedMetrics = []
        // Forget the CPU baseline, so a panel reopened in ten minutes reports
        // what is happening now rather than an average across the whole gap.
        processes.reset()
        if let observer { bus.removeObserver(observer) }
        observer = nil
    }

    private var preferredMetric: MetricID?

    /// Captures the popover **as it actually appears on screen**.
    ///
    /// Rendering the content view alone is what let the previous bug through:
    /// in isolation it looked perfect, while live it sat inset inside the
    /// popover with the desktop showing around it. This walks up to the
    /// popover's own window and captures its whole content view, so the frame,
    /// the corners and the fill are all in the picture.
    func dumpLive(to path: String) -> Bool {
        guard let window = view.window, let root = window.contentView else { return false }
        root.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let representation = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
            return false
        }
        root.cacheDisplay(in: root.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// Geometry check for when a picture is not available: the content view must
    /// fill the popover's content size exactly.
    var liveGeometry: String {
        guard let window = view.window else { return "popover not shown" }
        return "popover \(Int(window.frame.width))x\(Int(window.frame.height))"
            + "  content \(Int(popover.contentSize.width))x\(Int(popover.contentSize.height))"
            + "  view \(Int(view.bounds.width))x\(Int(view.bounds.height))"
            + "  origin \(Int(view.frame.minX)),\(Int(view.frame.minY))"
    }

    /// Renders the panel to a PNG in both appearances, over a saturated ground.
    ///
    /// The first version of this filled an opaque `windowBackgroundColor` before
    /// drawing, so it tested a condition that never occurs -- and reported the
    /// panel as fine while it was, in reality, illegible over a blue wallpaper.
    /// A verification tool that arranges favourable conditions is worse than no
    /// tool, because it converts an unknown into a false certainty.
    ///
    /// So the ground here is deliberately hostile: a strong colour, which the
    /// panel must completely cover. Anything showing through is a bug.
    func dump(group: String, to path: String) -> Bool {
        refreshCatalogue()
        guard grouped[group] != nil else { return false }

        focusedGroup = group
        preferredMetric = nil
        rebuild()

        // The dump has no popover to size the view, so here -- and only here --
        // the frame is set explicitly. Auto Layout would otherwise leave it at
        // zero, since nothing has laid it out.
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = NSRect(
            origin: .zero,
            size: NSSize(
                width: DetailPanelView.width,
                height: DetailPanelView.height(
                    rows: view.content?.rows.count ?? 0,
                    processes: view.content?.processes.count ?? 0,
                    hasNote: view.content?.processNote != nil,
                    hasOtherGroups: !(view.content?.otherGroups.isEmpty ?? true)
                )
            )
        )

        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return false }

        let gap: CGFloat = 20
        let total = NSSize(width: size.width * 2 + gap * 3, height: size.height + gap * 2)

        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(total.width * 2), pixelsHigh: Int(total.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return false }

        representation.size = total

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)

        // The wallpaper that broke the original opaque-fill approach.
        NSColor(calibratedRed: 0.33, green: 0.55, blue: 0.78, alpha: 1).setFill()
        NSRect(origin: .zero, size: total).fill()

        // The panel no longer paints its own background -- an NSVisualEffectView
        // behind it supplies the popover's material, which is what removed the
        // seam. Offscreen there is no such view, so this stands in for it.
        // Without it the dump shows the wallpaper straight through the content
        // and reads as a regression that is not there. `--dump-live-panel`
        // remains the authority on how the material actually behaves.
        let materialStandIn = NSRect(origin: .zero, size: total).insetBy(dx: gap - 1, dy: gap - 1)
        NSColor.windowBackgroundColor.setFill()
        materialStandIn.fill()

        for (index, name) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            let origin = CGPoint(x: gap + (size.width + gap) * CGFloat(index), y: gap)
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: origin.x, yBy: origin.y)
                transform.concat()
                self.view.draw(self.view.bounds)
                NSGraphicsContext.restoreGraphicsState()
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let data = representation.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    private func focus(_ group: String) {
        focusedGroup = group
        preferredMetric = nil
        rebuild()
    }

    /// Counts and percentages are whole things; a cycle count of "109.0" reads
    /// as a measurement error rather than as a number of cycles.
    private static func decimals(for unit: MetricUnit) -> Int {
        switch unit {
        case .percent, .count, .seconds: 0
        default: 1
        }
    }

    /// The top-five list for a group, or an explanation of its absence.
    private func processSection(
        for group: String
    ) -> (title: String?, rows: [DetailPanelView.Row], note: String?) {
        if group == "GPU" {
            // Said in place rather than left as a silent gap, because "why is
            // this here for CPU and not for GPU" is the obvious question.
            return (
                Self.processHeading,
                [],
                String(
                    localized: "macOS does not attribute GPU work to processes without root, so this cannot be shown.",
                    comment: "Detail panel, in place of a process list for the GPU")
            )
        }

        guard let ranking = Self.ranking(for: group) else { return (nil, [], nil) }

        let top = processes.top(5, by: ranking)
        guard !top.isEmpty else {
            return (Self.processHeading, [], String(
                localized: "Measuring\u{2026}",
                comment: "Detail panel: the process list before its first reading"))
        }

        let formatter = ValueFormatter(decimals: ranking == .cpu ? 0 : 1)
        let rows = top.map { usage in
            DetailPanelView.Row(
                name: usage.name,
                text: ranking == .cpu
                    ? formatter.string(for: usage.cpuPercent, unit: .percent)
                    : formatter.string(for: usage.memoryBytes, unit: .bytes)
            )
        }
        return (Self.processHeading, rows, nil)
    }

    private static var processHeading: String {
        String(localized: "Top processes", comment: "Detail panel: heading over the five busiest processes")
    }

    private func refreshCatalogue() {
        descriptors.removeAll(keepingCapacity: true)

        // Grouped from the ordered array, not from `descriptors.values`. A
        // dictionary's values have no order, so grouping them and taking the
        // first gave whichever metric happened to hash first -- the CPU panel
        // opened headlined "Efficiency Cores" rather than "CPU Usage".
        //
        // Sources declare their descriptors most-important-first, and that is
        // exactly the order a panel wants, so preserving it needs no extra
        // notion of priority.
        let ordered = bus.availableMetrics()
        for descriptor in ordered { descriptors[descriptor.id] = descriptor }
        grouped = Dictionary(grouping: ordered, by: \.group)
    }

    private func rebuild() {
        guard let group = focusedGroup, let members = grouped[group] else { return }

        // Declaration order, so the headline is the metric the source considers
        // primary and the rows read in a sensible sequence.
        let ordered = members
        let headline = preferredMetric.flatMap { id in ordered.first { $0.id == id } } ?? ordered.first
        guard let headline else { return }

        // Subscribe to exactly what is on screen, and only while it is -- but
        // rebuild the subscription only when the set changes.
        //
        // This ran on every snapshot, so it cancelled and re-subscribed once a
        // second. Each cycle could drop a source's refcount to zero and
        // re-activate it, discarding the delta state that tick-counter and rate
        // sources depend on, and making values fall back to placeholders for a
        // tick at a time.
        let needed = Set(ordered.prefix(Self.rowLimit + 1).map(\.id)).union([headline.id])
        if needed != subscribedMetrics {
            subscription?.cancel()
            subscription = bus.subscribe(to: needed)
            subscribedMetrics = needed
        }

        let formatter = ValueFormatter(decimals: Self.decimals(for: headline.unit))
        let value = bus.value(for: headline.id)

        let rows = ordered
            .filter { $0.id != headline.id }
            .prefix(Self.rowLimit)
            .map { descriptor in
                let rowFormatter = ValueFormatter(decimals: Self.decimals(for: descriptor.unit))
                let text = bus.value(for: descriptor.id)
                    .map { rowFormatter.string(for: $0, unit: descriptor.unit) }
                    ?? ValueFormatter.placeholder
                return DetailPanelView.Row(name: descriptor.displayName, text: text)
            }

        let others = grouped.keys
            .filter { $0 != group }
            .map { DetailPanelView.Chip(group: $0, title: MetricDescriptor.title(ofGroup: $0)) }
            // By the name on the chip, so the footer reads alphabetically in
            // whatever language it is in.
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let (processTitle, processRows, processNote) = processSection(for: group)

        view.content = DetailPanelView.Content(
            group: MetricDescriptor.title(ofGroup: group),
            headline: headline.displayName,
            value: value.map { formatter.string(for: $0, unit: headline.unit) }
                ?? ValueFormatter.placeholder,
            history: bus.history(for: headline.id, count: 60),
            unit: headline.unit,
            range: headline.range,
            rows: Array(rows),
            processTitle: processTitle,
            processes: processRows,
            processNote: processNote,
            otherGroups: others
        )

        let size = NSSize(
            width: DetailPanelView.width,
            height: DetailPanelView.height(
                rows: rows.count,
                processes: processRows.count,
                hasNote: processNote != nil,
                hasOtherGroups: !others.isEmpty
            )
        )

        // Never assign `view.frame` here. `NSPopover` sizes its content view
        // controller's view itself, so setting the frame fights it: the first
        // paint looked right and the next relayout left the panel inset inside
        // the popover, with the material -- and the desktop behind it -- showing
        // in a band around the content.
        //
        // Only the *content size* is ours to state, and only when it actually
        // changes: assigning it on every tick re-triggers the popover's own
        // layout once a second for no reason.
        guard popover.contentSize != size else { return }
        popover.contentSize = size
    }
}
