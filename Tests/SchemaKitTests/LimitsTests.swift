import AppKit
import Foundation
import LayoutEngine
import RenderKit
import SensorKit
import Testing
@testable import SchemaKit

@Suite("Widget limits")
struct WidgetLimitsTests {

    private func widget(_ cells: [CellDocument], name: String = "Test") -> WidgetDocument {
        WidgetDocument(name: name, cells: cells)
    }

    private func text(label: String? = nil) -> CellDocument {
        CellDocument(metric: CPULoadSource.total, style: .text(), label: label)
    }

    /// Asserts that parsing refuses `document`, and returns why.
    private func refusal(_ document: WidgetDocument) throws -> WidgetLimits.Violation? {
        do {
            _ = try WidgetTransfer.parse(document.encoded())
            return nil
        } catch WidgetTransfer.Failure.tooLarge(let violation) {
            return violation
        }
    }

    // MARK: - What must still be accepted

    @Test("the default widget and every style the editor offers are within the limits")
    func defaultsPass() throws {
        // Limits that refused the app's own output would make sharing refuse
        // exactly the widgets people build.
        try WidgetLimits.check(LayoutDocument.initial().widgets)
        let catalogue = CellStyle.catalogue.map { style in
            CellDocument(metric: style.isDecorative ? nil : CPULoadSource.total, style: style, label: "CPU")
        }
        try WidgetLimits.check(widget(catalogue))
        _ = try WidgetTransfer.parse(widget(catalogue).encoded())
    }

    @Test("a widget at every limit is still accepted")
    func limitsAreInclusive() throws {
        let name = String(repeating: "n", count: WidgetLimits.nameLength)
        let label = String(repeating: "L", count: WidgetLimits.captionLength)
        // Narrow spacers: two dozen graphs, or two dozen long captions, are
        // wider than the width limit, which is a separate refusal tested below.
        let cells = [text(label: label)] + (1..<WidgetLimits.cellsPerWidget).map { _ in
            CellDocument(style: .spacer(.init(width: 8)))
        }
        try WidgetLimits.check(widget(cells, name: name))
    }

    // MARK: - The file that started this

    @Test("the 300-cell file from the audit is refused, and says why")
    func theAuditFile() throws {
        let cells = (0..<300).map { _ in text(label: "CPU") }
        let violation = try refusal(widget(cells, name: "Wall"))
        #expect(violation == .tooManyCells(widget: "Wall", count: 300))
        // Something a person can act on: the count, the limit, and what to ask for.
        let message = try #require(violation?.message)
        #expect(message.contains("300"))
        #expect(message.contains("\(WidgetLimits.cellsPerWidget)"))
    }

    @Test("a 5,000-character name is refused without quoting it back")
    func longName() throws {
        let violation = try refusal(widget([text()], name: String(repeating: "x", count: 5_000)))
        #expect(violation == .nameTooLong(length: 5_000))
        #expect((violation?.message.count ?? .max) < 200)
    }

    @Test("length is counted in scalars, so combining marks cannot hide a long caption")
    func combiningMarks() throws {
        // One character to `String.count`, ten thousand and one things to draw.
        let stacked = "e" + String(repeating: "\u{301}", count: 10_000)
        #expect(stacked.count == 1)
        let violation = try refusal(widget([text(label: stacked)]))
        #expect(violation == .textTooLong(widget: "Test", cell: 1, field: "label", length: 10_001, limit: 16))
    }

