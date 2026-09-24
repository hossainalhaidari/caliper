import Foundation
import LayoutEngine
import RenderKit
import SensorKit
import Testing
@testable import SchemaKit

@Suite("Document round trips")
struct DocumentCodingTests {

    private func roundTrip(_ document: WidgetDocument) throws -> WidgetDocument {
        try WidgetDocument(json: document.encoded())
    }

    @Test("the default widget survives a round trip unchanged")
    func defaultRoundTrips() throws {
        let original = WidgetDocument.overview()
        #expect(try roundTrip(original) == original)
    }

    @Test("every style survives a round trip")
    func allStylesRoundTrip() throws {
        // A style that cannot be written and read back is a style that silently
        // resets to its defaults the next time the app launches.
        let cells = CellStyle.catalogue.enumerated().map { index, style in
            CellDocument(
                metric: MetricID("demo.metric.\(index)"),
                style: style,
                label: "L\(index)",
                thresholds: Thresholds(elevated: 70, critical: 90)
            )
        }
        let document = WidgetDocument(name: "All Styles", cells: cells)
        #expect(try roundTrip(document) == document)
    }

    @Test("styles encode flat, with the renderer's own type identifier")
    func styleEncodingShape() throws {
        let document = WidgetDocument(
            name: "One",
            cells: [CellDocument(metric: "cpu.usage.total", style: .history(.init(mode: .line, width: 40, capacity: 90)))]
        )
        let object = try JSONSerialization.jsonObject(with: document.encoded()) as? [String: Any]
        let cell = (object?["cells"] as? [[String: Any]])?.first
        let style = cell?["style"] as? [String: Any]

        // The type string is API: it appears in every shared document, so it
        // must be the renderer's identifier and not an incidental enum name.
        #expect(style?["type"] as? String == "graph.history")
        #expect(style?["mode"] as? String == "line")
        #expect(style?["capacity"] as? Int == 90)
    }

    @Test("an unknown style is preserved rather than dropped")
    func forwardCompatibility() throws {
        // A widget from a later version, using a style this build has never
        // heard of. Opening and saving it must not destroy the author's work.
        let json = """
        {
          "schema": "caliper.widget/1",
          "id": "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
          "isEnabled": true,
          "name": "From The Future",
          "cells": [
            {
              "id": "5F2504E0-4F89-41D3-9A0C-0305E82C3302",
              "metric": "gpu.0.utilization",
              "series": [],
              "style": { "type": "gauge.radial-burst", "petals": 7, "swirl": true }
            }
          ]
        }
        """.data(using: .utf8)!

        let document = try WidgetDocument(json: json)
        guard case .unsupported(let type, let payload) = document.cells[0].style else {
            Issue.record("unknown style should decode as unsupported")
            return
        }
        #expect(type == "gauge.radial-burst")
        #expect(payload.objectValue?["petals"] == .number(7))

        // And it must come back out intact, not as an empty object or a default.
        let reencoded = try WidgetDocument(json: document.encoded())
        #expect(reencoded == document)

        let object = try JSONSerialization.jsonObject(with: document.encoded()) as? [String: Any]
        let style = ((object?["cells"] as? [[String: Any]])?.first)?["style"] as? [String: Any]
        #expect(style?["petals"] as? Int == 7)
        #expect(style?["swirl"] as? Bool == true)
    }

    @Test("a quiet cell round-trips as quiet")
    func absentThresholds() throws {
        let document = WidgetDocument(
            name: "Quiet",
            cells: [CellDocument(metric: "cpu.usage.total", style: .text())]
        )
        let decoded = try roundTrip(document)
        #expect(decoded.cells[0].thresholds == nil)
    }

    @Test("layouts round trip with their display settings")
    func layoutRoundTrips() throws {
        let layout = LayoutDocument(
            widgets: [.overview()],
            density: .compact,
            alertsEnabled: false
        )
        let decoded = try LayoutDocument(json: layout.encoded())
        #expect(decoded == layout)
        #expect(decoded.density == .compact)
        // A setting that says "stop interrupting me" has to survive a relaunch,
        // or it is not a setting.
        #expect(decoded.alertsEnabled == false)
    }

    @Test("a layout written before a setting existed keeps working")
    func layoutDefaultsForwards() throws {
        // A layout.json on disk can predate any setting. Decoding has to treat
        // an absent key as the default rather than failing, or the first launch
        // after an update throws away the user's widgets.
        let json = Data("""
        {
          "schema": "caliper.layout/1",
          "density": "regular",
          "widgets": []
        }
        """.utf8)

        let decoded = try LayoutDocument(json: json)
        #expect(decoded.alertsEnabled)
        #expect(decoded.density == .regular)
    }

    @Test("a layout written with a retired setting keeps working")
    func layoutIgnoresRetiredSettings() throws {
        // `checksForUpdates` lived here until Sparkle took over the update
        // check and its switch, which it keeps in the app's defaults. Every
        // layout.json written before then still carries the key.
        let json = Data("""
        {
          "schema": "caliper.layout/1",
          "checksForUpdates": false,
          "widgets": []
        }
        """.utf8)

        let decoded = try LayoutDocument(json: json)
        #expect(decoded.widgets.isEmpty)
        #expect(decoded.alertsEnabled)
    }
}

