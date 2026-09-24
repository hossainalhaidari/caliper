import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// Draws the app icon and writes a complete `.iconset`.
///
/// The mark is an arc gauge -- the same shape `ArcGaugeRenderer` draws in the
/// menu bar. An icon that shares a visual language with the product it launches
/// is worth more than a prettier one that does not, and this way the two cannot
/// drift apart.
///
/// It has to survive being 16 points wide, which rules out anything with text,
/// fine lines, or more than one idea in it. A thick open ring keeps a
/// recognisable silhouette at every size, which is the only test that matters.
enum IconForge {

    /// Apple's icon grid: the artwork occupies about 80% of the canvas, with the
    /// rest as breathing room the system relies on for alignment.
    private static let artworkInset: CGFloat = 0.098

    static func write(to directory: String) throws {
        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // The names `iconutil` expects.
        let entries: [(name: String, pixels: Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]

        for entry in entries {
            guard let image = render(pixels: entry.pixels) else { continue }
            try write(image, to: folder.appending(path: "\(entry.name).png"))
        }

        // A contact sheet for judging the thing at the sizes it will be seen.
        if let sheet = contactSheet(sizes: sizes) {
            try write(sheet, to: folder.deletingLastPathComponent().appending(path: "icon-preview.png"))
        }
    }

    // MARK: - Drawing

    static func render(pixels: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let size = CGFloat(pixels)
        context.interpolationQuality = .high
        draw(in: context, size: size)
        return context.makeImage()
    }

    private static func draw(in context: CGContext, size: CGFloat) {
        let inset = size * artworkInset
        let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)

        // Squircle, not a rounded rectangle. macOS icons use a continuous curve,
        // and a circular-cornered rect next to real app icons looks subtly wrong
        // in a way that is hard to place and easy to see.
        let shape = squircle(in: plate)

        context.saveGState()
        context.addPath(shape)
        context.clip()

        // A deep, calm ground. The product's whole stance is that it stays quiet
        // until something matters, and an icon shouting in saturated colour
        // would contradict that before the app had drawn a single pixel.
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: [
                CGColor(red: 0.204, green: 0.231, blue: 0.286, alpha: 1),
                CGColor(red: 0.078, green: 0.090, blue: 0.114, alpha: 1),
            ] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.midX, y: plate.maxY),
            end: CGPoint(x: plate.midX, y: plate.minY),
            options: []
        )
        context.restoreGState()

        // A hairline highlight along the top edge, the way physical instrument
        // bezels catch light. Skipped at small sizes where it becomes noise.
        if size >= 128 {
            context.saveGState()
            context.addPath(shape)
            context.clip()
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
            context.setLineWidth(size * 0.006)
            context.addPath(squircle(in: plate.insetBy(dx: size * 0.003, dy: size * 0.003)))
            context.strokePath()
            context.restoreGState()
        }

        drawGauge(in: context, plate: plate, size: size)
    }

    /// The same 270-degree dial the menu bar draws, at icon scale.
    private static func drawGauge(in context: CGContext, plate: CGRect, size: CGFloat) {
        let lineWidth = plate.width * 0.155
        let radius = plate.width * 0.29
        let centre = CGPoint(x: plate.midX, y: plate.midY - plate.height * 0.03)

        let start = CGFloat.pi * 1.25
        let sweep = CGFloat.pi * 1.5

        context.setLineCap(.round)
        context.setLineWidth(lineWidth)

        context.setStrokeColor(CGColor(gray: 1, alpha: 0.20))
        context.addArc(center: centre, radius: radius,
                       startAngle: start, endAngle: start - sweep, clockwise: true)
        context.strokePath()

        // Filled to roughly two thirds: enough to read as "a reading" rather
        // than as an empty ring or a full one.
        let filled = sweep * 0.66
        // The accent is the leading tip of the reading, not a needle laid across
        // it. A needle overshooting the ring muddied the one place the eye
        // lands, and a tip says the same thing while keeping the silhouette
        // clean -- which is the only thing that survives to 16 points.
        let tip = size >= 64 ? min(sweep * 0.09, filled) : 0

        context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        context.addArc(center: centre, radius: radius,
                       startAngle: start, endAngle: start - (filled - tip), clockwise: true)
        context.strokePath()

        guard tip > 0 else { return }
        context.setStrokeColor(CGColor(red: 1.0, green: 0.60, blue: 0.16, alpha: 1))
        context.addArc(center: centre, radius: radius,
                       startAngle: start - (filled - tip), endAngle: start - filled, clockwise: true)
        context.strokePath()
    }

    /// A superellipse, which is what Apple's icon shape actually is.
    private static func squircle(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
        let path = CGMutablePath()
        let a = rect.width / 2
        let b = rect.height / 2
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let steps = 720

        for step in 0...steps {
            let theta = CGFloat(step) / CGFloat(steps) * 2 * .pi
            let cosT = cos(theta)
            let sinT = sin(theta)
            // |x/a|^n + |y/b|^n = 1, parameterised so the corners stay smooth.
            let x = centre.x + a * copysign(pow(abs(cosT), 2 / exponent), cosT)
            let y = centre.y + b * copysign(pow(abs(sinT), 2 / exponent), sinT)
            step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Output

    private static func contactSheet(sizes: [Int]) -> CGImage? {
        let padding = 24
        let width = sizes.reduce(0) { $0 + max($1, 64) + padding } + padding
        let height = 1024 + padding * 2

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(gray: 0.62, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        var x = padding
        for pixels in sizes {
            guard let image = render(pixels: pixels) else { continue }
            context.draw(
                image,
                in: CGRect(x: x, y: padding, width: pixels, height: pixels)
            )
            x += max(pixels, 64) + padding
        }
        return context.makeImage()
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
