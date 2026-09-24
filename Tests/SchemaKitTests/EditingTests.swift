import Foundation
import RenderKit
import SensorKit
import Testing
@testable import SchemaKit

@Suite("Editor operations")
struct WidgetEditingTests {

    private func cells(_ count: Int) -> [CellDocument] {
        (0..<count).map { CellDocument(metric: MetricID("m.\($0)"), style: .text()) }
    }

    @Test("moving a cell right lands it in the target's place")
    func reorderForwards() {
        var list = cells(4)
        let moved = list[0].id
        #expect(WidgetEditing.reorder(cells: &list, moving: moved, onto: list[2].id))

        // Dragging rightwards is where the off-by-one lives: removing the cell
        // first shifts the target left, so inserting at the target's new index
        // lands one place short.
        #expect(list.map(\.metric) == ["m.1", "m.2", "m.0", "m.3"])
    }

    @Test("moving a cell left lands it in the target's place")
    func reorderBackwards() {
        var list = cells(4)
        let moved = list[3].id
        #expect(WidgetEditing.reorder(cells: &list, moving: moved, onto: list[1].id))
        #expect(list.map(\.metric) == ["m.0", "m.3", "m.1", "m.2"])
    }

    @Test("dropping a cell on itself changes nothing")
    func reorderOntoSelf() {
        var list = cells(3)
        let before = list.map(\.metric)
        #expect(!WidgetEditing.reorder(cells: &list, moving: list[1].id, onto: list[1].id))
        #expect(list.map(\.metric) == before)
    }

    @Test("an unknown id is refused rather than crashing")
    func reorderUnknown() {
        var list = cells(3)
        #expect(!WidgetEditing.reorder(cells: &list, moving: UUID(), onto: list[0].id))
        #expect(list.count == 3)
    }

    @Test("a new cell always renders something")
    func newCellIsUsable() {
        // Text is the one style that accepts every metric, so a freshly added
        // cell can never start life as an error.
        let descriptor = MetricDescriptor(
            id: "net.throughput.down",
            displayName: "Download Rate",
            group: "Network",
            unit: .bytesPerSecond,
            range: .unbounded(min: 0)
        )
        let cell = WidgetEditing.makeCell(for: descriptor)

        #expect(cell.style.accepts(descriptor.range))
        // The caption comes from the group, not the first word of the display
        // name -- which used to produce "DOWNLOAD", far too wide for a strip.
        #expect(cell.label == "NET")
        if case .text(let options) = cell.style {
            #expect(options.decimals == 1, "a rate needs a decimal to be readable")
        } else {
            Issue.record("expected a text cell")
        }
    }

    @Test("duplicating gives everything fresh identities")
    func duplicateIsIndependent() {
        let original = WidgetDocument.overview()
        let copy = WidgetEditing.duplicate(original)

        #expect(copy.id != original.id)
        #expect(copy.name == original.name + " Copy")
        // Shared cell ids would make editor selection ambiguous and break
        // reordering, which matches on id.
        #expect(Set(copy.cells.map(\.id)).isDisjoint(with: Set(original.cells.map(\.id))))
        #expect(copy.cells.map(\.metric) == original.cells.map(\.metric))
    }
}

@MainActor
@Suite("Layout persistence")
struct WidgetStoreTests {

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "caliper-test-\(UUID().uuidString)")
            .appending(path: "layout.json")
    }

    @Test("a fresh store starts from the built-in layout")
    func startsWithDefault() {
        let store = WidgetStore(url: temporaryURL())
        #expect(store.document.widgets.count == 1)
        #expect(store.document.widgets[0].name == "Overview")
    }

    @Test("edits survive a reload")
    func persistsEdits() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = WidgetStore(url: url)
        store.edit { $0.widgets.append(WidgetDocument(name: "Second", cells: [])) }
        store.edit { $0.density = .compact }
        store.saveNow()

        let reloaded = WidgetStore(url: url)
        #expect(reloaded.document.widgets.count == 2)
        #expect(reloaded.document.widgets.last?.name == "Second")
        #expect(reloaded.document.density == .compact)
    }

    @Test("every edit bumps the revision so views refresh")
    func revisionTracksEdits() {
        let store = WidgetStore(url: temporaryURL())
        let before = store.revision
        store.updateWidget(id: store.document.widgets[0].id) { $0.name = "Renamed" }
        #expect(store.revision > before)
        #expect(store.document.widgets[0].name == "Renamed")
    }

    @Test("an unreadable layout is preserved, not overwritten")
    func keepsUnreadableLayout() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("{ this is not json".utf8).write(to: url)

        // Falling back to defaults is right; silently destroying the user's
        // configuration on the way is not. A hand edit or a future version may
        // still be able to read it.
        let store = WidgetStore(url: url)
        #expect(store.document.widgets.count == 1)

        let backup = url.appendingPathExtension("unreadable")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try String(contentsOf: backup, encoding: .utf8).hasPrefix("{ this is not json"))
    }

    @Test("a widget can be edited by id without touching the others")
    func targetedUpdates() {
        let store = WidgetStore(url: temporaryURL())
        let second = WidgetDocument(name: "Second", cells: [])
        store.edit { $0.widgets.append(second) }

        store.updateWidget(id: second.id) { $0.isEnabled = false }
        #expect(store.document.widgets[0].isEnabled)
        #expect(store.document.widgets[1].isEnabled == false)
    }
}

@Suite("Sensible defaults")
struct DefaultCellTests {

