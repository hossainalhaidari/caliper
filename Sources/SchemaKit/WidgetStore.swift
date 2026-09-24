import Foundation
import Observation
import RenderKit

/// The user's widgets, and the only thing that writes them to disk.
///
/// The document is the source of truth, not the rendered widgets. Everything
/// visible -- the menu bar items, the editor, the live preview -- is derived
/// from it, so there is exactly one place a change has to be made and no way for
/// the strip and the editor to disagree about what a widget is.
@MainActor
@Observable
public final class WidgetStore {
    public private(set) var document: LayoutDocument

    /// Bumped on every edit. Views observe this rather than diffing documents.
    public private(set) var revision = 0

    private let url: URL
    private var saveTask: Task<Void, Never>?

    public init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()

        if let existing = Self.load(from: self.url) {
            self.document = existing
        } else {
            // Write the defaults out immediately on first run. A configuration
            // file that only appears once you have edited something is a
            // configuration file nobody can find, and this one is meant to be
            // readable, diffable, and hand-editable.
            self.document = .initial()
            saveNow()
        }
    }

    // MARK: - Editing

    /// Every mutation goes through here, so persistence cannot be forgotten.
    public func edit(_ change: (inout LayoutDocument) -> Void) {
        change(&document)
        revision += 1
        scheduleSave()
    }

    public func widget(id: UUID) -> WidgetDocument? {
        document.widgets.first { $0.id == id }
    }

    public func updateWidget(id: UUID, _ change: (inout WidgetDocument) -> Void) {
        edit { document in
            guard let index = document.widgets.firstIndex(where: { $0.id == id }) else { return }
            change(&document.widgets[index])
        }
    }

    // MARK: - Persistence

    /// Writes are debounced.
    ///
    /// Typing a label in the editor produces a mutation per keystroke, and each
    /// one would otherwise be a synchronous disk write on the main actor. Half a
    /// second of quiet is imperceptible to the user and collapses a burst of
    /// edits into one write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    public func saveNow() {
        saveTask?.cancel()
        saveTask = nil

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Atomic: a crash mid-write must not leave a truncated layout that
            // fails to parse on next launch and loses everything.
            try document.encoded().write(to: url, options: .atomic)
        } catch {
            NSLog("caliper: could not save layout: \(error)")
        }
    }

    private static func load(from url: URL) -> LayoutDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try LayoutDocument(json: data)
        } catch {
            // A layout that will not parse is kept, not overwritten. It is the
            // user's configuration, and a future version -- or a hand edit --
            // may well be able to read it.
            NSLog("caliper: layout at \(url.path) could not be read: \(error)")
            let backup = url.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            return nil
        }
    }

    private static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base
            .appending(path: "de.alhaidari.caliper", directoryHint: .isDirectory)
            .appending(path: "layout.json")
    }
}