@Suite("Resolution against real hardware")
struct ResolutionTests {

    private func descriptor(_ id: MetricID, _ unit: MetricUnit, _ range: MetricRange) -> MetricDescriptor {
        MetricDescriptor(id: id, displayName: "d", group: "g", unit: unit, range: range)
    }

    private var fullContext: ResolutionContext {
        ResolutionContext(
            descriptors: [
                descriptor(CPULoadSource.total, .percent, .percentage),
                descriptor(MemorySource.usagePercent, .percent, .percentage),
                descriptor(MemorySource.pressure, .count, .bounded(min: 0, max: 2)),
                descriptor(NetworkSource.downloadRate, .bytesPerSecond, .unbounded(min: 0)),
                descriptor(NetworkSource.uploadRate, .bytesPerSecond, .unbounded(min: 0)),
            ],
            coreGroups: [6, 4]
        )
    }

    @Test("the default widget resolves completely on a normal Mac")
    func defaultResolves() {
        let resolution = WidgetDocument.overview().resolve(in: fullContext)
        #expect(resolution.isComplete, "issues: \(resolution.issues.map(\.summary))")
        #expect(resolution.widget.cells.count == 4)
    }

    @Test("a missing sensor keeps its cell so the layout holds its shape")
    func missingMetricIsSurvivable() {
        let document = WidgetDocument(name: "GPU", cells: [
            CellDocument(metric: "gpu.0.utilization", style: .text(), label: "GPU")
        ])
        let resolution = document.resolve(in: fullContext)

        // Reported, but still drawn -- a widget shared from a machine with
        // hardware this one lacks should show a visible gap, not silently
        // collapse to a narrower strip.
        #expect(!resolution.isComplete)
        #expect(resolution.widget.cells.count == 1)
        #expect(resolution.droppedCells == 0)
        #expect(resolution.issues.first?.kind == .unknownMetric("gpu.0.utilization"))
        #expect(resolution.issues.first?.isFatal == false)
    }

    @Test("a shape that cannot tell the truth is dropped, not drawn")
    func incompatibleStyleIsFatal() {
        let document = WidgetDocument(name: "Bad", cells: [
            CellDocument(metric: NetworkSource.downloadRate, style: .donut)
        ])
        let resolution = document.resolve(in: fullContext)

        #expect(resolution.widget.cells.isEmpty)
        #expect(resolution.droppedCells == 1)
        #expect(resolution.issues.first?.isFatal == true)
    }

    @Test("an unknown style is reported and skipped")
    func unsupportedStyleIsDropped() {
        let document = WidgetDocument(name: "Future", cells: [
            CellDocument(metric: CPULoadSource.total, style: .unsupported(type: "gauge.x", payload: .object([:])))
        ])
        let resolution = document.resolve(in: fullContext)
        #expect(resolution.widget.cells.isEmpty)
        #expect(resolution.issues.first?.kind == .unsupportedStyle("gauge.x"))
    }

    @Test("a core matrix adopts this machine's cluster layout")
    func coreMatrixAdaptsToHardware() {
        var context = fullContext
        context.descriptors[CPUCoreSource.core(0)] = descriptor(CPUCoreSource.core(0), .percent, .percentage)
        context.descriptors[CPUCoreSource.core(1)] = descriptor(CPUCoreSource.core(1), .percent, .percentage)
        context.coreGroups = [2, 2]

        let document = WidgetDocument(name: "Cores", cells: [
            CellDocument(
                metric: CPUCoreSource.core(0),
                style: .coreMatrix(),
                series: [CPUCoreSource.core(1), CPUCoreSource.core(9)]
            )
        ])
        let resolution = document.resolve(in: context)

        // Core 9 does not exist here. The matrix should be two bars wide, not
        // three with a blank -- a widget from a 10-core Mac must not draw the
        // author's core count on an 8-core one.
        #expect(resolution.widget.cells.count == 1)
        #expect(resolution.widget.cells[0].series.count == 1)
        #expect(resolution.issues.contains { $0.kind == .unknownMetric(CPUCoreSource.core(9)) })
    }

    @Test("alert metrics are subscribed along with displayed ones")
    func alertMetricIsRequired() {
        let resolution = WidgetDocument.overview().resolve(in: fullContext)
        #expect(resolution.widget.requiredMetrics.contains(MemorySource.pressure))
    }

    @Test("the resolved default strip stays within its width budget")
    func defaultStripWidth() {
        let resolution = WidgetDocument.overview().resolve(in: fullContext)
        let total = resolution.widget.cells.reduce(0.0) { running, cell in
            running + cell.renderer.width(
                for: CellInput(value: 50, unit: .percent, range: .percentage),
                in: RenderContext()
            )
        }
        // M1's default was 279pt. Locking this in so a future default cannot
        // quietly creep back up.
        #expect(total < 200, "cells total \(total)pt")
    }
}

@Suite("Layout cells")
struct LayoutCellTests {

