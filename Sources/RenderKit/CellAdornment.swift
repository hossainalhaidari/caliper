import AppKit
import CoreGraphics
import CoreText

/// What identifies a cell, sitting before its value.
///
/// Drawn by the compositor rather than by each renderer. Previously only
/// `TextValueRenderer` handled labels, so setting one on a donut or a graph did
/// nothing at all -- the width was never reserved and nothing was drawn. Six
/// renderers each doing their own label handling is six chances to forget, and
/// one of them already had.
///
/// Hoisting it means every style gets adornments for free, they are styled
/// identically everywhere, and a style added later cannot miss the feature.
public enum CellAdornment: Equatable, Sendable {
    case none
    /// A short caption: "CPU", "MEM".
    case text(String)
    /// An SF Symbol name. Monochrome, so it tints with the menu bar exactly as
    /// text does and keeps the strip a template image.
    case symbol(String)
    /// Any emoji. Renders in colour, which has a consequence -- see
    /// `forcesColour`.
    case emoji(String)

    public var isEmpty: Bool {
        switch self {
        case .none: true
        case .text(let value), .symbol(let value), .emoji(let value): value.isEmpty
        }
    }

    /// Emoji are colour glyphs, so a strip containing one cannot be a template
    /// image -- AppKit would flatten it to a silhouette. The compositor asks
    /// this so it can fall back to explicitly resolved colours, the same path an
    /// alerting cell already takes.
    public var forcesColour: Bool {
        if case .emoji(let value) = self { return !value.isEmpty }
        return false
    }

    /// Stable across ticks, so it can go in a redraw key.
    public var changeKey: String {
        switch self {
        case .none: ""
        case .text(let value): "t:\(value)"
        case .symbol(let value): "s:\(value)"
        case .emoji(let value): "e:\(value)"
        }
    }
}

/// Measures and draws adornments.
public enum AdornmentPainter {

    /// Gap between the adornment and the value it introduces.
    static let gap: CGFloat = 3

    /// Deliberately smaller and lighter than the value. In a strip of several
    /// cells the adornments form a quiet second layer you can read when you need
    /// it and ignore when you don't.
    static func font(_ context: RenderContext) -> NSFont {
        NSFont.systemFont(ofSize: context.font.pointSize * 0.85, weight: .medium)
    }

    /// How much larger than the type an icon draws.
    ///
    /// Icons used to be sized like the text, at 0.95x, which put a symbol 13pt
    /// tall in a 22pt menu bar -- beside system items whose glyphs are 17 to 18.
    /// The strip read as a smaller, fainter class of thing rather than as one of
    /// the neighbours. Measured against them, 1.3x is the size the menu bar
    /// actually uses.
    ///
    /// Relative to the font rather than a fixed number of points, so it follows
    /// the density preset and the desktop panel, which sizes its own font from
    /// the drawing height.
    static let symbolScale: CGFloat = 1.3

    /// Emoji are full-bleed square glyphs where a symbol is a thin drawing, so
    /// the same multiplier makes them read as bigger. Scaled less to land at the
    /// same visual weight.
    static let emojiScale: CGFloat = 1.15

    /// The tallest an icon may draw, leaving the margin the menu bar's own
    /// items keep.
    private static func heightLimit(_ context: RenderContext) -> CGFloat {
        context.height - 4
    }

    /// Symbol images, kept rather than rebuilt every frame.
    ///
    /// A symbol image is a pure function of its name and size, and each frame
    /// asks for the same one twice -- once to reserve the width, once to draw
    /// it -- plus a second time over for anything that needs fitting. Measured
    /// at 205 us/frame against 65 for the same cell wearing a text caption, in
    /// the one loop this app runs for as long as the Mac is on.
    ///
    /// `NSCache` rather than a dictionary: it is thread-safe by contract, so
    /// the painter does not have to become main-actor-only to hold state, and
    /// it evicts under pressure -- exactly right for something that can always
    /// be rebuilt from its key.
    nonisolated(unsafe) private static let symbolCache = NSCache<NSString, NSImage>()

