import AppKit
import RenderKit
import SensorKit
import Testing
@testable import LayoutEngine

@MainActor
@Suite("Strip composition")
struct StripComposerTests {

    private func descriptors() -> [MetricID: MetricDescriptor] {
        var result: [MetricID: MetricDescriptor] = [:]
        func add(_ id: MetricID, _ unit: MetricUnit, _ range: MetricRange) {
            result[id] = MetricDescriptor(id: id, displayName: "x", group: "x", unit: unit, range: range)
        }
        add(CPULoadSource.total, .percent, .percentage)
        add(MemorySource.usagePercent, .percent, .percentage)
        add(MemorySource.pressure, .count, .bounded(min: 0, max: 2))
        add(NetworkSource.downloadRate, .bytesPerSecond, .unbounded(min: 0))
        add(NetworkSource.uploadRate, .bytesPerSecond, .unbounded(min: 0))
        return result
    }

    /// The default strip, built directly rather than decoded, so these tests
    /// exercise composition without depending on the document layer.
    private func overview() -> Widget {
        Widget(name: "Overview", cells: [
            Cell(
                metric: CPULoadSource.total,
                renderer: TextValueRenderer(
                    formatter: ValueFormatter(decimals: 0),
                    thresholds: Thresholds(elevated: 70, critical: 90)
                ),
                label: "CPU"
            ),
            Cell(
                metric: CPULoadSource.total,
                renderer: HistoryGraphRenderer(style: .area, capacity: 60),
                historyDepth: 60
            ),
            Cell(
                metric: MemorySource.usagePercent,
                renderer: DonutRenderer(thresholds: Thresholds(elevated: 1, critical: 2)),
                alertMetric: MemorySource.pressure
            ),
            Cell(
                metric: NetworkSource.downloadRate,
                renderer: DualRateRenderer(),
                series: [NetworkSource.uploadRate]
            ),
        ])
    }

    private func frame(cpu: Double = 20, pressure: Double = 0) -> StripComposer.Frame {
        StripComposer.Frame(
            values: [
                CPULoadSource.total: cpu,
                MemorySource.usagePercent: 76,
                MemorySource.pressure: pressure,
                NetworkSource.downloadRate: 6_800_000,
                NetworkSource.uploadRate: 148_000,
            ],
            histories: [CPULoadSource.total: (0..<60).map { Float($0 % 40) }],
            descriptors: descriptors()
        )
    }

    @Test("the default strip fits in a sensible amount of menu bar")
    func defaultStripWidth() throws {
        let composer = StripComposer()
        let image = try #require(composer.compose(overview(), frame: frame(), context: RenderContext()))

        // M1's default was 279pt, nearly all of it two throughput cells each
        // reserving room for "888 MB/s". Stacking them and swapping the memory
        // number for a donut brought it under 200 while adding a graph.
        #expect(image.size.width < 210, "default strip grew to \(image.size.width)pt")
        #expect(image.size.width > 120, "suspiciously narrow: cells may not be rendering")
        #expect(image.size.height == 22)
    }

    @Test("an unchanged frame is not redrawn")
    func skipsIdenticalFrames() throws {
        let composer = StripComposer()
        let context = RenderContext()

        #expect(composer.compose(overview(), frame: frame(), context: context) != nil)
        // Same numbers, same pixels: the second call must decline to rasterise.
        #expect(composer.compose(overview(), frame: frame(), context: context) == nil)
    }

    @Test("a visible change is redrawn")
    func redrawsOnChange() throws {
        let composer = StripComposer()
        let context = RenderContext()

        _ = composer.compose(overview(), frame: frame(cpu: 20), context: context)
        #expect(composer.compose(overview(), frame: frame(cpu: 55), context: context) != nil)
    }

    @Test("invalidate forces a redraw without a data change")
    func invalidateForcesRedraw() throws {
        let composer = StripComposer()
        let context = RenderContext()

        _ = composer.compose(overview(), frame: frame(), context: context)
        composer.invalidate()
        // Appearance and display changes alter pixels without altering values,
        // so there has to be a way to say "draw it again anyway".
        #expect(composer.compose(overview(), frame: frame(), context: context) != nil)
    }

    @Test("the strip is a template until something alerts")
    func templateUntilAlerting() throws {
        let composer = StripComposer()
        let context = RenderContext()

        let calm = try #require(composer.compose(overview(), frame: frame(pressure: 0), context: context))
        #expect(calm.isTemplate, "a quiet strip must let AppKit tint it to match the menu bar")

        composer.invalidate()
        let alerting = try #require(composer.compose(overview(), frame: frame(pressure: 2), context: context))
        #expect(!alerting.isTemplate, "an alerting strip carries its own colour")
    }

