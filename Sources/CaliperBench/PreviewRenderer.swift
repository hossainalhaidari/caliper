import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// Renders the menu bar strip to a PNG.
///
/// The menu bar cannot be screenshotted without Screen Recording permission, and
/// asking for that just to look at your own work is absurd. This draws the exact
/// image the status item is handed, on both a light and a dark ground, so the
/// rendering can be inspected and iterated on directly.
///
/// It is also the honest way to review the design: the strip is a template image
/// that AppKit tints at display time, so seeing it in one appearance tells you
/// nothing about the other.
enum PreviewRenderer {

    /// Approximations of the menu bar's own backgrounds, which is what the
    /// template will actually be composited against.
    private static let lightGround = CGColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)
    private static let darkGround = CGColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1)
    private static let lightInk = CGColor(red: 0, green: 0, blue: 0, alpha: 0.85)
    private static let darkInk = CGColor(red: 1, green: 1, blue: 1, alpha: 0.92)

    /// Writes a two-row preview: the strip as it renders in dark appearance
    /// above, light below.
    ///
    /// Takes two separately composed images rather than tinting one, because a
    /// strip that is alerting is not a template -- it carries resolved colours,
    /// and those resolve differently per appearance. Compositing a single
    /// bitmap onto two backgrounds would hide exactly the bug this is for.
    static func write(dark darkImage: NSImage, light lightImage: NSImage, to path: String, scale: CGFloat = 4) throws {
        guard let darkStrip = darkImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let lightStrip = lightImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw PreviewError.noImage
        }

        let stripSize = darkImage.size
        let padding: CGFloat = 10
        let rowHeight = stripSize.height + padding * 2
        let width = stripSize.width + padding * 2
        let height = rowHeight * 2

        guard let context = CGContext(
            data: nil,
            width: Int(width * scale),
            height: Int(height * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PreviewError.noContext }

        context.scaleBy(x: scale, y: scale)
        context.interpolationQuality = .none

        // Bottom row is light, top row is dark, because CoreGraphics origin is
        // bottom-left and reading order in the finished file is top-down.
        draw(darkStrip, isTemplate: darkImage.isTemplate, in: context,
             ground: darkGround, ink: darkInk,
             row: CGRect(x: 0, y: rowHeight, width: width, height: rowHeight),
             padding: padding, stripSize: stripSize)

        draw(lightStrip, isTemplate: lightImage.isTemplate, in: context,
             ground: lightGround, ink: lightInk,
             row: CGRect(x: 0, y: 0, width: width, height: rowHeight),
             padding: padding, stripSize: stripSize)

        guard let output = context.makeImage() else { throw PreviewError.noImage }
        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ) else { throw PreviewError.noDestination }

        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination) else { throw PreviewError.writeFailed }
    }

    private static func draw(
        _ strip: CGImage,
        isTemplate: Bool,
        in context: CGContext,
        ground: CGColor,
        ink: CGColor,
        row: CGRect,
        padding: CGFloat,
        stripSize: CGSize
    ) {
        context.setFillColor(ground)
        context.fill(row)

        let target = CGRect(
            x: padding,
            y: row.minY + padding,
            width: stripSize.width,
            height: stripSize.height
        )

        guard isTemplate else {
            // Already carries its own colours, because a cell is alerting.
            context.draw(strip, in: target)
            return
        }

        // A template is drawn as a black silhouette with alpha; AppKit tints it
        // to suit the menu bar. Clipping to its alpha and filling reproduces
        // exactly that.
        context.saveGState()
        context.clip(to: target, mask: strip)
        context.setFillColor(ink)
        context.fill(target)
        context.restoreGState()
    }

    /// Draws one strip centred on a menu-bar-coloured swatch. Shared with the
    /// gallery so both tools composite identically.
    static func drawSwatch(_ image: NSImage, dark: Bool, context: CGContext, in rect: CGRect) {
        context.setFillColor(dark ? darkGround : lightGround)
        context.fill(rect)

        guard let strip = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let target = CGRect(
            x: rect.midX - image.size.width / 2,
            y: rect.midY - image.size.height / 2,
            width: image.size.width,
            height: image.size.height
        )

        guard image.isTemplate else {
            context.draw(strip, in: target)
            return
        }

        context.saveGState()
        context.clip(to: target, mask: strip)
        context.setFillColor(dark ? darkInk : lightInk)
        context.fill(target)
        context.restoreGState()
    }

    enum PreviewError: Error {
        case noImage, noContext, noDestination, writeFailed
    }
}