    /// An SF Symbol at icon size, fitted to the strip.
    ///
    /// The fit is the point of the second pass. Symbols are not square -- at one
    /// point size `cpu` comes back 19x18 and `bolt.fill` 15x21 -- so asking for
    /// a point size and drawing whatever arrives would let the vertical symbols
    /// fill the bar edge to edge while the wide ones sat comfortably. Fitting to
    /// the canvas keeps a strip of mixed icons looking like one row.
    private static func symbolImage(_ name: String, in context: RenderContext) -> NSImage? {
        let pointSize = context.font.pointSize * symbolScale
        let limit = heightLimit(context)
        // Rounded, so the float noise in a font size derived from a panel
        // height cannot turn one icon into a hundred cache entries.
        //
        // Keyed by backing scale as well, because the image is taken as a
        // CGImage and used as a mask: an entry rasterised for a 1x display
        // must not be the one a 2x display draws through. Two entries per icon
        // is the whole cost of not having to reason about that.
        let key = """
        \(name)|\((pointSize * 100).rounded())|\((limit * 100).rounded())|\(context.scale)
        """ as NSString

        if let cached = symbolCache.object(forKey: key) { return cached }

        // A name this macOS does not have is not cached: there is no object to
        // put in an NSCache for "nothing", and the lookup that fails is the
        // cheap half of this function anyway.
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        guard let sized = image.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        ) else { return nil }

        let fitted: NSImage
        if sized.size.height > limit {
            fitted = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: pointSize * limit / sized.size.height,
                    weight: .medium
                )
            ) ?? sized
        } else {
            fitted = sized
        }

        symbolCache.setObject(fitted, forKey: key)
        return fitted
    }

    /// Total horizontal space the adornment occupies, including its trailing gap.
    public static func advance(_ adornment: CellAdornment, in context: RenderContext) -> CGFloat {
        guard !adornment.isEmpty else { return 0 }

        switch adornment {
        case .none:
            return 0
        case .text(let value):
            return TextDraw.measure(value, font: font(context)) + gap
        case .emoji(let value):
            return TextDraw.measure(value, font: emojiFont(context)) + gap
        case .symbol(let name):
            // An unrecognised symbol name takes no space rather than leaving a
            // hole: a widget naming a symbol this macOS does not have should
            // look like it has no icon, not like it is broken.
            guard let image = symbolImage(name, in: context) else { return 0 }
            return image.size.width + gap
        }
    }

    static func emojiFont(_ context: RenderContext) -> NSFont {
        NSFont.systemFont(ofSize: context.font.pointSize * emojiScale)
    }

    /// How far an adornment recedes while nothing is wrong.
    ///
    /// A caption can afford to recede a long way: it repeats what the value
    /// beside it already says. An icon cannot -- it is the only thing naming the
    /// cell, and at a caption's 55% it read as disabled next to the
    /// full-strength glyphs of every other item in the menu bar.
    private static func quietAlpha(_ adornment: CellAdornment) -> CGFloat {
        if case .symbol = adornment { return 0.85 }
        return 0.55
    }

    /// Draws at the left edge of `rect`, vertically centred.
    public static func draw(
        _ adornment: CellAdornment,
        in cgContext: CGContext,
        rect: CGRect,
        context: RenderContext,
        color: NSColor,
        isNominal: Bool
    ) {
        guard !adornment.isEmpty else { return }

        // Dimmed while quiet, full strength while alerting -- so an adornment
        // never competes with its value for attention, but does follow it into
        // the alerting state rather than staying grey beside a red number.
        let tint = isNominal ? color.withAlphaComponent(quietAlpha(adornment)) : color

        switch adornment {
        case .none:
            return

        case .text(let value):
            TextDraw.draw(value, font: font(context), color: tint,
                          at: rect.minX, in: rect, context: cgContext)

        case .emoji(let value):
            // Drawn at full opacity: dimming an emoji makes it muddy rather
            // than quiet, because its colours are its own.
            TextDraw.draw(value, font: emojiFont(context), color: .black,
                          at: rect.minX, in: rect, context: cgContext)

        case .symbol(let name):
            guard let image = symbolImage(name, in: context) else { return }
            var target = CGRect(
                x: rect.minX,
                y: rect.midY - image.size.height / 2,
                width: image.size.width,
                height: image.size.height
            )
            guard let cgImage = image.cgImage(forProposedRect: &target, context: nil, hints: nil)
            else { return }

            // Clipped to the glyph's alpha and filled, which tints an SF Symbol
            // the same way AppKit tints a template image.
            cgContext.saveGState()
            cgContext.clip(to: target, mask: cgImage)
            cgContext.setFillColor(tint.cgColor)
            cgContext.fill(target)
            cgContext.restoreGState()
        }
    }
}
