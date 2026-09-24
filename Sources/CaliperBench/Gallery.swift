import AppKit
import CoreGraphics
import Foundation
import ImageIO
import LayoutEngine
import RenderKit
import SchemaKit
import SensorKit

/// Renders every cell style side by side, in both appearances, from synthetic
/// data.
///
/// The live preview shows the real strip but cannot show a graph properly --
/// three seconds of sampling is three points out of sixty, so the plot is a stub
/// in the corner. Design review needs a full window of plausible data, and it
/// needs every style at once so they can be judged as a set rather than one at a
/// time.
@MainActor
enum Gallery {
    private static let percentMetric: MetricID = "demo.percent"
    private static let rateMetric: MetricID = "demo.rate"
    private static func coreMetric(_ index: Int) -> MetricID { MetricID("demo.core.\(index)") }

    private static let coreGroups = [6, 4]

    static func write(to path: String, scale: CGFloat = 3) throws {
        let entries = makeEntries()
        let composed = try entries.map { entry in
            (entry.caption, try render(entry, appearance: .darkAqua), try render(entry, appearance: .aqua))
        }

        let captionWidth: CGFloat = 158
        let swatchWidth = composed.map { max($0.1.size.width, $0.2.size.width) }.max() ?? 60
        let padding: CGFloat = 10
        let rowHeight: CGFloat = 30
        let columnWidth = swatchWidth + padding * 2

        let width = captionWidth + columnWidth * 2
        let height = rowHeight * CGFloat(composed.count) + padding

        guard let context = CGContext(
            data: nil,
            width: Int(width * scale), height: Int(height * scale),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PreviewRenderer.PreviewError.noContext }

        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.52, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for (index, entry) in composed.enumerated() {
            // Top-down reading order in a bottom-up coordinate space.
            let y = height - CGFloat(index + 1) * rowHeight
            let row = CGRect(x: 0, y: y, width: width, height: rowHeight)

            caption(entry.0, in: CGRect(x: padding, y: row.minY, width: captionWidth - padding, height: rowHeight), context: context)

            PreviewRenderer.drawSwatch(
                entry.1, dark: true, context: context,
                in: CGRect(x: captionWidth, y: row.minY, width: columnWidth, height: rowHeight)
            )
            PreviewRenderer.drawSwatch(
                entry.2, dark: false, context: context,
                in: CGRect(x: captionWidth + columnWidth, y: row.minY, width: columnWidth, height: rowHeight)
            )
        }

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil
              ) else { throw PreviewRenderer.PreviewError.noDestination }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PreviewRenderer.PreviewError.writeFailed
        }
    }

    // MARK: - Content

    private struct Entry {
        let caption: String
        let widget: Widget
    }

    private static func makeEntries() -> [Entry] {
        let busy = Thresholds(elevated: 70, critical: 90)

        var entries: [Entry] = [
            Entry(caption: "text.value", widget: single(
                Cell(metric: percentMetric,
                     renderer: TextValueRenderer(formatter: ValueFormatter(decimals: 0), thresholds: busy),
                     label: "CPU")
            )),
            Entry(caption: "graph.history\nline", widget: single(
                Cell(metric: percentMetric,
                     renderer: HistoryGraphRenderer(style: .line, thresholds: busy),
                     historyDepth: 60)
            )),
            Entry(caption: "graph.history\narea", widget: single(
                Cell(metric: percentMetric,
                     renderer: HistoryGraphRenderer(style: .area, thresholds: busy),
                     historyDepth: 60)
            )),
            Entry(caption: "graph.histogram", widget: single(
                Cell(metric: percentMetric,
                     renderer: HistogramRenderer(thresholds: busy),
                     historyDepth: 60)
            )),
            Entry(caption: "graph.history\narea (rate)", widget: single(
                Cell(metric: rateMetric,
                     renderer: HistoryGraphRenderer(style: .area),
                     historyDepth: 60)
            )),
            Entry(caption: "gauge.donut", widget: single(
                Cell(metric: percentMetric, renderer: DonutRenderer(thresholds: busy))
            )),
            Entry(caption: "gauge.arc", widget: single(
                Cell(metric: percentMetric, renderer: ArcGaugeRenderer(thresholds: busy))
            )),
            Entry(caption: "gauge.bar", widget: single(
                Cell(metric: percentMetric, renderer: BarRenderer(thresholds: busy))
            )),
            Entry(caption: "matrix.cores\n6E + 4P", widget: single(
                Cell(metric: coreMetric(0),
                     renderer: CoreMatrixRenderer(groups: coreGroups, thresholds: busy),
                     series: (1..<10).map(coreMetric))
            )),
            Entry(caption: "text.dual-rate", widget: single(
                Cell(metric: rateMetric,
                     renderer: DualRateRenderer(),
                     series: [MetricID("demo.rate.up")])
            )),
            Entry(caption: "alerting\n(critical)", widget: single(
                Cell(metric: MetricID("demo.hot"),
                     renderer: TextValueRenderer(formatter: ValueFormatter(decimals: 0), thresholds: busy),
                     label: "CPU")
            )),
            Entry(caption: "unavailable\nmetric", widget: single(
                Cell(metric: MetricID("demo.missing"),
                     renderer: TextValueRenderer(formatter: ValueFormatter(decimals: 0)),
                     label: "GPU")
            )),
        ]

        // Adornments on styles that previously ignored them entirely.
        entries += [
            Entry(caption: "donut\n+ caption", widget: single(
                Cell(metric: percentMetric, renderer: DonutRenderer(thresholds: busy), label: "MEM")
            )),
            Entry(caption: "donut\n+ symbol", widget: single(
                Cell(metric: percentMetric, renderer: DonutRenderer(thresholds: busy),
                     adornment: .symbol("memorychip"))
            )),
            Entry(caption: "arc\n+ symbol", widget: single(
                Cell(metric: percentMetric, renderer: ArcGaugeRenderer(thresholds: busy),
                     adornment: .symbol("thermometer.medium"))
            )),
            Entry(caption: "graph\n+ caption", widget: single(
                Cell(metric: percentMetric, renderer: HistoryGraphRenderer(style: .area, thresholds: busy),
                     historyDepth: 60, label: "CPU")
            )),
            Entry(caption: "bar\n+ emoji", widget: single(
                Cell(metric: percentMetric, renderer: BarRenderer(thresholds: busy),
                     adornment: .emoji("\u{1F525}"))
            )),
            Entry(caption: "cores\n+ symbol", widget: single(
                Cell(metric: coreMetric(0),
                     renderer: CoreMatrixRenderer(groups: coreGroups, thresholds: busy),
                     adornment: .symbol("cpu"),
                     series: (1..<10).map(coreMetric))
            )),
            Entry(caption: "stacked rates\n+ symbol", widget: single(
                Cell(metric: rateMetric, renderer: DualRateRenderer(),
                     adornment: .symbol("network"),
                     series: [MetricID("demo.rate.up")])
            )),
        ]

        // The width fix: a byte metric bounded by installed RAM used to reserve
        // eleven integer digits to show "11.9 GB".
        let bytesMetric = MetricID("demo.bytes")
        entries += [
            Entry(caption: "bytes\n(bounded 16 GB)", widget: single(
                Cell(metric: bytesMetric,
                     renderer: TextValueRenderer(formatter: ValueFormatter(decimals: 1)),
                     label: "MEM")
            )),
            Entry(caption: "spacer + divider", widget: Widget(name: "d", cells: [
                Cell(metric: percentMetric, renderer: TextValueRenderer(), label: "CPU"),
                Cell(renderer: DividerRenderer()),
                Cell(metric: bytesMetric,
                     renderer: TextValueRenderer(formatter: ValueFormatter(decimals: 1)), label: "MEM"),
                Cell(renderer: SpacerRenderer(width: 18)),
                Cell(metric: percentMetric, renderer: DonutRenderer()),
            ])),
            Entry(caption: "tight spacing\n(gap 1)", widget: Widget(name: "t", cells: [
                Cell(metric: percentMetric, renderer: TextValueRenderer(), label: "CPU"),
                Cell(metric: percentMetric, renderer: DonutRenderer()),
                Cell(metric: percentMetric, renderer: ArcGaugeRenderer()),
            ], spacing: 1)),
            Entry(caption: "wide spacing\n(gap 16)", widget: Widget(name: "w", cells: [
                Cell(metric: percentMetric, renderer: TextValueRenderer(), label: "CPU"),
                Cell(metric: percentMetric, renderer: DonutRenderer()),
                Cell(metric: percentMetric, renderer: ArcGaugeRenderer()),
            ], spacing: 16)),
        ]

        let clockMetric = MetricID("demo.clock")
        func clock(_ caption: String, _ format: String, _ syntax: ClockFormat.Syntax,
                   _ zone: String? = nil, _ adornment: CellAdornment = .none) -> Entry {
            Entry(caption: caption, widget: single(
                Cell(metric: clockMetric,
                     renderer: ClockRenderer(format: ClockFormat(
                         format: format, syntax: syntax, timeZone: zone
                     )),
                     adornment: adornment)
            ))
        }

        entries += [
            clock("clock\n24-hour", "HH:mm", .pattern),
            clock("clock\nwith seconds", "HH:mm:ss", .pattern),
            clock("clock\n12-hour", "h:mm a", .pattern),
            clock("clock\ndate + time", "EEE d MMM  HH:mm", .pattern, nil, .symbol("clock")),
            clock("clock\ntwo rows", "EEE d MMM\nHH:mm:ss", .pattern),
            clock("clock\nstrftime", "%a %d %b %H:%M", .strftime),
            clock("clock\nTokyo (%Z)", "%H:%M %Z", .strftime, "Asia/Tokyo"),
        ]

        entries.append(
            Entry(
                caption: "the default\nstrip",
                widget: WidgetDocument.overview()
                    .resolve(in: ResolutionContext(descriptors: demoDescriptors(), coreGroups: coreGroups))
                    .widget
            )
        )
        return entries
    }

    private static func single(_ cell: Cell) -> Widget {
        Widget(name: "demo", cells: [cell])
    }

    // MARK: - Synthetic data

    /// A plausible CPU trace: a slow swell with short spikes on top, so the
    /// scaling and the line joins are exercised by something shaped like real
    /// data rather than by a sine wave.
    private static func percentHistory() -> [Float] {
        // Shaped like a machine actually doing something: a raised plateau in
        // the middle, a couple of short bursts, and low chatter either side.
        // A sine wave would exercise the renderer but tell you nothing about
        // whether the result is readable.
        (0..<60).map { index in
            let plateau: Double = (18...38).contains(index) ? 46 : 14
            let burst: Double = (index == 24 || index == 25 || index == 47) ? 34 : 0
            let jitter = Double((index &* 37) % 11) - 5
            return Float(min(96, max(4, plateau + burst + jitter)))
        }
    }

    /// Bursty traffic: mostly idle with two transfers, which is what makes the
    /// floor in the adaptive scale worth having.
    private static func rateHistory() -> [Float] {
        (0..<60).map { index in
            switch index {
            case 14...22: Float(6_500_000 + 900_000 * sin(Double(index)))
            case 40...46: Float(2_400_000)
            default: Float(Int.random(in: 2_000...40_000))
            }
        }
    }

    private static func demoDescriptors() -> [MetricID: MetricDescriptor] {
        frame().descriptors
    }

    private static func frame() -> StripComposer.Frame {
        var values: [MetricID: Double] = [
            percentMetric: 42,
            rateMetric: 6_800_000,
            MetricID("demo.rate.up"): 148_000,
            MetricID("demo.hot"): 94,
            MetricID("demo.bytes"): 12_800_000_000,
            MetricID("demo.clock"): Date().timeIntervalSince1970,
        ]
        // A heterogeneous load: efficiency cores busy, performance cores mostly
        // idle, which is the state the grouping exists to make visible.
        // Deliberately under the 70% threshold: the grouping is what this row
        // is demonstrating, and an alerting colour would just distract from it.
        // Efficiency cores busy, performance cores mostly idle -- the state the
        // cluster split exists to make visible at a glance.
        let cores: [Double] = [62, 58, 48, 55, 34, 41, 8, 4, 11, 3]
        for (index, value) in cores.enumerated() { values[coreMetric(index)] = value }

        func descriptor(_ id: MetricID, _ unit: MetricUnit, _ range: MetricRange) -> MetricDescriptor {
            MetricDescriptor(id: id, displayName: "Demo", group: "Demo", unit: unit, range: range)
        }

        var descriptors: [MetricID: MetricDescriptor] = [
            percentMetric: descriptor(percentMetric, .percent, .percentage),
            rateMetric: descriptor(rateMetric, .bytesPerSecond, .unbounded(min: 0)),
            MetricID("demo.rate.up"): descriptor(MetricID("demo.rate.up"), .bytesPerSecond, .unbounded(min: 0)),
            MetricID("demo.hot"): descriptor(MetricID("demo.hot"), .percent, .percentage),
            // Bounded by installed RAM, exactly as MemorySource declares it.
            MetricID("demo.bytes"): descriptor(
                MetricID("demo.bytes"), .bytes, .bounded(min: 0, max: 17_179_869_184)
            ),
            MetricID("demo.clock"): descriptor(
                MetricID("demo.clock"), .timestamp, .unbounded(min: 0)
            ),
        ]
        for index in 0..<10 {
            descriptors[coreMetric(index)] = descriptor(coreMetric(index), .percent, .percentage)
        }

        // The real strip's metrics, so the last row is the actual default.
        values[CPULoadSource.total] = 42
        values[MemorySource.usagePercent] = 76
        values[MemorySource.pressure] = 0
        values[NetworkSource.downloadRate] = 6_800_000
        values[NetworkSource.uploadRate] = 148_000
        descriptors[CPULoadSource.total] = descriptor(CPULoadSource.total, .percent, .percentage)
        descriptors[MemorySource.usagePercent] = descriptor(MemorySource.usagePercent, .percent, .percentage)
        descriptors[MemorySource.pressure] = descriptor(MemorySource.pressure, .count, .bounded(min: 0, max: 2))
        descriptors[NetworkSource.downloadRate] = descriptor(NetworkSource.downloadRate, .bytesPerSecond, .unbounded(min: 0))
        descriptors[NetworkSource.uploadRate] = descriptor(NetworkSource.uploadRate, .bytesPerSecond, .unbounded(min: 0))

        return StripComposer.Frame(
            values: values,
            histories: [
                percentMetric: percentHistory(),
                rateMetric: rateHistory(),
                CPULoadSource.total: percentHistory(),
            ],
            descriptors: descriptors
        )
    }

    private static func render(_ entry: Entry, appearance name: NSAppearance.Name) throws -> NSImage {
        let composer = StripComposer()
        var result: NSImage?
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            result = composer.compose(entry.widget, frame: frame(), context: RenderContext())
        }
        guard let result else { throw PreviewRenderer.PreviewError.noImage }
        return result
    }

    private static func caption(_ text: String, in rect: CGRect, context: CGContext) {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineSpacing = -1

        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 7.5, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
                .paragraphStyle: style,
            ]
        )

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let size = attributed.size()
        attributed.draw(in: CGRect(
            x: rect.minX, y: rect.midY - size.height / 2,
            width: rect.width, height: size.height
        ))
        NSGraphicsContext.restoreGraphicsState()
    }
}
