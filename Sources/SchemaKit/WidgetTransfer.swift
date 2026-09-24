import Foundation

/// Reading and writing widgets that came from somebody else.
///
/// Kept separate from `Codable` conformance because sharing has requirements
/// plain decoding does not: it must accept a whole layout as readily as a single
/// widget, it must fail with something a person can act on rather than a
/// `DecodingError`, and it must give incoming widgets fresh identities so that
/// importing the same file twice produces two widgets instead of a collision.
public enum WidgetTransfer {

    /// The file extension and type identifier for a shared widget.
    ///
    /// A registered type rather than plain `.json` so a double-click does
    /// something, while the contents stay ordinary text that opens in any editor
    /// and diffs in git.
    public static let fileExtension = "caliperwidget"
    public static let contentType = "de.alhaidari.caliper.widget"

    /// What a shared file turned out to contain.
    public enum Payload: Equatable, Sendable {
        case widget(WidgetDocument)
        /// Somebody's whole arrangement, which is a perfectly reasonable thing
        /// to send and would be irritating to reject.
        case layout([WidgetDocument])

        public var widgets: [WidgetDocument] {
            switch self {
            case .widget(let document): [document]
            case .layout(let documents): documents
            }
        }
    }

    public enum Failure: LocalizedError, Equatable {
        case notJSON
        case unrecognisedSchema(String?)
        case malformed(String)
        case empty
        /// Readable, but larger than any widget should be. See `WidgetLimits`.
        case tooLarge(WidgetLimits.Violation)

        public var errorDescription: String? {
            switch self {
            case .notJSON:
                String(
                    localized: "This does not look like a widget. Widgets are JSON text.",
                    comment: "Import error: the file is not JSON")
            case .unrecognisedSchema(let found):
                if let found {
                    String(
                        localized: "This file says it is \u{201C}\(found)\u{201D}, which is not a widget or a layout.",
                        comment: "Import error. The argument is the file's schema field, such as caliper.theme/1")
                } else {
                    String(
                        localized: "This file does not say what it is. A widget needs a \u{201C}schema\u{201D} field.",
                        comment: "Import error. Keep the word schema: it is the name of a field in the file")
                }
            case .malformed(let detail):
                String(
                    localized: "This widget could not be read: \(detail)",
                    comment: "Import error. The argument says what was wrong, such as a missing field")
            case .empty:
                String(localized: "This file contains no widgets.", comment: "Import error")
            case .tooLarge(let violation):
                violation.message
            }
        }
    }

    /// Parses shared data, accepting either a single widget or a whole layout.
    ///
    /// Everything returned is within `WidgetLimits`, so a caller can preview it
    /// straight away: the import sheet composes the strip before the user has
    /// decided anything, and that is exactly when an oversized file would cost
    /// the most.
    public static func parse(_ data: Data) throws -> Payload {
        let payload = try decode(data)
        do {
            try WidgetLimits.check(payload.widgets)
        } catch {
            throw Failure.tooLarge(error)
        }
        return payload
    }

    private static func decode(_ data: Data) throws -> Payload {
        // Before parsing, not after: the JSON parser's own memory is the first
        // thing a huge file would cost.
        guard data.count <= WidgetLimits.fileSize else {
            throw Failure.tooLarge(.fileTooLarge(bytes: data.count))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.notJSON
        }

        let schema = object["schema"] as? String
        let decoder = WidgetDocument.makeDecoder()

        // Matched on prefix, not equality: a "caliper.widget/2" from a later
        // version should still be attempted, because the cell-level forward
        // compatibility means most of it will survive. Refusing outright would
        // make the format brittle in exactly the situation it was designed for.
        if schema?.hasPrefix("caliper.widget/") == true {
            do {
                return .widget(try decoder.decode(WidgetDocument.self, from: data))
            } catch {
                throw Failure.malformed(readable(error))
            }
        }

        if schema?.hasPrefix("caliper.layout/") == true {
            do {
                let layout = try decoder.decode(LayoutDocument.self, from: data)
                guard !layout.widgets.isEmpty else { throw Failure.empty }
                return .layout(layout.widgets)
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure.malformed(readable(error))
            }
        }

        throw Failure.unrecognisedSchema(schema)
    }

    public static func parse(_ text: String) throws -> Payload {
        guard let data = text.data(using: .utf8) else { throw Failure.notJSON }
        return try parse(data)
    }

    /// The bytes to write when sharing.
    public static func export(_ document: WidgetDocument) throws -> Data {
        var shared = document
        shared.schema = WidgetDocument.schemaVersion
        // `isEnabled` is a fact about the sender's screen, not about the
        // widget. Shipping it off would silently decide something for the
        // recipient that is theirs to decide.
        shared.isEnabled = true
        // Screen position is a fact about the sender's desk, and their display
        // may be larger than the recipient's -- a widget placed at x=2400 would
        // arrive off-screen and appear not to work at all.
        shared.desktop = nil
        if shared.created == nil { shared.created = Date() }
        return try shared.encoded()
    }

    /// A suggested filename, safe for any filesystem.
    public static func filename(for document: WidgetDocument) -> String {
        let cleaned = document.name
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .trimmingCharacters(in: .whitespaces)
        let base = cleaned.isEmpty
            ? String(localized: "Widget", comment: "File name for an exported widget that has no name")
            : cleaned
        return "\(base).\(fileExtension)"
    }

    private static func readable(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        return switch decoding {
        case .keyNotFound(let key, _):
            String(
                localized: "a \u{201C}\(key.stringValue)\u{201D} field is missing",
                comment: "Import error detail. The argument is a field name from the file, kept as it is")
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            String(
                localized: "the value at \(path(context)) is the wrong kind",
                comment: "Import error detail. The argument is a path of field names, such as cells \u{203A} 0 \u{203A} style")
        case .dataCorrupted(let context):
            context.debugDescription
        @unknown default:
            String(localized: "unexpected structure", comment: "Import error detail")
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let parts = context.codingPath.map(\.stringValue)
        return parts.isEmpty
            ? String(localized: "the top level", comment: "Import error detail: where in the file, when it is the file itself")
            : parts.joined(separator: " \u{203A} ")
    }
}

public extension WidgetDocument {
    /// A copy with entirely fresh identities.
    ///
    /// Importing must never let a stranger's file collide with, or silently
    /// replace, a widget you already have -- and importing the same file twice
    /// should give you two widgets, because that is what the user asked for.
    func reidentified() -> WidgetDocument {
        var copy = self
        copy.id = UUID()
        copy.cells = cells.map { cell in
            var fresh = cell
            fresh.id = UUID()
            return fresh
        }
        return copy
    }
}
