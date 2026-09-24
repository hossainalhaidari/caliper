import AppKit
import CoreGraphics

/// How much room a cell gives itself.
///
/// Density is a **setting, not a default**. People run this on a 13" MacBook
/// with fourteen other menu bar items, and on a 32" display with three. One
/// fixed spacing cannot serve both, and per-cell padding controls would push
/// that decision onto the user one cell at a time. Three coherent presets that
/// move padding and type size together is the honest middle.
public enum Density: String, Codable, CaseIterable, Sendable {
    case compact
    case regular
    case roomy

    public var fontSize: CGFloat {
        switch self {
        case .compact: 10.0
        case .regular: 11.5
        case .roomy: 13.0
        }
    }

    /// The name in the editor's density picker.
    public var title: String {
        switch self {
        case .compact: String(localized: "Compact", comment: "Density: cells as tight as they go")
        case .regular: String(localized: "Regular", comment: "Density: the default spacing")
        case .roomy: String(localized: "Roomy", comment: "Density: cells with the most room")
        }
    }

    /// Horizontal breathing room inside a single cell.
    public var cellPadding: CGFloat {
        switch self {
        case .compact: 1.0
        case .regular: 2.0
        case .roomy: 3.0
        }
    }

    /// Gap between adjacent cells in a strip.
    public var cellSpacing: CGFloat {
        switch self {
        case .compact: 4.0
        case .regular: 6.0
        case .roomy: 8.0
        }
    }
}

/// What a value currently means, not what it currently is.
///
/// This is the backbone of the "colour is signal" rule: a nominal cell draws as
/// a **template image**, which AppKit tints to match the menu bar in light
/// mode, dark mode, and under a tinted wallpaper -- so the normal state of the
/// app is a calm monochrome strip that looks like it shipped with macOS.
/// Colour appears only when something crosses a threshold, which means colour
/// in the menu bar always carries information.
public enum Severity: Sendable, Comparable, CaseIterable {
    case nominal
    case elevated
    case critical

    /// `nil` means "draw as a template and let AppKit decide" -- deliberately
    /// not a hardcoded black or white.
    public var color: NSColor? {
        switch self {
        case .nominal: nil
        case .elevated: NSColor.systemOrange
        case .critical: NSColor.systemRed
        }
    }
}

/// The value at which a metric stops being unremarkable.
///
/// Both bounds are optional because most metrics have no meaningful ceiling.
/// A cell with no thresholds is permanently nominal, which is the right default:
/// a new cell should be quiet until its owner says what "bad" looks like.
public struct Thresholds: Sendable, Codable, Equatable {
    public var elevated: Double?
    public var critical: Double?

    public static let none = Thresholds()

    public init(elevated: Double? = nil, critical: Double? = nil) {
        self.elevated = elevated
        self.critical = critical
    }

    public func severity(for value: Double) -> Severity {
        if let critical, value >= critical { return .critical }
        if let elevated, value >= elevated { return .elevated }
        return .nominal
    }
}

/// Everything a renderer needs that is not the data itself.
///
/// Not `Sendable` on purpose -- it carries an `NSFont`, and all drawing happens
/// on the main actor. Making it sendable would invite background rendering,
/// which for ~20us of work per frame would cost more in hops than it saves.
public struct RenderContext {
    public var density: Density
    /// Backing scale of the screen the item is on. Read from the status item's
    /// window, never assumed to be 2.0 -- an external 1x display is still a
    /// thing, and rendering at the wrong scale is instantly visible.
    public var scale: CGFloat
    /// Drawing height. macOS gives status items 22pt regardless of menu bar
    /// thickness; the extra room on notched Macs is padding, not canvas.
    public var height: CGFloat
    public var font: NSFont
    /// Colour used when a cell is nominal *and* the strip cannot be a template
    /// image because some other cell in it is alerting.
    public var nominalColor: NSColor

    public init(
        density: Density = .regular,
        scale: CGFloat = 2.0,
        height: CGFloat = 22.0,
        font: NSFont? = nil,
        nominalColor: NSColor = .labelColor
    ) {
        self.density = density
        self.scale = scale
        self.height = height
        self.nominalColor = nominalColor
        // Monospaced *digits* only -- not a monospaced font. Proportional
        // letterforms keep labels readable and compact; fixed-width digits keep
        // the numbers from shifting. See ValueFormatter for the other half of
        // this.
        self.font = font ?? NSFont.monospacedDigitSystemFont(
            ofSize: density.fontSize,
            weight: .regular
        )
    }
}