    private var context: ResolutionContext {
        ResolutionContext(descriptors: [
            MetricDescriptor(id: CPULoadSource.total, displayName: "CPU", group: "CPU",
                             unit: .percent, range: .percentage)
        ])
    }

    @Test("spacers and dividers need no metric")
    func decorativeCellsResolve() {
        let document = WidgetDocument(name: "Spaced", cells: [
            CellDocument(metric: CPULoadSource.total, style: .text()),
            CellDocument(style: .spacer(.init(width: 12))),
            CellDocument(style: .divider()),
            CellDocument(metric: CPULoadSource.total, style: .text()),
        ])
        let resolution = document.resolve(in: context)

        #expect(resolution.isComplete, "issues: \(resolution.issues.map(\.summary))")
        #expect(resolution.widget.cells.count == 4)
        // And they must not cause a sensor to be activated.
        #expect(resolution.widget.requiredMetrics == [CPULoadSource.total])
    }

    @Test("a data style with no metric is reported, not drawn")
    func dataStyleNeedsAMetric() {
        // Would otherwise render a placeholder for ever, which reads as a broken
        // sensor rather than as an unfinished cell.
        let resolution = WidgetDocument(name: "Empty", cells: [
            CellDocument(style: .text())
        ]).resolve(in: context)

        #expect(resolution.widget.cells.isEmpty)
        #expect(resolution.issues.first?.kind == .missingMetric(style: "text.value"))
        #expect(resolution.issues.first?.isFatal == true)
    }

    @Test("decorative cells round-trip without a metric key")
    func decorativeRoundTrips() throws {
        let document = WidgetDocument(name: "Spaced", cells: [
            CellDocument(style: .spacer(.init(width: 14))),
            CellDocument(style: .divider(.init(thickness: 1, inset: 4))),
        ])
        let decoded = try WidgetDocument(json: document.encoded())
        #expect(decoded == document)
        #expect(decoded.cells[0].metric == nil)

        let object = try JSONSerialization.jsonObject(with: document.encoded()) as? [String: Any]
        let cells = object?["cells"] as? [[String: Any]]
        // No null metric key cluttering a file meant to be read.
        #expect(cells?[0]["metric"] == nil)
        #expect((cells?[0]["style"] as? [String: Any])?["width"] as? Int == 14)
    }

    @Test("per-widget spacing survives a round trip and reaches the widget")
    func spacingRoundTrips() throws {
        var document = WidgetDocument.overview()
        document.spacing = 14

        let decoded = try WidgetDocument(json: document.encoded())
        #expect(decoded.spacing == 14)
        #expect(decoded.resolve(in: context).widget.spacing == 14)

        // Absent means "use the density default", not zero.
        #expect(WidgetDocument.overview().resolve(in: context).widget.spacing == nil)
    }
}

@Suite("Clock cells")
struct ClockCellTests {

    private var context: ResolutionContext {
        ResolutionContext(descriptors: [
            MetricDescriptor(id: ClockSource.epoch, displayName: "Clock", group: "Time",
                             unit: .timestamp, range: .unbounded(min: 0))
        ])
    }

    @Test("clock options round-trip, including the dialect")
    func roundTrips() throws {
        let document = WidgetDocument(name: "Clocks", cells: [
            CellDocument(metric: ClockSource.epoch,
                         style: .clock(.init(format: "EEE d MMM\nHH:mm", syntax: .pattern))),
            CellDocument(metric: ClockSource.epoch,
                         style: .clock(.init(format: "%H:%M %Z", syntax: .strftime, timeZone: "Asia/Tokyo"))),
        ])
        let decoded = try WidgetDocument(json: document.encoded())
        #expect(decoded == document)

        let object = try JSONSerialization.jsonObject(with: document.encoded()) as? [String: Any]
        let cells = object?["cells"] as? [[String: Any]]
        let style = cells?[1]["style"] as? [String: Any]
        // Readable by eye, which is the point of the format.
        #expect(style?["syntax"] as? String == "strftime")
        #expect(style?["timeZone"] as? String == "Asia/Tokyo")
    }

    @Test("omitted clock options fall back to a sensible default")
    func toleratesBareStyle() throws {
        let json = #"""
        { "schema": "caliper.widget/1", "name": "Bare",
          "cells": [ { "metric": "time.epoch", "style": { "type": "text.clock" } } ] }
        """#
        guard case .widget(let decoded) = try WidgetTransfer.parse(json) else {
            Issue.record("expected a widget")
            return
        }
        guard case .clock(let options) = decoded.cells[0].style else {
            Issue.record("expected a clock")
            return
        }
        #expect(options.format == "HH:mm")
        #expect(options.syntax == .pattern)
        #expect(options.timeZone == nil)
    }

    @Test("a clock resolves and subscribes to the time")
    func resolves() {
        let resolution = WidgetDocument(name: "Clock", cells: [
            CellDocument(metric: ClockSource.epoch, style: .clock())
        ]).resolve(in: context)

        #expect(resolution.isComplete)
        // Without this the bus would deliver no snapshots and the clock would
        // freeze at whatever second it was created.
        #expect(resolution.widget.requiredMetrics == [ClockSource.epoch])
    }
}
