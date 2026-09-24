import AppKit
import MetricBus
import RenderKit
import SensorKit

/// The contents of the detail popover, drawn directly.
///
/// AppKit rather than SwiftUI because SwiftUI costs about 20 MB the moment it
/// loads and never returns it, and a panel opened from the menu bar would pay
/// that on the first click of every session. The renderers needed here --
/// sparklines above all -- already exist in `RenderKit`.
///
/// ## Opaque ink, not an opaque background
///
/// The system's label colours are semi-transparent by design -- roughly 85%, 50%
/// and 25% alpha. Drawn straight onto a translucent popover they blend with
/// whatever is behind the *window*, so on a saturated desktop every label came
/// out washed-out and tinted with the wallpaper's hue.
///
/// The first attempt at fixing that filled an opaque rectangle behind the
/// content. It made the text readable and introduced a worse problem: `NSPopover`
/// draws a 13pt translucent frame around its content, so an opaque rectangle
/// inside it left a hard seam with the desktop showing through the border.
///
/// The fix that actually works is the other way round: the background stays the
/// popover's own material -- supplied by an `NSVisualEffectView` so the content
/// and the frame are the same surface with no seam -- and the *ink* is fully
/// opaque. Contrast then comes from the colours rather than from covering
/// anything up, and nothing depends on the user's wallpaper.
final class DetailPanelView: NSView {

    struct Row {
        let name: String
        let text: String
    }

    /// A group in the footer: the key the panel switches on, and the name a
    /// person reads.
    struct Chip {
        let group: String
        let title: String
    }

    struct Content {
        var group: String
        var headline: String
        var value: String
        var history: [Float]
        var unit: MetricUnit
        var range: MetricRange
        var rows: [Row]
        /// Heading for the process list, when this group has one.
        var processTitle: String?
        var processes: [Row]
        /// Shown instead of a list when the platform cannot supply one.
        var processNote: String?
        var otherGroups: [Chip]
    }

    var content: Content? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// Called when the reader picks a different group from the footer.
    var onSelectGroup: ((String) -> Void)?

    /// Where each chip was last drawn, for clicks and for VoiceOver. Only the
    /// chips that fit are here.
    private var groupChips: [(chip: Chip, frame: CGRect)] = []
    private let sparkline = HistoryGraphRenderer(style: .area, width: 268, capacity: 60)

    static let width: CGFloat = 300

    // MARK: - Layout

    /// Every vertical measurement in one place.
    ///
    /// Previously the drawing code walked a series of literals and a separate
    /// `height(rows:)` function added up its own copy of the same numbers. They
    /// agreed by luck and left twelve points under the footer where sixteen were
    /// intended. Now one pass produces the geometry and the height is whatever
    /// that pass ended up needing, so the two cannot disagree.
    private enum Metrics {
        static let sidePadding: CGFloat = 16
        static let topPadding: CGFloat = 14
        static let bottomPadding: CGFloat = 14

        static let groupHeight: CGFloat = 13
        static let groupGap: CGFloat = 8
        static let headlineHeight: CGFloat = 30
        static let plotGap: CGFloat = 12
        static let plotHeight: CGFloat = 40
        static let rowsGap: CGFloat = 14
        static let rowHeight: CGFloat = 22
        static let sectionGap: CGFloat = 14
        static let headingHeight: CGFloat = 13
        static let headingGap: CGFloat = 6
        static let noteHeight: CGFloat = 30
        static let chipsGap: CGFloat = 14
        static let chipHeight: CGFloat = 24
        static let separator: CGFloat = 1
    }

    private struct Layout {
        var group = CGRect.zero
        var headline = CGRect.zero
        var plot = CGRect.zero
        var rowsRule = CGRect.zero
        var rows: [CGRect] = []
        var processRule = CGRect.zero
        var processHeading = CGRect.zero
        var processes: [CGRect] = []
        var processNote = CGRect.zero
        var chipsRule = CGRect.zero
        var chips = CGRect.zero
        var height: CGFloat = 0
    }

