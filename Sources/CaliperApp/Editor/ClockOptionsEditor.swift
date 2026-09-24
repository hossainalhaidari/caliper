import Combine
import RenderKit
import SchemaKit
import SwiftUI

/// Everything about how a clock cell reads.
///
/// Built around a live preview rather than documentation. A format string is
/// unguessable -- nobody remembers whether the month is `MM`, `LLL` or `%b` --
/// so the honest interface is one that shows you the answer as you type.
struct ClockOptionsEditor: View {
    let options: CellStyle.ClockOptions
    let onChange: (CellStyle.ClockOptions) -> Void

    @State private var pickingZone = false
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Common formats, in both dialects. Picking one writes its format *and* its
    /// syntax, so the two can never disagree.
    ///
    /// A pattern preset with no label is titled with what it draws for one
    /// fixed moment, rendered by the same code as the menu bar -- so the menu
    /// reads "Di. 25. Aug." to someone whose Mac is in German, where a written
    /// label could only ever have said "Tue 25 Aug". strftime presets are
    /// titled with their own codes, which is what that dialect's users look for.
    private static let presets: [(label: String?, format: String, syntax: ClockFormat.Syntax)] = [
        (nil, "HH:mm", .pattern),
        (nil, "HH:mm:ss", .pattern),
        (nil, "h:mm a", .pattern),
        (nil, "EEE d MMM", .pattern),
        (nil, "EEE d MMM HH:mm", .pattern),
        (nil, "yyyy-MM-dd", .pattern),
        (
            String(localized: "Two lines", comment: "Clock preset: date above, time below"),
            "EEE d MMM\nHH:mm:ss",
            .pattern
        ),
        ("%H:%M", "%H:%M", .strftime),
        ("%a %d %b %H:%M", "%a %d %b %H:%M", .strftime),
        ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M:%S", .strftime),
        ("%I:%M %p %Z", "%I:%M %p %Z", .strftime),
    ]

    /// The moment the unlabelled presets are drawn at: an afternoon, so a
    /// 12-hour format shows its PM, and a day and month that cannot be confused.
    private static let sampleMoment = Calendar.current.date(
        from: DateComponents(year: 2026, month: 8, day: 25, hour: 14, minute: 30, second: 45)
    ) ?? Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            preview

            Picker("Syntax", selection: syntaxBinding) {
                Text("Pattern").tag(ClockFormat.Syntax.pattern)
                Text("strftime").tag(ClockFormat.Syntax.strftime)
            }
            .pickerStyle(.segmented)

            LabeledContent("Format") {
                TextField("HH:mm", text: formatBinding, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1...3)
                    .frame(width: 220)
            }

            Menu("Presets\u{2026}") {
                ForEach(Array(Self.presets.enumerated()), id: \.offset) { _, preset in
                    Button(preset.label ?? ClockFormat(format: preset.format, syntax: preset.syntax)
                        .string(at: Self.sampleMoment)) {
                        var updated = options
                        updated.format = preset.format
                        updated.syntax = preset.syntax
                        onChange(updated)
                    }
                }
            }
            .frame(width: 140)

            LabeledContent("Time zone") {
                Button(options.timeZone
                       ?? String(localized: "System", comment: "Clock time zone: follow the Mac's own")) {
                    pickingZone = true
                }
                    .popover(isPresented: $pickingZone, arrowEdge: .bottom) {
                        TimeZonePicker(selected: options.timeZone) { identifier in
                            var updated = options
                            updated.timeZone = identifier
                            onChange(updated)
                            pickingZone = false
                        }
                    }
            }

            reference
        }
        .onReceive(tick) { now = $0 }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preview")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(options.clockFormatPreview(at: now))
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background {
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.10))
                }
        }
    }

    @ViewBuilder
    private var reference: some View {
        let items: [(String, String)] = options.syntax == .strftime
            ? [("%H %M %S", String(localized: "24-hour, minute, second", comment: "Clock format reference: what a format code stands for")),
               ("%I %p", String(localized: "12-hour, AM/PM", comment: "Clock format reference: what a format code stands for")),
               ("%a %A", String(localized: "weekday, short and full", comment: "Clock format reference: what a format code stands for")),
               ("%b %B", String(localized: "month, short and full", comment: "Clock format reference: what a format code stands for")),
               ("%d %-d", String(localized: "day, padded and not", comment: "Clock format reference: what a format code stands for")),
               ("%Y %m", String(localized: "year, month number", comment: "Clock format reference: what a format code stands for")),
               ("%Z %z", String(localized: "zone name, offset", comment: "Clock format reference: what a format code stands for"))]
            : [("HH mm ss", String(localized: "24-hour, minute, second", comment: "Clock format reference: what a format code stands for")),
               ("h a", String(localized: "12-hour, AM/PM", comment: "Clock format reference: what a format code stands for")),
               ("EEE EEEE", String(localized: "weekday, short and full", comment: "Clock format reference: what a format code stands for")),
               ("MMM MMMM", String(localized: "month, short and full", comment: "Clock format reference: what a format code stands for")),
               ("d dd", String(localized: "day, unpadded and padded", comment: "Clock format reference: what a format code stands for")),
               ("yyyy MM", String(localized: "year, month number", comment: "Clock format reference: what a format code stands for")),
               ("zzz Z", String(localized: "zone name, offset", comment: "Clock format reference: what a format code stands for"))]

        VStack(alignment: .leading, spacing: 3) {
            Text(options.syntax == .strftime
                 ? "strftime, as on Linux. A newline stacks the clock into two rows."
                 : "Unicode date patterns, as macOS uses. A newline stacks the clock into two rows.")
                .font(.callout)
                .foregroundStyle(.tertiary)

            ForEach(items, id: \.0) { code, meaning in
                HStack(spacing: 8) {
                    Text(code)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 92, alignment: .leading)
                    Text(meaning)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var formatBinding: Binding<String> {
        Binding(
            get: { options.format },
            set: { value in
                var updated = options
                updated.format = WidgetLimits.truncated(value, to: WidgetLimits.clockFormatLength)
                onChange(updated)
            }
        )
    }

    private var syntaxBinding: Binding<ClockFormat.Syntax> {
        Binding(
            get: { options.syntax },
            set: { value in
                var updated = options
                updated.syntax = value
                onChange(updated)
            }
        )
    }
}

private extension CellStyle.ClockOptions {
    /// Rendered by the same code the menu bar uses, so the preview cannot lie.
    func clockFormatPreview(at date: Date) -> String {
        let text = ClockFormat(
            format: format, syntax: syntax, timeZone: timeZone, locale: locale
        ).string(at: date)
        return text.isEmpty ? "\u{2014}" : text
    }
}

/// A searchable list of every zone the system knows, plus following the system.
private struct TimeZonePicker: View {
    let selected: String?
    let onPick: (String?) -> Void

    @State private var query = ""

    private var matches: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers.sorted()
        guard !query.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)

            Divider()

            List {
                Button("System (\(TimeZone.current.identifier))") { onPick(nil) }
                    .buttonStyle(.plain)

                ForEach(matches, id: \.self) { identifier in
                    Button {
                        onPick(identifier)
                    } label: {
                        HStack {
                            Text(identifier)
                            Spacer()
                            if identifier == selected {
                                Image(systemName: "checkmark").foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 300, height: 360)
    }
}
