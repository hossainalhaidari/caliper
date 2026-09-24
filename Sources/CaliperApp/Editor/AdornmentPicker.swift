import AppKit
import SchemaKit
import SwiftUI

/// Choosing what identifies a cell: nothing, a caption, a symbol, or an emoji.
struct AdornmentPicker: View {
    let cell: CellDocument
    let onChange: (CellDocument) -> Void

    private enum Kind: String, CaseIterable, Identifiable {
        case none = "None"
        case text = "Text"
        case symbol = "Icon"
        case emoji = "Emoji"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .none: String(localized: "None", comment: "Cell inspector: no metric, or no threshold")
            case .text: String(localized: "Text", comment: "Cell adornment: a written caption")
            case .symbol: String(localized: "Icon", comment: "Cell adornment: an SF Symbol")
            case .emoji: String(localized: "Emoji", comment: "Cell adornment: an emoji")
            }
        }
    }

    private var kind: Kind {
        switch cell.icon {
        case .symbol: .symbol
        case .emoji: .emoji
        case nil: (cell.label?.isEmpty == false) ? .text : .none
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Show", selection: kindBinding) {
                ForEach(Kind.allCases) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            switch kind {
            case .none:
                Text("The cell shows only its value.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)

            case .text:
                LabeledContent("Caption") {
                    TextField("CPU", text: labelBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
                Text("Drawn dimmer than the value, so it reads as a second layer.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)

            case .symbol:
                SymbolGrid(selected: cell.icon?.value) { name in
                    var updated = cell
                    updated.icon = .symbol(name)
                    onChange(updated)
                }
                Text("Monochrome, so it tints with the menu bar exactly as text does.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)

            case .emoji:
                LabeledContent("Emoji") {
                    TextField("\u{1F525}", text: emojiBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                Text("Press Control-Command-Space for the emoji picker. Emoji are drawn in colour, so a strip containing one no longer adapts to the menu bar's tint.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Bindings

    private var kindBinding: Binding<Kind> {
        Binding(
            get: { kind },
            set: { value in
                var updated = cell
                switch value {
                case .none:
                    updated.label = nil
                    updated.icon = nil
                case .text:
                    updated.icon = nil
                    // Kept if the cell had one before, so switching away and back
                    // does not silently discard what was typed.
                    if updated.label?.isEmpty != false { updated.label = "" }
                case .symbol:
                    updated.icon = .symbol(SymbolGrid.available.first ?? "gauge.with.dots.needle.50percent")
                case .emoji:
                    updated.icon = .emoji("\u{1F525}")
                }
                onChange(updated)
            }
        )
    }

    private var labelBinding: Binding<String> {
        Binding(
            get: { cell.label ?? "" },
            set: { value in
                var updated = cell
                // The same limit an import applies, so a caption typed here can
                // always be sent to somebody.
                let value = WidgetLimits.truncated(value, to: WidgetLimits.captionLength)
                updated.label = value.isEmpty ? nil : value
                updated.icon = nil
                onChange(updated)
            }
        )
    }

    private var emojiBinding: Binding<String> {
        Binding(
            get: { cell.icon?.value ?? "" },
            set: { value in
                var updated = cell
                // One glyph only: more than that stops being an icon and starts
                // being a caption in the wrong font.
                let glyphs = WidgetLimits.truncated(String(value.prefix(2)), to: WidgetLimits.emojiLength)
                updated.icon = glyphs.isEmpty ? nil : .emoji(glyphs)
                onChange(updated)
            }
        )
    }
}

/// A grid of SF Symbols suited to system statistics.
///
/// Filtered to what this macOS actually resolves, so the picker cannot offer a
/// symbol that would render as nothing. Symbol names come and go between
/// releases, and a hardcoded list eventually contains ghosts.
private struct SymbolGrid: View {
    let selected: String?
    let onPick: (String) -> Void

    private static let candidates = [
        "cpu", "memorychip", "internaldrive", "externaldrive", "opticaldiscdrive",
        "network", "wifi", "antenna.radiowaves.left.and.right", "globe",
        "thermometer.medium", "thermometer.sun", "flame",
        "bolt", "bolt.fill", "battery.100", "battery.50",
        "gauge.with.dots.needle.50percent", "speedometer", "fan.desk",
        "chart.line.uptrend.xyaxis", "waveform.path.ecg",
        "arrow.down", "arrow.up", "arrow.up.arrow.down",
        "display", "desktopcomputer", "laptopcomputer", "server.rack",
        "clock", "hourglass", "square.stack.3d.up",
    ]

    static let available: [String] = candidates.filter {
        NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 8), spacing: 6) {
            ForEach(Self.available, id: \.self) { name in
                Button {
                    onPick(name)
                } label: {
                    Image(systemName: name)
                        .frame(width: 28, height: 24)
                        .background {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(selected == name
                                      ? Color.accentColor.opacity(0.25)
                                      : Color.secondary.opacity(0.10))
                        }
                }
                .buttonStyle(.plain)
                .help(name)
            }
        }
    }
}
