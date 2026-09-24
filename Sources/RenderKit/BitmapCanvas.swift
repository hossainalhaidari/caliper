import AppKit
import CoreGraphics

/// A reusable off-screen bitmap.
///
/// Creating a `CGContext` allocates and zeroes a backing buffer. Doing that
/// once per second forever is pure waste, so the context is kept and only
/// rebuilt when the geometry actually changes -- which happens on a display
/// change or a density change, not on a tick.
public final class BitmapCanvas {
    private var cgContext: CGContext?
    private var pixelSize = CGSize.zero
    private var currentScale: CGFloat = 0

    public init() {}

    /// Draws into a cached context and returns the result.
    ///
    /// The closure receives a context already scaled to points, so callers work
    /// in points and never think about backing scale.
    public func makeImage(
        size: CGSize,
        scale: CGFloat,
        draw: (CGContext) -> Void
    ) -> CGImage? {
        let pixels = CGSize(
            width: (size.width * scale).rounded(.up),
            height: (size.height * scale).rounded(.up)
        )
        guard pixels.width >= 1, pixels.height >= 1 else { return nil }

        if cgContext == nil || pixels != pixelSize || scale != currentScale {
            guard let fresh = CGContext(
                data: nil,
                width: Int(pixels.width),
                height: Int(pixels.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,  // let CoreGraphics pick an aligned stride
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }

            cgContext = fresh
            pixelSize = pixels
            currentScale = scale
        }

        guard let cgContext else { return nil }

        cgContext.saveGState()
        defer { cgContext.restoreGState() }

        // Reset to a known state: the previous frame's pixels are still there.
        cgContext.clear(CGRect(origin: .zero, size: pixels))
        cgContext.scaleBy(x: scale, y: scale)
        // Text at menu bar sizes lives or dies on subpixel positioning being
        // left alone; no snapping, no integer rounding of glyph origins.
        cgContext.setShouldSmoothFonts(true)
        cgContext.setShouldAntialias(true)

        draw(cgContext)

        return cgContext.makeImage()
    }
}