    @Test("a widget declares every metric it reads")
    func requiredMetricsAreComplete() {
        let required = overview().requiredMetrics

        // Missing any of these means the bus never activates its source and the
        // cell silently renders a placeholder forever.
        #expect(required.contains(CPULoadSource.total))
        #expect(required.contains(MemorySource.usagePercent))
        #expect(required.contains(MemorySource.pressure), "alert metrics must be subscribed too")
        #expect(required.contains(NetworkSource.downloadRate))
        #expect(required.contains(NetworkSource.uploadRate), "series metrics must be subscribed too")
    }

    @Test("an unavailable metric keeps its space")
    func unknownMetricHoldsLayout() throws {
        let composer = StripComposer()
        let context = RenderContext()

        let widget = Widget(name: "t", cells: [
            Cell(metric: "does.not.exist", renderer: TextValueRenderer(), label: "GPU")
        ])
        let empty = StripComposer.Frame(values: [:], descriptors: [:])

        // A widget shared from a machine with hardware this one lacks must keep
        // its shape rather than collapsing.
        let image = try #require(composer.compose(widget, frame: empty, context: context))
        #expect(image.size.width > 20)
    }
}

@MainActor
@Suite("Cell hit testing")
struct CellHitTestingTests {

    private func widget() -> Widget {
        Widget(name: "t", cells: [
            Cell(metric: "a", renderer: TextValueRenderer(), label: "A"),
            Cell(metric: "b", renderer: DonutRenderer()),
            Cell(metric: "c", renderer: TextValueRenderer(), label: "C"),
        ])
    }

    private func frame() -> StripComposer.Frame {
        var descriptors: [MetricID: MetricDescriptor] = [:]
        for id in ["a", "b", "c"] as [MetricID] {
            descriptors[id] = MetricDescriptor(
                id: id, displayName: "d", group: "g", unit: .percent, range: .percentage
            )
        }
        return StripComposer.Frame(values: ["a": 10, "b": 20, "c": 30], descriptors: descriptors)
    }

    @Test("frames cover the strip in order, without overlapping")
    func framesAreOrdered() throws {
        let composer = StripComposer()
        _ = composer.compose(widget(), frame: frame(), context: RenderContext())

        let frames = composer.cellFrames
        #expect(frames.count == 3)
        for (earlier, later) in zip(frames, frames.dropFirst()) {
            #expect(earlier.maxX <= later.minX, "cells overlap: \(frames)")
        }
    }

    @Test("a click lands on the cell under it")
    func clickResolvesToCell() throws {
        let composer = StripComposer()
        _ = composer.compose(widget(), frame: frame(), context: RenderContext())

        for (index, cellFrame) in composer.cellFrames.enumerated() {
            let hit = composer.cellIndex(at: CGPoint(x: cellFrame.midX, y: 11))
            #expect(hit == index, "midpoint of cell \(index) resolved to \(hit as Any)")
        }
    }

    @Test("a click in the gap picks the nearest cell rather than nothing")
    func gapsBelongToNeighbours() throws {
        let composer = StripComposer()
        _ = composer.compose(widget(), frame: frame(), context: RenderContext())
        let frames = composer.cellFrames

        // Spacing between cells is dead space in the image. Returning nil there
        // would make the panel occasionally not open for no visible reason.
        let gap = (frames[0].maxX + frames[1].minX) / 2
        #expect(composer.cellIndex(at: CGPoint(x: gap, y: 11)) != nil)

        // Past either end, the outermost cell still wins.
        #expect(composer.cellIndex(at: CGPoint(x: -50, y: 11)) == 0)
        #expect(composer.cellIndex(at: CGPoint(x: 9999, y: 11)) == 2)
    }

    @Test("frames stay current even when the strip is not redrawn")
    func framesSurviveSkippedRedraws() throws {
        let composer = StripComposer()
        _ = composer.compose(widget(), frame: frame(), context: RenderContext())
        let first = composer.cellFrames

        // The second compose returns nil because nothing changed. Hit testing
        // still has to work, or clicking would break on every tick that produced
        // no visible change -- which is most of them.
        #expect(composer.compose(widget(), frame: frame(), context: RenderContext()) == nil)
        #expect(composer.cellFrames == first)
    }
}

@MainActor
@Suite("Adornments")
struct AdornmentTests {

    private func descriptors() -> [MetricID: MetricDescriptor] {
        ["m": MetricDescriptor(id: "m", displayName: "d", group: "g", unit: .percent, range: .percentage)]
    }

    private func frame() -> StripComposer.Frame {
        StripComposer.Frame(values: ["m": 42], descriptors: descriptors())
    }

    private func widget(_ adornment: CellAdornment, _ renderer: any CellRenderer) -> Widget {
        Widget(name: "t", cells: [Cell(metric: "m", renderer: renderer, adornment: adornment)])
    }

