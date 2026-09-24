import AppKit
import SensorKit
import Testing
@testable import RenderKit

@Suite("Renderer contracts")
struct RendererContractTests {
    private let context = RenderContext()

    private func percentInput(_ value: Double?) -> CellInput {
        CellInput(value: value, unit: .percent, range: .percentage)
    }

    private func rateInput(_ value: Double?, up: Double? = nil) -> CellInput {
        CellInput(
            value: value,
            unit: .bytesPerSecond,
            range: .unbounded(min: 0),
            series: up.map { [$0] } ?? []
        )
    }

    @Test("proportion styles refuse unbounded metrics")
    func proportionRequiresBounds() {
        // A ring that is 3% full implies a maximum. For throughput there is no
        // maximum, so the shape would be asserting something untrue.
        for accepts in [DonutRenderer.accepts, ArcGaugeRenderer.accepts, BarRenderer.accepts] {
            #expect(accepts(.percentage))
            #expect(accepts(.bounded(min: 0, max: 16_000_000_000)))
            #expect(!accepts(.unbounded(min: 0)))
        }
    }

    @Test("history styles accept anything")
    func historyAcceptsEverything() {
        // A graph over time carries no claim about a whole, so an unbounded
        // metric is perfectly honest -- it just needs an adaptive scale.
        #expect(HistoryGraphRenderer.accepts(.unbounded(min: 0)))
        #expect(HistogramRenderer.accepts(.unbounded(min: 0)))
        #expect(HistoryGraphRenderer.accepts(.percentage))
    }

    @Test("every style holds a constant width as its value changes")
    func widthsAreStable() {
        let renderers: [(String, any CellRenderer)] = [
            ("text", TextValueRenderer()),
            ("line", HistoryGraphRenderer(style: .line)),
            ("area", HistoryGraphRenderer(style: .area)),
            ("histogram", HistogramRenderer()),
            ("donut", DonutRenderer()),
            ("arc", ArcGaugeRenderer()),
            ("bar", BarRenderer()),
        ]

        for (name, renderer) in renderers {
            let widths = Set(
                stride(from: 0.0, through: 100.0, by: 2.5)
                    .map { renderer.width(for: percentInput($0), in: context) }
            )
            #expect(widths.count == 1, "\(name) varied: \(widths.sorted())")
            #expect(
                renderer.width(for: percentInput(nil), in: context) == widths.first,
                "\(name) changed width when the metric was unavailable"
            )
        }
    }

    @Test("one stacked rate cell is far narrower than two separate ones")
    func dualRateSavesWidth() {
        // The measurement that justifies the style existing. Two throughput
        // cells each reserve room for "888 MB/s"; one stacked cell reserves it
        // once and puts the second rate underneath.
        let single = TextValueRenderer(formatter: ValueFormatter(decimals: 0))
        let pair = single.width(for: rateInput(0), in: context) * 2

        let stacked = DualRateRenderer().width(for: rateInput(0, up: 0), in: context)

        #expect(stacked < pair * 0.6, "expected a large saving, got \(stacked) vs \(pair)")
        #expect(stacked > 0)
    }

    @Test("stacked rate width is independent of both values")
    func dualRateWidthStable() {
        let renderer = DualRateRenderer()
        let widths = Set(
            [(0.0, 0.0), (1024.0, 900.0), (6_800_000.0, 148_000.0), (900_000_000.0, 1.0)]
                .map { renderer.width(for: rateInput($0.0, up: $0.1), in: context) }
        )
        #expect(widths.count == 1, "varied: \(widths.sorted())")
    }

    @Test("core matrix widens with core count and alerts on the busiest core")
    func coreMatrix() {
        let renderer = CoreMatrixRenderer(
            groups: [6, 4],
            thresholds: Thresholds(elevated: 70, critical: 90)
        )

        func matrixInput(_ values: [Double]) -> CellInput {
            CellInput(
                value: values.first,
                unit: .percent,
                range: .percentage,
                series: values.dropFirst().map { Optional($0) }
            )
        }

        let four = renderer.width(for: matrixInput([1, 2, 3, 4]), in: context)
        let ten = renderer.width(for: matrixInput(Array(repeating: 5, count: 10)), in: context)
        #expect(ten > four)

        // One pinned core is the thing worth noticing; averaging across ten
        // would hide it entirely.
        var mostlyIdle = [Double](repeating: 2, count: 10)
        mostlyIdle[7] = 95
        #expect(renderer.severity(for: matrixInput(mostlyIdle)) == .critical)
        #expect(renderer.severity(for: matrixInput(Array(repeating: 40, count: 10))) == .nominal)
    }

    @Test("a flat graph reports no visible change")
    func flatGraphSkipsRedraw() {
        let renderer = HistoryGraphRenderer(style: .area)
        var input = percentInput(0)
        input.history = [Float](repeating: 0, count: 60)

        // The steady state for most cells most of the time: an idle graph must
        // cost a hash comparison, not a rasterisation.
        #expect(
            renderer.changeKey(for: input, in: context)
                == renderer.changeKey(for: input, in: context)
        )
    }

    @Test("graphs redraw when the trace scrolls")
    func scrollingGraphRedraws() {
        let renderer = HistoryGraphRenderer(style: .line)
        var before = percentInput(50)
        before.history = (0..<60).map { Float($0 % 30) }

        var after = percentInput(50)
        after.history = (0..<60).map { Float(($0 + 1) % 30) }

        #expect(renderer.changeKey(for: before, in: context) != renderer.changeKey(for: after, in: context))
    }
}

@Suite("Absent readings look absent")
struct UnavailableRenderingTests {
    private let context = RenderContext()

    private func bounded(_ value: Double?) -> CellInput {
        CellInput(value: value, unit: .percent, range: .percentage)
    }

    /// Rasterises a single cell and counts how many pixels carry ink.
    private func inkedPixels(_ renderer: any CellRenderer, _ input: CellInput) -> Int {
        let width = renderer.width(for: input, in: context)
        let canvas = BitmapCanvas()
        guard let image = canvas.makeImage(
            size: CGSize(width: width, height: context.height),
            scale: 2,
            draw: { cgContext in
            renderer.draw(
                input,
                in: cgContext,
                rect: CGRect(x: 0, y: 0, width: width, height: context.height),
                context: context,
                severity: .nominal
            )
        }) else { return 0 }

        guard let data = image.dataProvider?.data as Data? else { return 0 }
        var inked = 0
        // Premultiplied RGBA: the alpha byte is the last of each four.
        for index in stride(from: 3, to: data.count, by: 4) where data[index] > 8 {
            inked += 1
        }
        return inked
    }

    @Test("an empty gauge is visually distinct from one reading zero")
    func gaugesDistinguishNoReading() {
        // Before this, a sensor the Mac does not have and a sensor reporting
        // nothing drew the identical ring -- which quietly broke the promise
        // that the text placeholder keeps.
        for renderer in [AnyRendererBox(DonutRenderer()), AnyRendererBox(ArcGaugeRenderer()), AnyRendererBox(BarRenderer())] {
            let absent = inkedPixels(renderer.value, bounded(nil))
            let zero = inkedPixels(renderer.value, bounded(0))
            #expect(absent != zero, "\(type(of: renderer.value)) draws the same thing for nil and 0")
            #expect(absent > 0, "\(type(of: renderer.value)) draws nothing at all when unavailable")
        }
    }
}

/// Boxes an existential so a heterogeneous list of renderers can be iterated.
struct AnyRendererBox {
    let value: any CellRenderer
    init(_ value: any CellRenderer) { self.value = value }
}