    @Test("a layout with too many widgets is refused")
    func tooManyWidgets() throws {
        let widgets = (0..<40).map { _ in widget([text()]) }
        #expect(throws: WidgetTransfer.Failure.tooLarge(.tooManyWidgets(40))) {
            try WidgetTransfer.parse(LayoutDocument(widgets: widgets).encoded())
        }
    }

    @Test("a file too large to be a widget is refused before it is parsed")
    func fileSize() throws {
        // Not even JSON: the size is checked first, so the parser never runs.
        let data = Data(count: WidgetLimits.fileSize + 1)
        #expect(throws: WidgetTransfer.Failure.tooLarge(.fileTooLarge(bytes: WidgetLimits.fileSize + 1))) {
            try WidgetTransfer.parse(data)
        }
    }

    // MARK: - Options

    @Test("a histogram with zero-width bars is refused rather than trapping")
    func zeroWidthBars() throws {
        let json = """
        { "schema": "caliper.widget/1", "name": "Bars", "cells": [ { "metric": "cpu.usage.total",
          "style": { "type": "graph.histogram", "barWidth": 0, "barGap": 0 } } ] }
        """
        #expect(throws: WidgetTransfer.Failure.tooLarge(.outOfRange(
            widget: "Bars", cell: 1, field: "barWidth", value: 0, range: WidgetLimits.histogramBarWidth
        ))) {
            try WidgetTransfer.parse(json)
        }

        // And the layout.json path, which is never checked, no longer traps.
        let style = CellStyle.histogram(.init(width: 34, barWidth: 0, barGap: 0))
        #expect(style.historyDepth == 1)
        #expect(CellStyle.histogram(.init(width: 1e300, barWidth: 1, barGap: 0)).historyDepth == 3600)
    }

    @Test("every numeric option is bounded", arguments: [
        (#"{ "type": "graph.history", "width": 5000 }"#, "width"),
        (#"{ "type": "graph.history", "capacity": 100000000 }"#, "capacity"),
        (#"{ "type": "text.value", "decimals": 1000 }"#, "decimals"),
        (#"{ "type": "gauge.bar", "width": -4 }"#, "width"),
        (#"{ "type": "layout.spacer", "width": 80000 }"#, "width"),
        (#"{ "type": "layout.divider", "thickness": 900 }"#, "thickness"),
        (#"{ "type": "matrix.cores", "groups": [100000] }"#, "groups"),
    ])
    func optionRanges(style: String, field: String) throws {
        let json = #"{ "schema": "caliper.widget/1", "name": "W", "cells": [ { "metric": "cpu.usage.total", "style": \#(style) } ] }"#
        do {
            _ = try WidgetTransfer.parse(json)
            Issue.record("\(style) was accepted")
        } catch WidgetTransfer.Failure.tooLarge(.outOfRange(_, let cell, let found, _, _)) {
            #expect(cell == 1)
            #expect(found == field)
        }
    }

    @Test("a widget's spacing and a desktop widget's height are bounded")
    func widgetOptions() throws {
        var spaced = widget([text()])
        spaced.spacing = 10_000
        #expect(try refusal(spaced) == .outOfRange(
            widget: "Test", cell: nil, field: "spacing", value: 10_000, range: WidgetLimits.spacing))

        // Only a layout carries a desktop placement -- export strips it -- so
        // that is the route this could arrive by.
        var tall = widget([text()])
        tall.desktop = DesktopPlacement(height: 10_000)
        #expect(throws: WidgetTransfer.Failure.tooLarge(.outOfRange(
            widget: "Test", cell: nil, field: "height", value: 10_000, range: WidgetLimits.desktopHeight
        ))) {
            try WidgetTransfer.parse(LayoutDocument(widgets: [tall]).encoded())
        }
    }

    // MARK: - Width

    @Test("a widget within every other limit can still be too wide")
    func tooWide() throws {
        let graphs = (0..<WidgetLimits.cellsPerWidget).map { _ in
            CellDocument(metric: CPULoadSource.total, style: .history(.init(width: 120)))
        }
        let violation = try refusal(widget(graphs, name: "Graphs"))
        guard case .tooWide(let name, let width) = violation else {
            Issue.record("expected tooWide, got \(String(describing: violation))")
            return
        }
        #expect(name == "Graphs")
        #expect(CGFloat(width) > WidgetLimits.width)
    }

    @Test("the worst-case width is never narrower than the widget really draws")
    @MainActor
    func widthIsPessimistic() throws {
        // Measured without knowing any units, so it has to be at least what the
        // composer draws once it does -- or a file could pass the check and
        // still be wider than the limit on the Mac that opened it.
        let document = WidgetDocument.overview()
        let descriptors: [MetricDescriptor] = [
            .init(id: CPULoadSource.total, displayName: "x", group: "x", unit: .percent, range: .percentage),
            .init(id: MemorySource.usagePercent, displayName: "x", group: "x", unit: .percent, range: .percentage),
            .init(id: MemorySource.pressure, displayName: "x", group: "x", unit: .count, range: .bounded(min: 0, max: 2)),
            .init(id: NetworkSource.downloadRate, displayName: "x", group: "x", unit: .bytesPerSecond, range: .unbounded(min: 0)),
            .init(id: NetworkSource.uploadRate, displayName: "x", group: "x", unit: .bytesPerSecond, range: .unbounded(min: 0)),
        ]
        let widget = document.resolve(in: ResolutionContext(descriptors: descriptors)).widget
        let image = try #require(StripComposer().compose(
            widget,
            frame: .init(values: [:], descriptors: Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })),
            context: RenderContext(density: .regular, scale: 1)
        ))
        #expect(WidgetLimits.worstCaseWidth(of: document) >= image.size.width)
    }

    // MARK: - The editor's side

    @Test("truncation cuts at a character boundary, within the scalar limit")
    func truncation() {
        #expect(WidgetLimits.truncated("CPU", to: 16) == "CPU")
        #expect(WidgetLimits.truncated("abcdef", to: 4) == "abcd")
        // "é" as e + combining acute is one character of two scalars: it goes
        // whole or not at all, never as a bare "e".
        #expect(WidgetLimits.truncated("ab" + "e\u{301}", to: 3) == "ab")
        #expect(WidgetLimits.truncated("ab" + "e\u{301}", to: 4) == "ab" + "e\u{301}")
    }

    @Test("a duplicated or renamed widget stays within the name limit")
    func editingKeepsNamesShort() {
        let long = String(repeating: "n", count: WidgetLimits.nameLength)
        let copy = WidgetEditing.duplicate(widget([text()], name: long))
        #expect(copy.name.unicodeScalars.count <= WidgetLimits.nameLength)
        #expect(WidgetEditing.sanitisedName(long + "more").unicodeScalars.count == WidgetLimits.nameLength)
    }
}
