import AppKit
import SensorKit
import Testing
@testable import RenderKit

@Suite("Value formatting")
struct ValueFormatterTests {

    @Test("percent formatting respects decimals")
    func percent() {
        #expect(ValueFormatter(decimals: 0).string(for: 41.6, unit: .percent) == "42%")
        #expect(ValueFormatter(decimals: 1).string(for: 41.64, unit: .percent) == "41.6%")
        #expect(ValueFormatter(decimals: 0, showsUnit: false).string(for: 41.6, unit: .percent) == "42")
    }

    @Test("byte rates step up through units")
    func byteRates() {
        let formatter = ValueFormatter(decimals: 1)
        // Adaptive precision has already kicked in by three integer digits.
        #expect(formatter.string(for: 512, unit: .bytesPerSecond) == "512 B/s")
        #expect(formatter.string(for: 64, unit: .bytesPerSecond) == "64.0 B/s")
        #expect(formatter.string(for: 1536, unit: .bytesPerSecond) == "1.5 KB/s")
        #expect(formatter.string(for: 1_572_864, unit: .bytesPerSecond) == "1.5 MB/s")
    }

    @Test("drops decimals once the integer part is three digits")
    func adaptivePrecision() {
        let formatter = ValueFormatter(decimals: 1)
        // Keeps the rendered string at a constant character count as the value
        // grows, which is what lets the cell hold a fixed width.
        #expect(formatter.string(for: 150 * 1_048_576, unit: .bytesPerSecond) == "150 MB/s")
    }

    @Test("non-finite values render as a placeholder, never as nan")
    func handlesNaN() {
        let formatter = ValueFormatter(decimals: 1)
        #expect(formatter.string(for: .nan, unit: .percent) == "\u{2013}")
        #expect(formatter.string(for: .infinity, unit: .bytesPerSecond) == "\u{2013}")
    }

    @Test("widest string bounds every value in a bounded range")
    func widestCoversRange() {
        let formatter = ValueFormatter(decimals: 0)
        let widest = formatter.widestString(for: .percent, range: .percentage)
        #expect(widest == "888%")

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        let reserved = width(of: widest, font: font)

        for value in stride(from: 0.0, through: 100.0, by: 1.0) {
            let rendered = formatter.string(for: value, unit: .percent)
            #expect(width(of: rendered, font: font) <= reserved,
                    "\(rendered) overflows the reserved width")
        }
    }

    private func width(of text: String, font: NSFont) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        return CTLineGetTypographicBounds(
            CTLineCreateWithAttributedString(attributed), nil, nil, nil
        )
    }
}

@Suite("Text cell")
struct TextValueRendererTests {

    private func input(_ value: Double?) -> CellInput {
        CellInput(value: value, unit: .percent, range: .percentage, label: "CPU")
    }

    @Test("cell width never changes with the value")
    func widthIsStable() {
        // The whole reason the menu bar does not reflow while you watch it.
        let renderer = TextValueRenderer()
        let context = RenderContext()

        let widths = Set(
            stride(from: 0.0, through: 100.0, by: 0.5)
                .map { renderer.width(for: input($0), in: context) }
        )

        #expect(widths.count == 1, "width varied across values: \(widths.sorted())")
        #expect(renderer.width(for: input(nil), in: context) == widths.first)
    }

    @Test("change key collapses invisible differences")
    func changeKeySkipsNoise() {
        let renderer = TextValueRenderer(formatter: ValueFormatter(decimals: 0))
        let context = RenderContext()

        // 41.2 and 41.4 both render "41%" -- one comparison instead of a
        // rasterisation.
        #expect(
            renderer.changeKey(for: input(41.2), in: context)
                == renderer.changeKey(for: input(41.4), in: context)
        )
        #expect(
            renderer.changeKey(for: input(41.2), in: context)
                != renderer.changeKey(for: input(42.7), in: context)
        )
    }

    @Test("change key reflects a threshold crossing even at the same digits")
    func changeKeyTracksSeverity() {
        let renderer = TextValueRenderer(
            formatter: ValueFormatter(decimals: 0),
            thresholds: Thresholds(elevated: 70)
        )
        let context = RenderContext()

        // Both render "70%", but one is orange.
        #expect(
            renderer.changeKey(for: input(69.6), in: context)
                != renderer.changeKey(for: input(70.4), in: context)
        )
    }

    @Test("severity follows thresholds")
    func severity() {
        let renderer = TextValueRenderer(
            thresholds: Thresholds(elevated: 70, critical: 90)
        )
        #expect(renderer.severity(for: input(10)) == .nominal)
        #expect(renderer.severity(for: input(75)) == .elevated)
        #expect(renderer.severity(for: input(95)) == .critical)
        #expect(renderer.severity(for: input(nil)) == .nominal)
    }

    @Test("a cell with no thresholds is always quiet")
    func defaultsToQuiet() {
        let renderer = TextValueRenderer()
        #expect(renderer.severity(for: input(100)) == .nominal)
    }
}