    /// Every style, including the six that used to ignore labels entirely.
    private var everyStyle: [(String, any CellRenderer)] {
        [
            ("text", TextValueRenderer()),
            ("line", HistoryGraphRenderer(style: .line)),
            ("area", HistoryGraphRenderer(style: .area)),
            ("histogram", HistogramRenderer()),
            ("donut", DonutRenderer()),
            ("arc", ArcGaugeRenderer()),
            ("bar", BarRenderer()),
            ("cores", CoreMatrixRenderer(groups: [2, 2])),
            ("dual", DualRateRenderer()),
        ]
    }

    @Test("a caption widens every style, not just the text one")
    func captionReservesWidthEverywhere() throws {
        // The original bug: only TextValueRenderer handled labels, so setting one
        // on a donut reserved no width and drew nothing at all.
        let composer = StripComposer()
        let context = RenderContext()

        for (name, renderer) in everyStyle {
            composer.invalidate()
            let bare = try #require(composer.compose(widget(.none, renderer), frame: frame(), context: context))
            composer.invalidate()
            let labelled = try #require(
                composer.compose(widget(.text("MEM"), renderer), frame: frame(), context: context)
            )
            #expect(labelled.size.width > bare.size.width,
                    "\(name) did not make room for its caption")
        }
    }

    @Test("an icon widens every style too")
    func symbolReservesWidthEverywhere() throws {
        let composer = StripComposer()
        let context = RenderContext()

        for (name, renderer) in everyStyle {
            composer.invalidate()
            let bare = try #require(composer.compose(widget(.none, renderer), frame: frame(), context: context))
            composer.invalidate()
            let adorned = try #require(
                composer.compose(widget(.symbol("cpu"), renderer), frame: frame(), context: context)
            )
            #expect(adorned.size.width > bare.size.width, "\(name) did not make room for its symbol")
        }
    }

    @Test("changing the adornment forces a redraw")
    func adornmentIsInTheRedrawKey() throws {
        // The adornment can change with no value changing at all, which is
        // exactly what happens when someone types a label in the editor.
        let composer = StripComposer()
        let context = RenderContext()

        #expect(composer.compose(widget(.text("CPU"), TextValueRenderer()), frame: frame(), context: context) != nil)
        #expect(composer.compose(widget(.text("CPU"), TextValueRenderer()), frame: frame(), context: context) == nil)
        #expect(composer.compose(widget(.text("MEM"), TextValueRenderer()), frame: frame(), context: context) != nil)
    }

    @Test("an emoji forces the strip to carry its own colour")
    func emojiBreaksTemplate() throws {
        let composer = StripComposer()
        let context = RenderContext()

        composer.invalidate()
        let plain = try #require(composer.compose(widget(.text("CPU"), TextValueRenderer()), frame: frame(), context: context))
        #expect(plain.isTemplate)

        composer.invalidate()
        let emoji = try #require(composer.compose(widget(.emoji("\u{1F525}"), TextValueRenderer()), frame: frame(), context: context))
        // A template image is alpha-only, which would flatten the emoji into a
        // silhouette and lose the only reason to use one.
        #expect(!emoji.isTemplate)
    }

    @Test("an unknown symbol name takes no space rather than leaving a hole")
    func unknownSymbolIsIgnored() throws {
        let composer = StripComposer()
        let context = RenderContext()

        composer.invalidate()
        let bare = try #require(composer.compose(widget(.none, TextValueRenderer()), frame: frame(), context: context))
        composer.invalidate()
        let bogus = try #require(
            composer.compose(widget(.symbol("not.a.real.symbol.name"), TextValueRenderer()),
                             frame: frame(), context: context)
        )
        // A widget naming a symbol this macOS lacks should look like it has no
        // icon, not like it is broken.
        #expect(bogus.size.width == bare.size.width)
    }

    @Test("hit testing accounts for the adornment")
    func framesIncludeAdornments() throws {
        let composer = StripComposer()
        let context = RenderContext()
        let two = Widget(name: "t", cells: [
            Cell(metric: "m", renderer: TextValueRenderer(), adornment: .text("CPU")),
            Cell(metric: "m", renderer: DonutRenderer(), adornment: .symbol("memorychip")),
        ])

        _ = composer.compose(two, frame: frame(), context: context)
        let frames = composer.cellFrames
        #expect(frames.count == 2)
        // Clicking the caption must resolve to its own cell, not the previous one.
        #expect(composer.cellIndex(at: CGPoint(x: frames[1].minX + 2, y: 11)) == 1)
    }

    @Test("a strip wider than the backstop is cut off rather than allocated")
    func widthIsCapped() throws {
        // Imports are refused long before this; the cap is for a hand-edited
        // layout.json, which nothing checks. Two hundred 80pt spacers would be
        // a 17,000pt strip.
        let wide = Widget(name: "w", cells: (0..<200).map { _ in
            Cell(renderer: SpacerRenderer(width: 80))
        })
        let image = try #require(StripComposer().compose(wide, frame: frame(), context: RenderContext()))
        #expect(image.size.width == StripComposer.maximumWidth)
    }
}
