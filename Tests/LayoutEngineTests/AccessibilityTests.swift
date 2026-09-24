import AppKit
import RenderKit
import SensorKit
import Testing
@testable import LayoutEngine

/// What a strip says to VoiceOver, and what it shows to someone who cannot
/// tell its colours apart.
///
/// Both are easy to lose without noticing: the status item looks exactly the
/// same with no accessibility value, and an alert drawn in colour alone looks
/// fine to anyone who can see the colour.
@MainActor
@Suite("Accessibility")
struct AccessibilityTests {

    private let descriptors: [MetricID: MetricDescriptor] = {
        var result: [MetricID: MetricDescriptor] = [:]
        func add(_ id: MetricID, _ name: String, _ unit: MetricUnit, _ range: MetricRange) {
            result[id] = MetricDescriptor(id: id, displayName: name, group: "x", unit: unit, range: range)
        }
        add(CPULoadSource.total, "CPU Usage", .percent, .percentage)
        add(MemorySource.usagePercent, "Memory Used", .percent, .percentage)
        add(NetworkSource.downloadRate, "Download", .bytesPerSecond, .unbounded(min: 0))
        add(NetworkSource.uploadRate, "Upload", .bytesPerSecond, .unbounded(min: 0))
        for core in 0..<6 { add(CPUCoreSource.core(core), "Core \(core)", .percent, .percentage) }
        return result
    }()

    private func spoken(_ cells: [Cell], values: [MetricID: Double]) throws -> String {
        let composer = StripComposer()
        _ = try #require(composer.compose(
            Widget(name: "Test", cells: cells),
            frame: StripComposer.Frame(values: values, descriptors: descriptors),
            context: RenderContext()
        ))
        return composer.spokenDescription
    }

    private func text(_ metric: MetricID, label: String? = nil, critical: Double? = nil) -> Cell {
        Cell(
            metric: metric,
            renderer: TextValueRenderer(thresholds: Thresholds(elevated: critical.map { $0 - 10 }, critical: critical)),
            label: label
        )
    }

    // MARK: - Spoken description

    @Test("a cell is called by its caption, and by its metric when it has none")
    func namesCells() throws {
        let description = try spoken(
            [text(CPULoadSource.total, label: "CPU"), text(MemorySource.usagePercent)],
            values: [CPULoadSource.total: 23, MemorySource.usagePercent: 61]
        )
        #expect(description.contains("CPU 23%"))
        #expect(description.contains("Memory Used 61%"))
    }

    @Test("an alerting cell says so in words, not only in colour")
    func saysSeverity() throws {
        let critical = try spoken(
            [text(CPULoadSource.total, label: "CPU", critical: 90)],
            values: [CPULoadSource.total: 95]
        )
        #expect(critical == "CPU critical at 95%")

        let elevated = try spoken(
            [text(CPULoadSource.total, label: "CPU", critical: 90)],
            values: [CPULoadSource.total: 85]
        )
        #expect(elevated == "CPU high at 85%")
    }

    @Test("a missing reading is said, not skipped")
    func saysMissing() throws {
        let description = try spoken([text(CPULoadSource.total, label: "CPU")], values: [:])
        #expect(description == "CPU no reading")
    }

    @Test("spacers and dividers say nothing")
    func skipsDecoration() throws {
        let description = try spoken(
            [
                text(CPULoadSource.total, label: "CPU"),
                Cell(renderer: SpacerRenderer()),
                Cell(renderer: DividerRenderer()),
            ],
            values: [CPULoadSource.total: 5]
        )
        #expect(description == "CPU 5%")
    }

    @Test("a two-valued cell names both values")
    func namesSeries() throws {
        let description = try spoken(
            [Cell(metric: NetworkSource.downloadRate, renderer: DualRateRenderer(), series: [NetworkSource.uploadRate])],
            values: [NetworkSource.downloadRate: 2_000_000, NetworkSource.uploadRate: 30_000]
        )
        #expect(description.contains("Download"))
        #expect(description.contains("Upload"))
    }

    @Test("a many-valued cell is summarised rather than read out")
    func summarisesMatrix() throws {
        let cores = (0..<6).map(CPUCoreSource.core)
        var values: [MetricID: Double] = [:]
        for (index, core) in cores.enumerated() { values[core] = Double(index * 10) }

        let description = try spoken(
            [Cell(metric: cores[0], renderer: CoreMatrixRenderer(groups: [6]), label: "CPU", series: Array(cores.dropFirst()))],
            values: values
        )
        #expect(description == "CPU average 25%, highest 50%")
    }

    // MARK: - The mark under an alerting cell

    /// Opaque pixels in the bottom two points of the strip, where the mark is
    /// drawn and no style draws anything else.
    private func markPixels(_ severity: Double) throws -> Int {
        let composer = StripComposer()
        let image = try #require(composer.compose(
            Widget(name: "Test", cells: [text(CPULoadSource.total, label: "CPU", critical: 90)]),
            frame: StripComposer.Frame(values: [CPULoadSource.total: severity], descriptors: descriptors),
            context: RenderContext(scale: 2)
        ))
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)

        var count = 0
        for y in (bitmap.pixelsHigh - 4)..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                count += 1
            }
        }
        return count
    }

    @Test("a quiet cell has no mark, a critical one a solid line, a warning a dashed one")
    func marksSeverityByShape() throws {
        let quiet = try markPixels(20)
        let warning = try markPixels(85)
        let critical = try markPixels(95)

        #expect(quiet == 0, "a nominal cell must stay unmarked")
        #expect(critical > 0, "a critical cell must be underlined")
        // Dashed: visibly broken, but clearly there.
        #expect(warning > 0)
        #expect(warning < critical, "the warning mark should be dashed, so lighter than the solid one")
    }
}