@Suite("Canvas")
struct BitmapCanvasTests {

    @Test("produces an image at the requested backing scale")
    func honoursScale() throws {
        let canvas = BitmapCanvas()
        let image = try #require(
            canvas.makeImage(size: CGSize(width: 40, height: 22), scale: 2.0) { context in
                context.setFillColor(NSColor.black.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: 40, height: 22))
            }
        )

        #expect(image.width == 80)
        #expect(image.height == 44)
    }

    @Test("reuses its context across frames of the same geometry")
    func reusesContext() throws {
        let canvas = BitmapCanvas()
        let size = CGSize(width: 40, height: 22)

        let first = try #require(canvas.makeImage(size: size, scale: 2.0) { _ in })
        let second = try #require(canvas.makeImage(size: size, scale: 2.0) { context in
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
        })

        // Same geometry, and the previous frame must not bleed through.
        #expect(first.width == second.width)
        #expect(first.height == second.height)
    }
}

@Suite("Alerting on a different metric")
struct AlertValueTests {

    private let renderer = TextValueRenderer(
        formatter: ValueFormatter(decimals: 0),
        thresholds: Thresholds(elevated: 1, critical: 2)
    )

    /// The memory case: the cell shows 78% used, which would breach any sane
    /// percentage threshold, while the kernel reports no pressure at all.
    private func memoryCell(used: Double, pressure: Double?) -> CellInput {
        CellInput(
            value: used,
            unit: .percent,
            range: .percentage,
            label: "MEM",
            alertValue: pressure
        )
    }

    @Test("severity follows the alert metric, not the displayed value")
    func alertValueWins() {
        // 78% used but pressure normal: stays quiet, which is the entire point.
        #expect(renderer.severity(for: memoryCell(used: 78, pressure: 0)) == .nominal)
        #expect(renderer.severity(for: memoryCell(used: 78, pressure: 1)) == .elevated)
        #expect(renderer.severity(for: memoryCell(used: 78, pressure: 2)) == .critical)

        // Low usage with high pressure still alerts -- the number on screen has
        // no vote.
        #expect(renderer.severity(for: memoryCell(used: 12, pressure: 2)) == .critical)
    }

    @Test("falls back to the displayed value when no alert metric is bound")
    func fallsBackToValue() {
        #expect(renderer.severity(for: memoryCell(used: 0, pressure: nil)) == .nominal)
        #expect(renderer.severity(for: memoryCell(used: 3, pressure: nil)) == .critical)
    }

    @Test("the displayed digits are unaffected by the alert metric")
    func alertDoesNotChangeTheNumber() {
        let context = RenderContext()
        let quiet = renderer.changeKey(for: memoryCell(used: 78, pressure: 0), in: context)
        let loud = renderer.changeKey(for: memoryCell(used: 78, pressure: 2), in: context)

        // Same number, different severity: the keys must differ so the colour
        // change forces a redraw, but both must still render "78%".
        #expect(quiet != loud)
        #expect(quiet.hasPrefix("78%"))
        #expect(loud.hasPrefix("78%"))
    }
}

@Suite("Two-column value layout")
struct ValueColumnTests {