    private func descriptor(
        _ id: MetricID, _ name: String, _ group: String, _ unit: MetricUnit, _ range: MetricRange
    ) -> MetricDescriptor {
        MetricDescriptor(id: id, displayName: name, group: group, unit: unit, range: range)
    }

    @Test("a clock metric starts as a clock, not a number")
    func timestampBecomesAClock() {
        // Shown as a number this reads "1787663595", which tells nobody
        // anything -- and is the first thing someone sees after adding the cell.
        let cell = WidgetEditing.makeCell(for: descriptor(
            "time.epoch", "Clock", "Time", .timestamp, .unbounded(min: 0)
        ))

        guard case .clock = cell.style else {
            Issue.record("expected a clock, got \(cell.style.displayName)")
            return
        }
        // The time says what it is; a "TIME" caption beside it is noise.
        #expect(cell.label == nil)
    }

    @Test("whole quantities are shown whole")
    func decimalsSuitTheUnit() {
        // "109.0 cycles" and "31.4°" are precision nobody can act on.
        #expect(WidgetEditing.defaultDecimals(for: .count) == 0)
        #expect(WidgetEditing.defaultDecimals(for: .percent) == 0)
        #expect(WidgetEditing.defaultDecimals(for: .celsius) == 0)
        #expect(WidgetEditing.defaultDecimals(for: .seconds) == 0)

        // Rates and sizes are worth a decimal: "1.2 MB/s" beats "1 MB/s".
        #expect(WidgetEditing.defaultDecimals(for: .bytesPerSecond) == 1)
        #expect(WidgetEditing.defaultDecimals(for: .bytes) == 1)
        #expect(WidgetEditing.defaultDecimals(for: .watts) == 1)
    }

    @Test("captions are short enough for a menu bar")
    func labelsAreShort() {
        let cases: [(String, MetricUnit, String?)] = [
            ("CPU", .percent, "CPU"),
            ("Memory", .bytes, "MEM"),
            ("Network", .bytesPerSecond, "NET"),
            ("Temperature", .celsius, "TEMP"),
            ("Battery", .percent, "BATT"),
            ("Power", .watts, "PWR"),
        ]

        for (group, unit, expected) in cases {
            let label = WidgetEditing.defaultLabel(
                for: descriptor("m", "Some Long Display Name", group, unit, .percentage)
            )
            // The old rule took the first word of the display name, which turned
            // "Download" into "DOWNLOAD" and "Hottest Sensor" into "HOTTEST".
            #expect(label == expected, "\(group) produced \(label ?? "nil")")
        }

        // Anything unrecognised is still capped rather than left to sprawl.
        let unknown = WidgetEditing.defaultLabel(
            for: descriptor("m", "Whatever", "Something Unexpected", .count, .percentage)
        )
        #expect((unknown?.count ?? 0) <= 4)
    }

    @Test("a new cell can always be drawn as-is")
    func defaultsAreValid() {
        // Whatever style is chosen, it must accept the metric it was chosen for.
        for (unit, range) in [
            (MetricUnit.percent, MetricRange.percentage),
            (.bytes, .bounded(min: 0, max: 17_179_869_184)),
            (.bytesPerSecond, .unbounded(min: 0)),
            (.timestamp, .unbounded(min: 0)),
            (.celsius, .bounded(min: 0, max: 110)),
            (.count, .unbounded(min: 0)),
        ] as [(MetricUnit, MetricRange)] {
            let cell = WidgetEditing.makeCell(for: descriptor("m", "X", "CPU", unit, range))
            #expect(cell.style.accepts(range), "\(unit) default style rejects its own metric")
            #expect(cell.metric != nil)
        }
    }
}

@Suite("Default label overrides")
struct DefaultLabelOverrideTests {

    @Test("uptime is not captioned by its group")
    func uptimeReadsAsUptime() {
        // Uptime shares the "Time" group with the clock, and "TIME 8d 0h" says
        // the wrong thing about what is being measured.
        let label = WidgetEditing.defaultLabel(for: MetricDescriptor(
            id: ClockSource.uptime, displayName: "Uptime", group: "Time",
            unit: .seconds, range: .unbounded(min: 0)
        ))
        #expect(label == "UP")
    }
}

@Suite("Renaming")
struct RenameTests {

    @Test("a blank name never survives")
    func blankBecomesUntitled() {
        // An empty name leaves a row that is nearly impossible to click, and an
        // export filename with no stem at all.
        #expect(WidgetEditing.sanitisedName("") == "Untitled")
        #expect(WidgetEditing.sanitisedName("   ") == "Untitled")
        #expect(WidgetEditing.sanitisedName("\n\t") == "Untitled")
    }

    @Test("a real name is kept, trimmed")
    func realNamesSurvive() {
        #expect(WidgetEditing.sanitisedName("Network") == "Network")
        #expect(WidgetEditing.sanitisedName("  Desk Clock  ") == "Desk Clock")
        // Internal spacing is the user's business.
        #expect(WidgetEditing.sanitisedName("CPU  and  RAM") == "CPU  and  RAM")
    }

    @Test("a sanitised name still makes a usable filename")
    func namesProduceFilenames() {
        for raw in ["", "   ", "Network", "../../etc/passwd"] {
            let name = WidgetEditing.sanitisedName(raw)
            let filename = WidgetTransfer.filename(for: WidgetDocument(name: name, cells: []))
            #expect(filename.hasSuffix(".caliperwidget"))
            #expect(filename != ".caliperwidget", "\(raw) produced a filename with no stem")
        }
    }
}