    /// Laid out against a given width, never a hardcoded one.
    ///
    /// This used to assume `Self.width`. Once the popover owns the view's frame
    /// it can hand it a different width, and everything inside -- right-aligned
    /// values, the sparkline, the footer chips -- was then positioned for a
    /// panel of the wrong size.
    private static func layout(
        rows: Int,
        processes: Int,
        hasNote: Bool,
        hasChips: Bool,
        width: CGFloat
    ) -> Layout {
        var layout = Layout()
        let contentWidth = max(0, width - Metrics.sidePadding * 2)
        var cursor = Metrics.topPadding

        func take(_ height: CGFloat) -> CGRect {
            defer { cursor += height }
            // Measured downward from the top; converted to view coordinates when
            // drawn, so the arithmetic here reads in the order things appear.
            return CGRect(x: Metrics.sidePadding, y: cursor, width: contentWidth, height: height)
        }

        layout.group = take(Metrics.groupHeight)
        cursor += Metrics.groupGap
        layout.headline = take(Metrics.headlineHeight)
        cursor += Metrics.plotGap
        layout.plot = take(Metrics.plotHeight)

        if rows > 0 {
            cursor += Metrics.rowsGap
            layout.rowsRule = take(Metrics.separator)
            cursor += 6
            layout.rows = (0..<rows).map { _ in take(Metrics.rowHeight) }
        }

        if processes > 0 || hasNote {
            cursor += Metrics.sectionGap
            layout.processRule = take(Metrics.separator)
            cursor += Metrics.headingGap
            layout.processHeading = take(Metrics.headingHeight)
            cursor += 4
            if hasNote {
                layout.processNote = take(Metrics.noteHeight)
            } else {
                layout.processes = (0..<processes).map { _ in take(Metrics.rowHeight) }
            }
        }

        if hasChips {
            cursor += Metrics.chipsGap
            layout.chipsRule = take(Metrics.separator)
            cursor += Metrics.chipsGap - 2
            layout.chips = take(Metrics.chipHeight)
        }

        cursor += Metrics.bottomPadding
        layout.height = cursor
        return layout
    }

    static func height(rows: Int, processes: Int, hasNote: Bool, hasOtherGroups: Bool) -> CGFloat {
        layout(
            rows: rows, processes: processes, hasNote: hasNote,
            hasChips: hasOtherGroups, width: width
        ).height
    }

    override var isFlipped: Bool { false }

