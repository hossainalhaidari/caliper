import Foundation
import Testing

/// The contract that makes a new language a copy-and-translate job rather than a hunt.
///
/// Three things have to hold, and none of them can be seen by running the app in English:
///
/// - every localizable string in the source has an entry in `en.lproj`, or it silently stays English
///   in every language;
/// - every entry in `en.lproj` is still used by some string in the source, or translators are paid
///   to translate dead text;
/// - every other `.lproj` holds exactly the keys English does, so a language is either complete or
///   says which lines are missing.
///
/// A failure prints the keys rather than a count, and `CALIPER_DUMP_STRINGS=1 swift test` writes a
/// ready-made catalogue to the temporary directory -- which is how `en.lproj/Localizable.strings`
/// was built in the first place.
///
/// Every library is scanned, not only the app: metric names, style names and import reports are
/// written in SensorKit and SchemaKit and read in the app, and `String(localized:)` resolves them
/// against the app's bundle wherever they were written. `CaliperBench` is left out -- a developer's
/// command-line tool, which never ships and speaks English.
@Suite struct LocalizationTests {
    /// Interpolated keys are matched as patterns: the specifier Foundation generates depends on the
    /// interpolated type (`%lld` for a count, `%@` for a name), which the source text does not say.
    private static let specifier = "%(?:[0-9]+\\$)?(?:@|lld|ld|d|u|f|lf|\\.[0-9]+f)"

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LocalizationTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
    }

    private static var englishDirectory: URL {
        repositoryRoot.appendingPathComponent("Resources/en.lproj")
    }

    /// Source directories that never reach the user.
    private static let unshipped: Set<String> = ["CaliperBench"]

    /// Every localizable string the source contains, by pattern.
    private static let scanned: [LocalizableScan.Found] = {
        let sources = repositoryRoot.appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var found: [LocalizableScan.Found] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let module = url.pathComponents.dropFirst(sources.pathComponents.count).first ?? ""
            guard !unshipped.contains(module) else { continue }
            found += (try? LocalizableScan.scan(file: url)) ?? []
        }
        return found
    }()

    // MARK: - The catalogue covers the source

    @Test func theScanFindsTheSource() {
        // A scanner that quietly found nothing would pass every test below.
        #expect(Self.scanned.count > 200, "only \(Self.scanned.count) strings found -- is the scan looking in the right place?")
    }

    @Test func everyLocalizableStringHasAnEnglishEntry() throws {
        let catalogue = try Self.keys(inStringsAt: Self.englishDirectory)
        let plurals = try Self.pluralKeys(at: Self.englishDirectory)
        let available = catalogue.union(plurals)

        Self.dumpIfAsked(existing: catalogue)

        let missing = Self.scanned.filter { found in
            !available.contains { Self.key($0, matches: found.pattern) }
        }
        #expect(
            missing.isEmpty,
            """
            \(missing.count) string(s) in the source have no entry in Resources/en.lproj. \
            Add them to Localizable.strings (or Localizable.stringsdict if one takes a count):
            \(missing.map { "  \($0.file):\($0.line)  \(Self.display($0.pattern))" }.joined(separator: "\n"))
            """)
    }

    /// The other direction. A key nobody asks for any more is a line every translator still pays
    /// for, and nothing in the running app would ever reveal it.
    @Test func theEnglishCatalogueHasNothingSpare() throws {
        let catalogue = try Self.keys(inStringsAt: Self.englishDirectory)
            .union(try Self.pluralKeys(at: Self.englishDirectory))
        let patterns = Set(Self.scanned.map(\.pattern))

        let orphans = catalogue.filter { key in
            !patterns.contains { Self.key(key, matches: $0) }
        }
        #expect(
            orphans.isEmpty,
            """
            \(orphans.count) entr(y/ies) in Resources/en.lproj match no string in the source. \
            Remove them:
            \(orphans.sorted().map { "  \($0)" }.joined(separator: "\n"))
            """)
    }

    /// English is the development language, so a value that is not simply the key back again means
    /// somebody has edited the wrong column.
    @Test func englishValuesAreTheirOwnKeys() throws {
        let entries = try Self.entries(inStringsAt: Self.englishDirectory)
        let edited = entries.filter { $0.key != $0.value }.map(\.key)
        #expect(
            edited.isEmpty,
            """
            In en.lproj the value is the English text, so it must equal the key. These differ:
            \(edited.sorted().map { "  \($0)" }.joined(separator: "\n"))
            """)
    }

    // MARK: - Every other language matches English

    /// What makes adding a language checkable: German is complete, or this says which lines are not.
    @Test func everyTranslationCoversTheSameKeysAsEnglish() throws {
        let english = try Self.keys(inStringsAt: Self.englishDirectory)

        for directory in try Self.localizationDirectories() {
            let language = directory.deletingPathExtension().lastPathComponent
            guard language != "en" else { continue }
            let translated = try Self.keys(inStringsAt: directory)

            let missing = english.subtracting(translated).sorted()
            let spare = translated.subtracting(english).sorted()
            #expect(
                missing.isEmpty,
                """
                \(language) is missing \(missing.count) key(s):
                \(missing.map { "  \($0)" }.joined(separator: "\n"))
                """)
            #expect(
                spare.isEmpty,
                """
                \(language) has \(spare.count) key(s) English does not:
                \(spare.map { "  \($0)" }.joined(separator: "\n"))
                """)
        }
    }

    /// A plural rule is per language -- Polish needs three forms where English needs two -- so the
    /// keys have to line up even though the number of forms behind each one does not.
    @Test func everyTranslationCoversTheSamePluralsAsEnglish() throws {
        let english = try Self.pluralKeys(at: Self.englishDirectory)

        for directory in try Self.localizationDirectories() {
            let language = directory.deletingPathExtension().lastPathComponent
            guard language != "en" else { continue }
            let translated = try Self.pluralKeys(at: directory)
            let missing = english.subtracting(translated).sorted()
            #expect(
                missing.isEmpty,
                """
                \(language) has no plural rule for \(missing.count) key(s):
                \(missing.map { "  \($0)" }.joined(separator: "\n"))
                """)
        }
    }

    /// The counted strings resolve through the catalogue rather than falling back to the key, and
    /// the two forms English declares are actually different. `1 cells` is the kind of thing that
    /// makes a sheet look unfinished, and it is invisible until somebody imports exactly one.
    @Test func theEnglishPluralFormsAreApplied() throws {
        let bundle = try #require(Bundle(url: Self.englishDirectory.deletingLastPathComponent()))

        let one = 1
        let four = 4
        #expect(String(localized: "\(one) cells", bundle: bundle) == "1 cell")
        #expect(String(localized: "\(four) cells", bundle: bundle) == "4 cells")
        #expect(String(localized: "\(one) metrics unavailable", bundle: bundle) == "1 metric unavailable")
        #expect(String(localized: "\(one) cells could not be shown", bundle: bundle) == "1 cell could not be shown")
        #expect(String(localized: "Add \(four) widgets?", bundle: bundle) == "Add 4 widgets?")

        // Several arguments with the plural in the middle: the positions in the rule have to line
        // up with the arguments around it, or the name and the limit swap places.
        let name = "Wall"
        let cells = 300
        let limit = 24
        #expect(String(localized: "\u{201C}\(name)\u{201D} has \(cells) cells, and a widget can have at most \(limit). Ask whoever sent it to split it into smaller widgets.", bundle: bundle)
                == "\u{201C}Wall\u{201D} has 300 cells, and a widget can have at most 24. Ask whoever sent it to split it into smaller widgets.")
        let field = "label"
        #expect(String(localized: "Cell \(one) of \u{201C}\(name)\u{201D} has a \(field) \(one) characters long, and it can be at most \(limit).", bundle: bundle)
                == "Cell 1 of \u{201C}Wall\u{201D} has a label 1 character long, and it can be at most 24.")
    }

    /// Info.plist strings are looked up by their Info.plist key -- or, for a document type, by its
    /// English name -- so the check is that every key there names something Info.plist has.
    @Test func infoPlistStringsNameRealKeys() throws {
        let strings = Self.englishDirectory.appendingPathComponent("InfoPlist.strings")
        guard let table = NSDictionary(contentsOf: strings) as? [String: String] else {
            Issue.record("Resources/en.lproj/InfoPlist.strings could not be read")
            return
        }
        let plistURL = Self.repositoryRoot.appendingPathComponent("Resources/Info.plist")
        let plist = try #require(NSDictionary(contentsOf: plistURL) as? [String: Any])

        let documentTypes = (plist["CFBundleDocumentTypes"] as? [[String: Any]] ?? [])
            .compactMap { $0["CFBundleTypeName"] as? String }
        let exportedTypes = (plist["UTExportedTypeDeclarations"] as? [[String: Any]] ?? [])
            .compactMap { $0["UTTypeDescription"] as? String }
        let names = Set(documentTypes + exportedTypes)

        for key in table.keys {
            #expect(
                plist[key] != nil || names.contains(key),
                "InfoPlist.strings translates \(key), which Info.plist does not have")
        }
    }

    // MARK: - Reading the catalogues

    private static func localizationDirectories() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: repositoryRoot.appendingPathComponent("Resources"),
                                 includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func entries(inStringsAt directory: URL) throws -> [(key: String, value: String)] {
        let url = directory.appendingPathComponent("Localizable.strings")
        let data = try Data(contentsOf: url)
        guard let table = try PropertyListSerialization
            .propertyList(from: data, format: nil) as? [String: String]
        else { throw CocoaError(.propertyListReadCorrupt) }
        return table.map { (key: $0.key, value: $0.value) }
    }

    private static func keys(inStringsAt directory: URL) throws -> Set<String> {
        Set(try entries(inStringsAt: directory).map(\.key))
    }

    private static func pluralKeys(at directory: URL) throws -> Set<String> {
        let url = directory.appendingPathComponent("Localizable.stringsdict")
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let table = try PropertyListSerialization
            .propertyList(from: data, format: nil) as? [String: Any]
        else { throw CocoaError(.propertyListReadCorrupt) }
        return Set(table.keys)
    }

    /// Whether a catalogue key is the same string as a scanned pattern, treating each interpolation
    /// as "some format specifier".
    private static func key(_ key: String, matches pattern: String) -> Bool {
        guard pattern.contains(LocalizableScan.interpolation) else { return key == pattern }
        let expression = pattern
            .split(separator: LocalizableScan.interpolation, omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: specifier)
        let range = NSRange(key.startIndex..., in: key)
        return (try? NSRegularExpression(pattern: "^" + expression + "$"))?
            .firstMatch(in: key, range: range) != nil
    }

    private static func display(_ pattern: String) -> String {
        pattern
            .replacingOccurrences(of: String(LocalizableScan.interpolation), with: "%@")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Writes what the catalogue would look like if it were generated from the source right now.
    /// Not a test -- a way to start a catalogue, or to see a diff when one has drifted a long way.
    private static func dumpIfAsked(existing: Set<String>) {
        guard ProcessInfo.processInfo.environment["CALIPER_DUMP_STRINGS"] == "1" else { return }
        var lines: [String] = [
            "/* Generated by CALIPER_DUMP_STRINGS=1 swift test. Interpolated keys need their",
            "   specifier chosen by hand: %lld for a count, %@ for a name. */",
            "",
        ]
        // One entry per key, with every place it is used, because the same words in two places are
        // one line for a translator rather than two.
        let sites = Dictionary(grouping: scanned, by: \.pattern)
        for pattern in sites.keys.sorted() {
            let key = escaped(pattern)
                .replacingOccurrences(of: String(LocalizableScan.interpolation), with: "%@")
            let uses = sites[pattern] ?? []
            let where_ = uses.map { "\($0.file):\($0.line)" }.sorted().joined(separator: ", ")
            // The note the author wrote for whoever translates this, where there was one.
            let note = uses.compactMap(\.comment).first
            lines.append(note.map { "/* \($0)\n   \(where_) */" } ?? "/* \(where_) */")
            lines.append("\"\(key)\" = \"\(key)\";")
            lines.append("")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Caliper-Localizable.strings")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        print("wrote \(scanned.count) scanned keys (\(existing.count) already present) to \(url.path)")
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
