import CoreGraphics
import Foundation
import RenderKit
import SensorKit
import Testing
@testable import SchemaKit

@Suite("Sharing widgets")
struct WidgetTransferTests {

    @Test("an exported widget can be read straight back")
    func exportImportRoundTrip() throws {
        let original = WidgetDocument.overview()
        let payload = try WidgetTransfer.parse(WidgetTransfer.export(original))

        guard case .widget(let decoded) = payload else {
            Issue.record("expected a single widget")
            return
        }
        #expect(decoded.name == original.name)
        #expect(decoded.cells.map(\.metric) == original.cells.map(\.metric))
    }

    @Test("a whole layout is accepted, not rejected")
    func acceptsLayouts() throws {
        // Sending someone your entire arrangement is a reasonable thing to do,
        // and refusing it would be a pointless obstacle.
        let layout = LayoutDocument(widgets: [
            .overview(),
            WidgetDocument(name: "Second", cells: []),
        ])
        let payload = try WidgetTransfer.parse(layout.encoded())

        guard case .layout(let widgets) = payload else {
            Issue.record("expected a layout")
            return
        }
        #expect(widgets.count == 2)
        #expect(payload.widgets.count == 2)
    }

    @Test("importing gives everything fresh identities")
    func importsAreIndependent() throws {
        let original = WidgetDocument.overview()
        let first = original.reidentified()
        let second = original.reidentified()

        // Importing the same file twice must give two independent widgets, not
        // one that silently replaces the other.
        #expect(first.id != original.id)
        #expect(second.id != first.id)
        #expect(Set(first.cells.map(\.id)).isDisjoint(with: Set(original.cells.map(\.id))))
        #expect(Set(first.cells.map(\.id)).isDisjoint(with: Set(second.cells.map(\.id))))
    }

    @Test("the sender's menu bar state is not imposed on the recipient")
    func doesNotShareEnabledState() throws {
        var hidden = WidgetDocument.overview()
        hidden.isEnabled = false

        guard case .widget(let decoded) = try WidgetTransfer.parse(WidgetTransfer.export(hidden)) else {
            Issue.record("expected a widget")
            return
        }
        // Whether it appears in *your* menu bar is your decision, not theirs.
        #expect(decoded.isEnabled)
    }

    @Test("a widget from a later schema is still attempted")
    func toleratesNewerSchema() throws {
        // Cell-level forward compatibility means most of a newer document will
        // survive, so refusing on the version string alone would make the
        // format brittle in exactly the case it was built for.
        let json = """
        {
          "schema": "caliper.widget/2",
          "id": "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
          "isEnabled": true,
          "name": "Newer",
          "cells": [
            { "id": "5F2504E0-4F89-41D3-9A0C-0305E82C3302",
              "metric": "cpu.usage.total",
              "style": { "type": "text.value", "decimals": 1, "showsUnit": true } }
          ]
        }
        """
        guard case .widget(let decoded) = try WidgetTransfer.parse(json) else {
            Issue.record("expected a widget")
            return
        }
        #expect(decoded.name == "Newer")
    }

    @Test("failures say something a person can act on")
    func readableFailures() {
        #expect(throws: WidgetTransfer.Failure.notJSON) {
            try WidgetTransfer.parse("not json at all")
        }

        #expect(throws: WidgetTransfer.Failure.unrecognisedSchema("some.other.thing/1")) {
            try WidgetTransfer.parse(#"{"schema": "some.other.thing/1"}"#)
        }

        #expect(throws: WidgetTransfer.Failure.unrecognisedSchema(nil)) {
            try WidgetTransfer.parse(#"{"name": "no schema here"}"#)
        }