    /// Converts a top-down layout rect into view coordinates.
    private func place(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: bounds.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let content, let cgContext = NSGraphicsContext.current?.cgContext else { return }
        groupChips = []

        let layout = Self.layout(
            rows: content.rows.count,
            processes: content.processes.count,
            hasNote: content.processNote != nil,
            hasChips: !content.otherGroups.isEmpty,
            width: bounds.width
        )

        draw(content.group.uppercased(), in: place(layout.group),
             font: .systemFont(ofSize: 10, weight: .semibold),
             colour: ink(.secondary), tracking: 0.8)

        // Headline and value share a row, so the eye reads "CPU Usage: 5%" as one
        // statement rather than as two stacked things.
        let headline = place(layout.headline)
        draw(content.headline, in: headline,
             font: .systemFont(ofSize: 13, weight: .regular), colour: ink(.secondary))
        draw(content.value, in: headline,
             font: .monospacedDigitSystemFont(ofSize: 24, weight: .medium),
             colour: ink(.primary), alignment: .right)

        let plot = place(layout.plot)
        if content.history.contains(where: { $0.isFinite }) {
            sparkline.draw(
                CellInput(value: nil, history: content.history, unit: content.unit, range: content.range),
                in: cgContext,
                rect: plot,
                context: RenderContext(
                    scale: window?.backingScaleFactor ?? 2,
                    height: plot.height,
                    nominalColor: ink(.primary)
                ),
                severity: .nominal
            )
        } else {
            draw(String(localized: "Collecting history\u{2026}",
                        comment: "Detail panel: in place of the graph before there is enough to draw"),
                 in: plot,
                 font: .systemFont(ofSize: 11), colour: ink(.tertiary))
        }

        if !content.rows.isEmpty {
            rule(place(layout.rowsRule))
            let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            for (row, frame) in zip(content.rows, layout.rows) {
                let placed = place(frame)
                draw(row.name, in: placed, font: .systemFont(ofSize: 12), colour: ink(.secondary))
                draw(row.text, in: placed, font: valueFont, colour: ink(.primary), alignment: .right)
            }
        }

        if let title = content.processTitle {
            rule(place(layout.processRule))
            draw(title.uppercased(), in: place(layout.processHeading),
                 font: .systemFont(ofSize: 10, weight: .semibold),
                 colour: ink(.secondary), tracking: 0.8)

            if let note = content.processNote {
                drawWrapped(note, in: place(layout.processNote),
                            font: .systemFont(ofSize: 11), colour: ink(.tertiary))
            } else {
                let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                for (row, frame) in zip(content.processes, layout.processes) {
                    let placed = place(frame)
                    // The name is truncated rather than allowed to run into the
                    // number: a process called
                    // "com.apple.WebKit.WebContent" is wider than the panel.
                    let valueWidth = measure(row.text, font: valueFont)
                    draw(truncate(row.name, font: .systemFont(ofSize: 12),
                                  fitting: placed.width - valueWidth - 12),
                         in: placed, font: .systemFont(ofSize: 12), colour: ink(.secondary))
                    draw(row.text, in: placed, font: valueFont,
                         colour: ink(.primary), alignment: .right)
                }
            }
        }

        guard !content.otherGroups.isEmpty else { return }
        rule(place(layout.chipsRule))
        drawChips(content.otherGroups, in: place(layout.chips))
    }

    private func drawChips(_ chips: [Chip], in frame: CGRect) {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        var x = frame.minX

        for chipContent in chips {
            let width = measure(chipContent.title, font: font) + 18
            // Anything that will not fit is simply not drawn: a chip clipped by
            // the frame edge looks like a rendering fault.
            guard x + width <= frame.maxX else { break }

            let chip = CGRect(x: x, y: frame.minY, width: width, height: frame.height)
            ink(.chip).setFill()
            NSBezierPath(roundedRect: chip, xRadius: 6, yRadius: 6).fill()
            draw(chipContent.title, in: chip, font: font, colour: ink(.secondary), alignment: .center)

            groupChips.append((chipContent, chip))
            x += width + 6
        }
    }

    private func rule(_ frame: CGRect) {
        ink(.rule).setFill()
        frame.fill()
    }

    // MARK: - Ink

    private enum Ink {
        case primary, secondary, tertiary, rule, chip
    }

    /// Fully opaque colours, chosen per appearance.
    ///
    /// Deliberately not the system label colours. Those carry alpha, which is
    /// exactly what made the panel illegible over a wallpaper -- and the sparkline
    /// is drawn on the same surface, so it has to match. Fixed values mean the
    /// contrast is a property of the design rather than of what happens to be
    /// behind the window.
    private func ink(_ level: Ink) -> NSColor {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        switch level {
        case .primary: return isDark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.10, alpha: 1)
        case .secondary: return isDark ? NSColor(white: 0.68, alpha: 1) : NSColor(white: 0.36, alpha: 1)
        case .tertiary: return isDark ? NSColor(white: 0.48, alpha: 1) : NSColor(white: 0.55, alpha: 1)
        case .rule: return isDark ? NSColor(white: 0.34, alpha: 1) : NSColor(white: 0.80, alpha: 1)
        case .chip: return isDark ? NSColor(white: 0.28, alpha: 1) : NSColor(white: 0.88, alpha: 1)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = groupChips.first(where: { $0.frame.contains(point) }) else { return }
        onSelectGroup?(hit.chip.group)
    }

