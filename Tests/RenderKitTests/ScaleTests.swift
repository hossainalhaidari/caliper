import Foundation
import SensorKit
import Testing
@testable import RenderKit

@Suite("Graph scaling")
struct ValueScaleTests {

    @Test("rounds up to readable steps")
    func niceCeilings() {
        // 1 / 2 / 5 x a power of the radix -- the steps people read axes in.
        #expect(ValueScale.niceCeiling(0.7) == 1)
        #expect(ValueScale.niceCeiling(1) == 1)
        #expect(ValueScale.niceCeiling(1.3) == 2)
        #expect(ValueScale.niceCeiling(4.9) == 5)
        #expect(ValueScale.niceCeiling(6) == 10)
        #expect(ValueScale.niceCeiling(37) == 50)
        #expect(ValueScale.niceCeiling(4_000_000) == 5_000_000)
        // Degenerate input must not produce a zero span and a divide by zero.
        #expect(ValueScale.niceCeiling(0) == 1)
        #expect(ValueScale.niceCeiling(.nan) == 1)
    }

    @Test("byte ceilings land on values that display cleanly")
    func binaryCeilings() {
        let mb = 1_048_576.0
        // The point of the binary radix: every ceiling here is a round number
        // of MB, so the top of the graph reads as "2 MB/s" and not "1.9 MB/s".
        #expect(ValueScale.niceCeiling(mb, base: 1024) == mb)
        #expect(ValueScale.niceCeiling(1.4 * mb, base: 1024) == 2 * mb)
        #expect(ValueScale.niceCeiling(4.2 * mb, base: 1024) == 5 * mb)
        #expect(ValueScale.niceCeiling(6.5 * mb, base: 1024) == 10 * mb)

        let formatter = ValueFormatter(decimals: 1)
        for multiple in [1.0, 2.0, 5.0] {
            let text = formatter.string(for: multiple * mb, unit: .bytesPerSecond)
            #expect(text.hasSuffix(" MB/s"))
            #expect(text.hasPrefix("\(Int(multiple))"), "ceiling displays as \(text)")
        }
    }

    @Test("quiet data stays near the floor")
    func floorKeepsIdleQuiet() {
        let scale = ValueScale.adaptive(floor: 1_048_576, base: 1024)
        // Background chatter of a few KB/s: without a floor this would fill the
        // graph and read as heavy traffic.
        let window = [Float](repeating: 7_000, count: 60)
        let resolved = scale.resolve(for: window)

        #expect(resolved.max == 1_048_576)
        #expect(GraphGeometry.fraction(7_000, in: resolved) < 0.01)
    }

    @Test("ceiling rises to contain real peaks")
    func adaptsToPeaks() {
        let scale = ValueScale.adaptive(floor: 1_048_576, base: 1024)
        var window = [Float](repeating: 7_000, count: 60)
        window[30] = 6_800_000

        let resolved = scale.resolve(for: window)
        #expect(resolved.max >= 6_800_000)
        // Quantised in MB, so it is a round number of megabytes per second.
        #expect(resolved.max.truncatingRemainder(dividingBy: 1_048_576) == 0)
        #expect(GraphGeometry.fraction(6_800_000, in: resolved) <= 1.0)
    }

    @Test("ceiling holds steady across small changes")
    func quantisationPreventsBreathing() {
        let scale = ValueScale.adaptive(floor: 1, base: 1000)
        // Three windows whose peaks differ by a few percent. A ceiling tracking
        // the peak exactly would rescale on each, and the graph would appear to
        // wobble for no reason the viewer can see.
        let peaks: [Float] = [41, 43, 46]
        let ceilings = peaks.map { peak -> Double in
            var window = [Float](repeating: 10, count: 30)
            window[10] = peak
            return scale.resolve(for: window).max
        }
        #expect(Set(ceilings).count == 1, "ceiling moved: \(ceilings)")
    }

    @Test("gaps in history are not treated as zero")
    func ignoresNaN() {
        let scale = ValueScale.adaptive(floor: 1, base: 1000)
        var window = [Float](repeating: .nan, count: 10)
        window[5] = 30
        #expect(scale.resolve(for: window).max == 50)
    }

    @Test("bounded ranges pass straight through")
    func boundedIsExact() {
        let resolved = ValueScale.bounded(min: 0, max: 100).resolve(for: [Float](repeating: 5, count: 10))
        #expect(resolved == (0, 100))

        // A percentage must never auto-scale: 5% has to look like 5%, not like
        // a full bar because nothing higher happened to be in the window.
        #expect(GraphGeometry.fraction(5, in: resolved) == 0.05)
    }

    @Test("fraction clamps rather than overflowing the plot")
    func fractionClamps() {
        let scale = (min: 0.0, max: 100.0)
        #expect(GraphGeometry.fraction(-20, in: scale) == 0)
        #expect(GraphGeometry.fraction(150, in: scale) == 1)
        #expect(GraphGeometry.fraction(.nan, in: scale) == 0)
    }
}

@Suite("Graph redraw detection")
struct GraphChangeKeyTests {
    private let scale = (min: 0.0, max: 100.0)

    @Test("sub-pixel changes do not force a redraw")
    func ignoresInvisibleChange() {
        let base = (0..<60).map { Float($0 % 40) }
        var nudged = base
        // Far below one pixel of a 28px plot.
        nudged[10] += 0.001

        #expect(
            GraphGeometry.changeKey(for: base, scale: scale, pixelHeight: 28)
                == GraphGeometry.changeKey(for: nudged, scale: scale, pixelHeight: 28)
        )
    }

    @Test("a visible change does force a redraw")
    func detectsVisibleChange() {
        let base = (0..<60).map { Float($0 % 40) }
        var changed = base
        changed[10] += 25

        #expect(
            GraphGeometry.changeKey(for: base, scale: scale, pixelHeight: 28)
                != GraphGeometry.changeKey(for: changed, scale: scale, pixelHeight: 28)
        )
    }

    @Test("a value scrolling out of the window is detected")
    func detectsScrollOut() {
        // The case a naive "compare the latest value" check gets wrong: the
        // newest sample is unchanged, but a spike left the far end and the plot
        // genuinely looks different.
        var before = [Float](repeating: 5, count: 60)
        before[0] = 90
        var after = [Float](repeating: 5, count: 60)
        after[59] = 5

        #expect(
            GraphGeometry.changeKey(for: before, scale: scale, pixelHeight: 28)
                != GraphGeometry.changeKey(for: after, scale: scale, pixelHeight: 28)
        )
    }

    @Test("a flat graph is never redrawn")
    func flatIsStable() {
        let flat = [Float](repeating: 0, count: 60)
        #expect(
            GraphGeometry.changeKey(for: flat, scale: scale, pixelHeight: 28)
                == GraphGeometry.changeKey(for: flat, scale: scale, pixelHeight: 28)
        )
    }

    @Test("a gap is distinguishable from zero")
    func gapIsNotZero() {
        var withGap = [Float](repeating: 5, count: 10)
        withGap[3] = .nan
        var withZero = [Float](repeating: 5, count: 10)
        withZero[3] = 0

        #expect(
            GraphGeometry.changeKey(for: withGap, scale: scale, pixelHeight: 28)
                != GraphGeometry.changeKey(for: withZero, scale: scale, pixelHeight: 28)
        )
    }
}