        // Every message has to be something a user could read and act on, not a
        // DecodingError dumped on screen.
        for failure: WidgetTransfer.Failure in [
            .notJSON, .unrecognisedSchema("x"), .unrecognisedSchema(nil),
            .malformed("a \"metric\" field is missing"), .empty,
        ] {
            let message = failure.errorDescription ?? ""
            #expect(!message.isEmpty)
            #expect(!message.contains("Swift."))
            #expect(!message.contains("CodingKeys"))
        }
    }

    @Test("a hand-written widget needs only the essentials")
    func handWrittenIsEnough() throws {
        // Nobody should have to invent a UUID to write a widget by hand.
        let json = #"""
        { "schema": "caliper.widget/1", "name": "Minimal",
          "cells": [ { "metric": "cpu.usage.total", "style": { "type": "text.value" } } ] }
        """#
        guard case .widget(let decoded) = try WidgetTransfer.parse(json) else {
            Issue.record("expected a widget")
            return
        }
        #expect(decoded.name == "Minimal")
        #expect(decoded.cells.count == 1)
        #expect(decoded.isEnabled)
        #expect(decoded.cells[0].series.isEmpty)
    }

    @Test("a malformed widget reports what is wrong, not that it threw")
    func malformedIsExplained() {
        // A cell with no style at all: `metric` is legitimately optional now,
        // since spacers and dividers have none.
        let json = #"{"schema": "caliper.widget/1", "name": "Broken", "cells": [{"metric": "cpu.usage.total"}]}"#
        do {
            _ = try WidgetTransfer.parse(json)
            Issue.record("should have failed")
        } catch let failure as WidgetTransfer.Failure {
            guard case .malformed(let detail) = failure else {
                Issue.record("expected malformed, got \(failure)")
                return
            }
            // Names the field the author actually got wrong, rather than the
            // first thing the decoder happened to trip over.
            #expect(detail.contains("style"), "detail should name the missing field: \(detail)")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("filenames are safe and recognisable")
    func filenames() {
        #expect(WidgetTransfer.filename(for: WidgetDocument(name: "CPU + Net", cells: []))
                == "CPU  Net.caliperwidget")
        #expect(WidgetTransfer.filename(for: WidgetDocument(name: "../../etc/passwd", cells: []))
                == "etcpasswd.caliperwidget")
        #expect(WidgetTransfer.filename(for: WidgetDocument(name: "", cells: []))
                == "Widget.caliperwidget")
    }
}

@Suite("Desktop placement")
struct DesktopPlacementTests {

    @Test("placement round-trips with the document")
    func roundTrips() throws {
        var widget = WidgetDocument.overview()
        widget.desktop = DesktopPlacement(x: 140, y: 240, level: .floating, height: 60)

        let decoded = try WidgetDocument(json: widget.encoded())
        #expect(decoded.desktop == widget.desktop)
    }

    @Test("a widget with no desktop placement stays absent, not defaulted")
    func absentStaysAbsent() throws {
        let decoded = try WidgetDocument(json: WidgetDocument.overview().encoded())
        #expect(decoded.desktop == nil)
    }

    @Test("exporting strips the sender's screen position")
    func exportDropsPlacement() throws {
        var widget = WidgetDocument.overview()
        widget.desktop = DesktopPlacement(x: 2400, y: 1300, level: .floating, height: 44)

        guard case .widget(let shared) = try WidgetTransfer.parse(WidgetTransfer.export(widget)) else {
            Issue.record("expected a widget")
            return
        }
        // x=2400 is off the edge of most displays. Shipping it would make the
        // widget arrive invisible and appear not to work.
        #expect(shared.desktop == nil)
    }
}

@Suite("Cell icons")
struct CellIconTests {

    @Test("icons round-trip as a single-key object")
    func roundTrips() throws {
        let widget = WidgetDocument(name: "Icons", cells: [
            CellDocument(metric: "cpu.usage.total", style: .text(), icon: .symbol("cpu")),
            CellDocument(metric: "memory.usage.percent", style: .donut, icon: .emoji("\u{1F525}")),
        ])
        let decoded = try WidgetDocument(json: widget.encoded())
        #expect(decoded.cells[0].icon == .symbol("cpu"))
        #expect(decoded.cells[1].icon == .emoji("\u{1F525}"))

        let object = try JSONSerialization.jsonObject(with: widget.encoded()) as? [String: Any]
        let cells = object?["cells"] as? [[String: Any]]
        // Readable by eye, which is the point of the format.
        #expect((cells?[0]["icon"] as? [String: Any])?["symbol"] as? String == "cpu")
    }

    @Test("an icon takes precedence over a caption")
    func iconWins() {
        var cell = CellDocument(metric: "m", style: .text(), label: "CPU")
        #expect(cell.adornment == .text("CPU"))

        cell.icon = .symbol("cpu")
        // They occupy the same slot and are alternatives, which is how the
        // editor presents them.
        #expect(cell.adornment == .symbol("cpu"))
    }

    @Test("no icon and no caption means nothing is drawn")
    func absentMeansNone() {
        #expect(CellDocument(metric: "m", style: .text()).adornment == .none)
        #expect(CellDocument(metric: "m", style: .text(), label: "").adornment == .none)
    }

    @Test("an icon with neither key is rejected with a readable message")
    func malformedIcon() {
        let json = #"{"schema":"caliper.widget/1","name":"x","cells":[{"metric":"m","style":{"type":"text.value"},"icon":{"glyph":"?"}}]}"#
        #expect(throws: (any Error).self) { try WidgetTransfer.parse(json) }
    }
}

@Suite("Desktop window levels")
struct DesktopLevelTests {

    @Test("behind-windows sits above every desktop surface")
    func desktopLevelIsAboveTheDesktop() {
        let desktopIcons = Int(CGWindowLevelForKey(.desktopIconWindow))
        let normal = Int(CGWindowLevelForKey(.normalWindow))

        // The bug this pins: placing the widget at the desktop-icon level looks
        // right and makes it permanently invisible, because WindowManager and
        // Finder both composite full-screen windows there and a third-party
        // window lands behind both.
        #expect(DesktopPlacement.Level.desktop.windowLevel > desktopIcons)
        #expect(DesktopPlacement.Level.desktop.windowLevel > Int(CGWindowLevelForKey(.desktopWindow)))

        // ...and still below ordinary app windows, which is the whole point.
        #expect(DesktopPlacement.Level.desktop.windowLevel < normal)
    }

    @Test("floating sits above ordinary windows")
    func floatingIsAboveNormal() {
        #expect(DesktopPlacement.Level.floating.windowLevel > Int(CGWindowLevelForKey(.normalWindow)))
    }

    @Test("the two levels are ordered as their names claim")
    func levelsAreOrdered() {
        #expect(DesktopPlacement.Level.desktop.windowLevel < DesktopPlacement.Level.floating.windowLevel)
    }
}