    // MARK: - Accessibility

    /// The panel is drawn, not built from controls, so VoiceOver would find one
    /// blank rectangle. These stand in for what is drawn: the headline, each
    /// row, the process list, and the chips -- which are buttons, and press.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { content?.group }

    override func accessibilityChildren() -> [Any]? {
        guard let content else { return [] }
        let layout = Self.layout(
            rows: content.rows.count,
            processes: content.processes.count,
            hasNote: content.processNote != nil,
            hasChips: !content.otherGroups.isEmpty,
            width: bounds.width
        )

        var children: [Any] = []
        func text(_ label: String, _ frame: CGRect) {
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel(label)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(place(frame))
            children.append(element)
        }
        func reading(_ name: String, _ value: String) -> String {
            String(localized: "\(name): \(value)",
                   comment: "VoiceOver: a row of the detail panel. A metric's name, then its reading")
        }

        text(reading(content.headline, content.value), layout.headline)
        for (row, frame) in zip(content.rows, layout.rows) {
            text(reading(row.name, row.text), frame)
        }
        if let title = content.processTitle {
            text(title, layout.processHeading)
            if let note = content.processNote {
                text(note, layout.processNote)
            } else {
                for (row, frame) in zip(content.processes, layout.processes) {
                    text(reading(row.name, row.text), frame)
                }
            }
        }
        for (chip, frame) in groupChips {
            let button = ChipElement()
            button.setAccessibilityRole(.button)
            button.setAccessibilityLabel(chip.title)
            button.setAccessibilityParent(self)
            button.setAccessibilityFrameInParentSpace(frame)
            button.onPress = { [weak self] in self?.onSelectGroup?(chip.group) }
            children.append(button)
        }
        return children
    }

    /// A footer chip, pressable from VoiceOver as it is clickable with a mouse.
    private final class ChipElement: NSAccessibilityElement {
        var onPress: (() -> Void)?

        override func accessibilityPerformPress() -> Bool {
            onPress?()
            return onPress != nil
        }
    }

    // MARK: - Text

    private func attributes(
        _ font: NSFont, _ colour: NSColor, tracking: CGFloat = 0
    ) -> [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
        if tracking != 0 { result[.kern] = tracking }
        return result
    }

    /// Draws text vertically centred in a rect, so every element lines up on the
    /// same grid instead of being nudged by hand.
    private func draw(
        _ text: String,
        in rect: CGRect,
        font: NSFont,
        colour: NSColor,
        tracking: CGFloat = 0,
        alignment: NSTextAlignment = .left
    ) {
        let attributed = NSAttributedString(
            string: text, attributes: attributes(font, colour, tracking: tracking)
        )
        let size = attributed.size()

        let x = switch alignment {
        case .right: rect.maxX - size.width
        case .center: rect.midX - size.width / 2
        default: rect.minX
        }

        attributed.draw(at: CGPoint(x: x, y: rect.midY - size.height / 2))
    }

    /// Trims to fit, with an ellipsis, so a long process name cannot collide
    /// with its own reading.
    private func truncate(_ text: String, font: NSFont, fitting width: CGFloat) -> String {
        guard measure(text, font: font) > width, width > 0 else { return text }

        var trimmed = text
        while !trimmed.isEmpty, measure(trimmed + "\u{2026}", font: font) > width {
            trimmed.removeLast()
        }
        return trimmed.isEmpty ? text : trimmed + "\u{2026}"
    }

    /// Two lines of small explanatory text.
    private func drawWrapped(_ text: String, in rect: CGRect, font: NSFont, colour: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: colour, .paragraphStyle: style]
        ).draw(with: rect, options: [.usesLineFragmentOrigin])
    }

    private func measure(_ text: String, font: NSFont) -> CGFloat {
        NSAttributedString(string: text, attributes: attributes(font, .labelColor)).size().width
    }
}
