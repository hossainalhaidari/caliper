import AppKit
import Observation
import SchemaKit
import UniformTypeIdentifiers

/// Holds a widget somebody sent, until the user decides what to do with it.
///
/// Nothing is added to the menu bar until it has been looked at. That is the
/// entire reason this exists: an import that lands silently gives the user a
/// broken widget and no idea why, whereas a preview against their own hardware
/// turns a silent degradation into an informed choice.
@MainActor
@Observable
final class ImportCoordinator {
    private(set) var offered: [WidgetDocument] = []
    private(set) var source: String?
    var failure: String?

    var isPresenting: Bool { !offered.isEmpty }

    /// The content types an import can arrive as.
    static var readableTypes: [UTType] {
        [
            UTType(exportedAs: WidgetTransfer.contentType, conformingTo: .json),
            .json,
            .plainText,
        ]
    }

    func offer(data: Data, from source: String) {
        do {
            let payload = try WidgetTransfer.parse(data)
            // Fresh identities at the door, so an import can never collide with
            // or replace something the user already has.
            offered = payload.widgets.map { $0.reidentified() }
            self.source = source
            failure = nil
        } catch {
            offered = []
            self.source = nil
            failure = error.localizedDescription
        }
    }

    func offer(url: URL) {
        // Measured before it is read, so a file the size of a disk image is
        // refused rather than loaded into memory to be refused.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > WidgetLimits.fileSize {
            offered = []
            source = nil
            failure = WidgetTransfer.Failure.tooLarge(.fileTooLarge(bytes: size)).localizedDescription
            return
        }
        do {
            offer(data: try Data(contentsOf: url), from: url.lastPathComponent)
        } catch {
            failure = String(
                localized: "Could not read \(url.lastPathComponent): \(error.localizedDescription)",
                comment: "Import error. A file name, then the system's reason")
        }
    }

    /// Paste. The route that matters most for sharing in a chat -- no file, no
    /// download, just the text.
    func offerPasteboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            failure = String(
                localized: "There is no text on the clipboard.", comment: "Import error: Paste with nothing to paste")
            return
        }
        offer(data: Data(text.utf8), from: String(
            localized: "the clipboard",
            comment: "Where an import came from, completing \u{201C}From %@\u{201D} under the import sheet's title"))
    }

    func dismiss() {
        offered = []
        source = nil
    }
}

/// Writing widgets out.
@MainActor
enum WidgetExport {

    static func save(_ document: WidgetDocument) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = WidgetTransfer.filename(for: document)
        panel.allowedContentTypes = [
            UTType(exportedAs: WidgetTransfer.contentType, conformingTo: .json)
        ]
        panel.canCreateDirectories = true
        panel.message = String(
            localized: "Share this widget. It is plain JSON, so it can be read and edited anywhere.",
            comment: "Message at the top of the Export save panel")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try WidgetTransfer.export(document).write(to: url, options: .atomic)
        } catch {
            present(error: String(
                localized: "Could not write \(url.lastPathComponent): \(error.localizedDescription)",
                comment: "Export error. A file name, then the system's reason"))
        }
    }

    /// The counterpart to paste: put the JSON on the clipboard so it can be
    /// dropped straight into a message.
    static func copyToPasteboard(_ document: WidgetDocument) {
        do {
            let data = try WidgetTransfer.export(document)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
        } catch {
            present(error: String(
                localized: "Could not copy this widget: \(error.localizedDescription)",
                comment: "Copy as JSON error. The argument is the system's reason"))
        }
    }

    private static func present(error message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Export failed", comment: "Alert title: a widget could not be exported")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
