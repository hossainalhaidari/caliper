import Foundation
import SensorKit

/// Document edits the editor performs, kept out of the views.
///
/// Views should express intent, not manipulate arrays. Putting the operations
/// here means they can be tested without instantiating any UI -- which matters
/// for an editor whose SwiftUI hierarchy cannot be rendered headlessly.
public enum WidgetEditing {

    /// Moves `dragged` into the slot `target` currently occupies.
    ///
    /// Dropping one chip onto another in a horizontal strip means "put it
    /// here", so the dragged cell should end up where the target was and the
    /// target should shift aside. Getting that right needs the two directions
    /// handled separately:
    ///
    /// - Dragging **right**, removing the cell first shifts the target one place
    ///   left, so the insertion goes *after* it.
    /// - Dragging **left**, the target has not moved, so the insertion goes at
    ///   its index.
    ///
    /// Using one rule for both is the classic off-by-one here: it looks correct
    /// dragging leftwards and silently drops a cell one place short every time
    /// you drag rightwards.
    public static func reorder(
        cells: inout [CellDocument],
        moving dragged: UUID,
        onto target: UUID
    ) -> Bool {
        guard dragged != target,
              let from = cells.firstIndex(where: { $0.id == dragged }),
              let to = cells.firstIndex(where: { $0.id == target })
        else { return false }

        let cell = cells.remove(at: from)
        guard let shifted = cells.firstIndex(where: { $0.id == target }) else {
            cells.insert(cell, at: min(to, cells.count))
            return true
        }

        cells.insert(cell, at: from < to ? shifted + 1 : shifted)
        return true
    }

    /// A new cell for a metric, styled the way that metric wants to be read.
    ///
    /// The style is chosen from the unit rather than always starting as a
    /// number, because for some metrics a number is simply the wrong answer: a
    /// timestamp shown as a number is seconds since 1970, which tells nobody
    /// anything. Getting the default right matters more than it sounds -- it is
    /// what someone sees the instant they add a cell, and a first impression of
    /// "1787663595" is one they have to undo.
    public static func makeCell(for descriptor: MetricDescriptor) -> CellDocument {
        CellDocument(
            metric: descriptor.id,
            style: defaultStyle(for: descriptor),
            label: defaultLabel(for: descriptor)
        )
    }

    static func defaultStyle(for descriptor: MetricDescriptor) -> CellStyle {
        switch descriptor.unit {
        case .timestamp:
            // The whole point of the clock style. A timestamp has no useful
            // numeric reading.
            return .clock()
        default:
            return .text(.init(decimals: defaultDecimals(for: descriptor.unit)))
        }
    }

    /// Decimal places that suit the quantity.
    ///
    /// Whole things are shown whole. A charge-cycle count of "109.0" reads as a
    /// measurement error rather than as a number of cycles, and a temperature to
    /// a tenth of a degree is precision nobody can act on.
    static func defaultDecimals(for unit: MetricUnit) -> Int {
        switch unit {
        case .percent, .count, .seconds, .timestamp, .celsius, .rpm: 0
        case .bytes, .bytesPerSecond, .watts, .hertz: 1
        }
    }

    /// Short group abbreviations rather than the first word of the name.
    ///
    /// "Download" and "Hottest Sensor" are what the previous first-word rule
    /// produced, and neither belongs in a menu bar. The group says what kind of
    /// reading it is, which is what a caption is for, and four characters is
    /// about the most a strip can spare.
    static func defaultLabel(for descriptor: MetricDescriptor) -> String? {
        // A handful of metrics where the group is misleading. Uptime sits in
        // "Time" alongside the clock, and "TIME 8d 0h" says the wrong thing.
        if descriptor.id == ClockSource.uptime {
            return String(localized: "UP", comment: "Default caption for uptime. At most four characters")
        }

        // Keyed by the group's English name, which is what a descriptor carries;
        // the caption is what the reader sees, so it is translated.
        let known = [
            "CPU": String(localized: "CPU", comment: "Metric group: the processor as a whole"),
            "CPU Cores": String(localized: "CPU", comment: "Metric group: the processor as a whole"),
            "Memory": String(localized: "MEM", comment: "Default caption for a new cell. At most four characters, in capitals where the language has them"),
            "Network": String(localized: "NET", comment: "Default caption for a new cell. At most four characters, in capitals where the language has them"),
            "Network Interfaces": String(localized: "NET", comment: "Default caption for a new cell. At most four characters, in capitals where the language has them"),
            "Disk": String(localized: "DISK", comment: "Default caption for a new cell. At most four characters, in capitals where the language has them"),
            "Volumes": String(localized: "DISK", comment: "Default caption for a new cell. At most four characters, in capitals where the language has them"),
            "GPU": String(localized: "GPU", comment: "Metric group: the graphics processor"),
            "Temperature": String(localized: "TEMP", comment: "Default caption for a new cell. At most four characters, in capitals where the language has them"),
            "Temperature (Advanced)": String(localized: "TEMP", comment: "Default caption for a new cell. At most four characters, in capitals where the language has them"),
            "Battery": String(localized: "BATT", comment: "Default caption for a new cell. At most four characters, in capitals where the language has them"),
            "Power": String(localized: "PWR", comment: "Default caption for a new cell. At most four characters, in capitals where the language has them"),
            "Fans": String(localized: "FAN", comment: "Default caption for a new cell. At most four characters, in capitals where the language has them"),
        ]
        if let label = known[descriptor.group] { return label }

        // A clock needs no caption: the time says what it is.
        guard descriptor.unit != .timestamp else { return nil }

        let first = descriptor.group.split(separator: " ").first.map(String.init) ?? descriptor.group
        guard !first.isEmpty else { return nil }
        return String(first.prefix(4)).uppercased()
    }

    /// Cleans up a name typed into the editor.
    ///
    /// An empty name is not merely untidy: the row becomes a blank strip that is
    /// hard to click, and `WidgetTransfer.filename` would produce
    /// ".caliperwidget" with no stem at all. Whitespace is trimmed for the same
    /// reason -- a name of three spaces looks exactly like an empty one.
    public static func sanitisedName(_ name: String) -> String {
        let trimmed = WidgetLimits.truncated(
            name.trimmingCharacters(in: .whitespacesAndNewlines),
            to: WidgetLimits.nameLength
        )
        return trimmed.isEmpty
            ? String(localized: "Untitled", comment: "Name given to a widget whose name was left empty")
            : trimmed
    }

    /// A copy with fresh identities throughout.
    ///
    /// Reusing cell ids would make editor selection ambiguous between the
    /// original and the copy, and would break the reorder above, which matches
    /// on id.
    public static func duplicate(_ widget: WidgetDocument) -> WidgetDocument {
        var copy = widget
        copy.id = UUID()
        // Cut to the limit, or duplicating a widget with a long name would
        // make one that could not be shared.
        copy.name = WidgetLimits.truncated(
            String(
                localized: "\(widget.name) Copy",
                comment: "Name of a duplicated widget. The argument is the original's name"),
            to: WidgetLimits.nameLength
        )
        copy.cells = widget.cells.map { cell in
            var duplicated = cell
            duplicated.id = UUID()
            return duplicated
        }
        return copy
    }
}