    @Test("number and unit are measured independently")
    func componentsSplit() {
        let formatter = ValueFormatter(decimals: 1)

        #expect(formatter.components(for: 42, unit: .percent) == .init(number: "42.0", suffix: "%"))
        #expect(formatter.components(for: 1536, unit: .bytesPerSecond) == .init(number: "1.5", suffix: " KB/s"))
        #expect(formatter.components(for: 48, unit: .celsius) == .init(number: "48.0", suffix: "\u{00B0}"))

        // A placeholder must never acquire a unit: "-%" is not a reading.
        #expect(formatter.components(for: .nan, unit: .percent).suffix.isEmpty)
    }

    @Test("joined components match the single-string formatter")
    func componentsAgreeWithString() {
        let formatter = ValueFormatter(decimals: 1)
        for value in [0.0, 7.5, 512, 1536, 1_572_864, 157_286_400] as [Double] {
            for unit in [MetricUnit.percent, .bytes, .bytesPerSecond, .celsius] {
                #expect(
                    formatter.components(for: value, unit: unit).joined
                        == formatter.string(for: value, unit: unit)
                )
            }
        }
    }

    @Test("the unit column never moves as the magnitude changes")
    func unitColumnIsFixed() {
        // The reason for splitting the columns at all: "7 KB/s" and "888 MB/s"
        // must place their unit at the same x, or a strip of cells stops
        // lining up and the whole thing reads as noise.
        let formatter = ValueFormatter(decimals: 0)
        let widest = formatter.widestComponents(for: .bytesPerSecond, range: .unbounded(min: 0))
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)

        func width(_ text: String) -> CGFloat {
            CTLineGetTypographicBounds(
                CTLineCreateWithAttributedString(
                    NSAttributedString(string: text, attributes: [.font: font])
                ), nil, nil, nil
            )
        }

        let numberSlot = width(widest.number)
        for value in [0.0, 7, 512, 1536, 1_572_864, 943_718_400] as [Double] {
            let parts = formatter.components(for: value, unit: .bytesPerSecond)
            #expect(width(parts.number) <= numberSlot,
                    "\(parts.number) overflows the number column")
            #expect(width(parts.suffix) <= width(widest.suffix),
                    "\(parts.suffix) overflows the unit column")
        }
    }
}

@Suite("Duration formatting")
struct DurationFormattingTests {
    private let formatter = ValueFormatter(decimals: 0)

    @Test("durations read as durations, not as second counts")
    func readsAsDuration() {
        // Battery time remaining arrives in seconds. "7140s" is accurate and
        // useless; "1h 59m" is the same fact in the form a person holds it in.
        #expect(formatter.string(for: 7140, unit: .seconds) == "1h 59m")
        #expect(formatter.string(for: 3600, unit: .seconds) == "1h 0m")
        #expect(formatter.string(for: 750, unit: .seconds) == "12m")
        // Beyond a day, hours alone stop being readable -- and 191h is wider
        // than a two-digit hour reservation, which is how this was found.
        #expect(formatter.string(for: 691_200, unit: .seconds) == "8d 0h")
        #expect(formatter.string(for: 690_000, unit: .seconds) == "7d 23h")
        #expect(formatter.string(for: 45, unit: .seconds) == "45s")
        #expect(formatter.string(for: 0, unit: .seconds) == "0s")
    }

    @Test("the reservation covers the longest duration it can print")
    func durationWidthIsStable() {
        let widest = formatter.widestComponents(for: .seconds, range: .unbounded(min: 0))
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)

        func width(_ text: String) -> CGFloat {
            CTLineGetTypographicBounds(
                CTLineCreateWithAttributedString(
                    NSAttributedString(string: text, attributes: [.font: font])
                ), nil, nil, nil
            )
        }

        // Up to three years, so the days tier is covered as well.
        for seconds in [0.0, 45, 750, 3600, 7140, 86_399, 690_000, 8_640_000, 94_608_000] as [Double] {
            let rendered = formatter.string(for: seconds, unit: .seconds)
            #expect(width(rendered) <= width(widest.joined),
                    "\(rendered) overflows the reserved width")
        }
    }

    @Test("a placeholder is still a placeholder")
    func nonFiniteDuration() {
        #expect(formatter.string(for: .nan, unit: .seconds) == ValueFormatter.placeholder)
    }
}
