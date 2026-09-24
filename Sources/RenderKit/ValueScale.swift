import Foundation
import SensorKit

/// Decides what the top of a graph means.
///
/// Bounded metrics answer this for free -- 0 to 100 for a percentage. Unbounded
/// ones do not, and getting it wrong is what makes most network graphs useless:
/// scale continuously to the window's peak and a machine trickling 7 KB/s of
/// background chatter draws the same full-height storm as one saturating a
/// gigabit link. Absolute magnitude disappears entirely.
///
/// So `adaptive` does two things. A **floor** means quiet really looks quiet:
/// below a megabyte a second, the line stays near the bottom where it belongs.
/// And the ceiling is **quantised** to 1/2/5 x 10^n rather than tracking the peak
/// exactly, so it changes in occasional visible steps instead of breathing on
/// every tick.
///
/// Quantisation is also what lets this stay a pure function of the data. A
/// stateful decay would make a graph's appearance depend on the history of its
/// own ceilings, so the same widget fed the same numbers could render
/// differently on two Macs -- which is precisely what M4's shareable documents
/// must not do.
public enum ValueScale: Sendable, Equatable {
    /// Straight from the metric's declared range.
    case bounded(min: Double, max: Double)

    /// Derived from the data window, never below `floor`.
    ///
    /// `base` is the radix the ceiling is quantised in: 1024 for anything
    /// measured in bytes, 1000 for everything else. This is not pedantry. A
    /// decimally-rounded ceiling of 2,000,000 bytes per second *displays* as
    /// "1.9 MB/s", so the top of the graph is a number no one would ever choose
    /// -- the quantisation has to happen in the same units the label is written
    /// in, or it defeats its own purpose.
    case adaptive(floor: Double, base: Double)

    /// A ceiling the user pinned, for comparing across time or machines.
    case fixed(min: Double, max: Double)

    /// The default policy for a metric, given what its descriptor claims.
    public static func `default`(for range: MetricRange, unit: MetricUnit) -> ValueScale {
        switch range {
        case .bounded(let min, let max):
            .bounded(min: min, max: max)
        case .unbounded:
            .adaptive(floor: defaultFloor(for: unit), base: base(for: unit))
        }
    }

    /// Byte-denominated quantities step in 1024s, everything else in 1000s.
    public static func base(for unit: MetricUnit) -> Double {
        switch unit {
        case .bytes, .bytesPerSecond: 1024
        default: 1000
        }
    }

    /// Where "quiet" stops for each kind of quantity.
    ///
    /// A megabyte a second is the threshold at which network activity is
    /// something you did rather than something the OS is doing in the
    /// background, which is the distinction the graph exists to draw.
    public static func defaultFloor(for unit: MetricUnit) -> Double {
        switch unit {
        case .bytesPerSecond: 1_048_576
        case .bytes: 1_073_741_824
        case .watts: 10
        case .hertz: 1_000_000_000
        default: 1
        }
    }

    /// Resolves against a data window. NaN entries -- periods before sampling
    /// began -- are ignored rather than treated as zero.
    public func resolve(for window: [Float]) -> (min: Double, max: Double) {
        switch self {
        case .bounded(let min, let max), .fixed(let min, let max):
            return (min, max)

        case .adaptive(let floor, let base):
            var peak = 0.0
            for sample in window where sample.isFinite {
                peak = Swift.max(peak, Double(sample))
            }
            // The floor is a deliberate choice, so it is honoured exactly rather
            // than rounded: "quiet stops at 1 MB/s" should mean 1 MB/s.
            guard peak > floor else { return (0, floor) }
            return (0, Self.niceCeiling(peak, base: base))
        }
    }

    /// Rounds up to the next 1, 2, or 5 times a power of ten.
    ///
    /// These are the steps people read axes in. The practical effect is that a
    /// graph's ceiling changes rarely, and when it does it changes by a factor
    /// large enough to notice -- rather than drifting by 3% every second, which
    /// reads as the graph wobbling for no reason.
    static func niceCeiling(_ value: Double, base: Double = 1000) -> Double {
        guard value > 0, value.isFinite, base > 1 else { return 1 }

        // Two separate roundings, which is the part that is easy to get wrong.
        //
        // First reduce to a mantissa in [1, base) by whole powers of the radix.
        // That chooses the *unit* the ceiling will be labelled in -- MB rather
        // than KB -- and it is the step that must use 1024 for bytes.
        var magnitude = 1.0
        var mantissa = value
        while mantissa >= base {
            mantissa /= base
            magnitude *= base
        }

        // Then round the mantissa to a readable decimal step, because "5 MB/s"
        // is a number a person picks and "5.12 MB/s" is not. This step is always
        // decimal: nobody reads an axis in 1024ths of a megabyte.
        let stepped = decimalStep(mantissa)

        // A mantissa that rounds past the radix belongs in the next unit up.
        return stepped >= base ? base * magnitude : stepped * magnitude
    }

    /// Rounds up to 1, 2, or 5 times a power of ten.
    private static func decimalStep(_ value: Double) -> Double {
        let exponent = log10(value).rounded(.down)
        let magnitude = pow(10, exponent)
        let normalised = value / magnitude

        let step: Double = if normalised <= 1 {
            1
        } else if normalised <= 2 {
            2
        } else if normalised <= 5 {
            5
        } else {
            10
        }

        return step * magnitude
    }
}

/// Maps values into a drawing rect and reports what actually changed on screen.
enum GraphGeometry {

    /// Fraction of the way up the plot, clamped to 0...1.
    static func fraction(_ value: Double, in scale: (min: Double, max: Double)) -> Double {
        let span = scale.max - scale.min
        guard span > 0, value.isFinite else { return 0 }
        return Swift.min(1, Swift.max(0, (value - scale.min) / span))
    }

    /// A change key for a whole data window, quantised to pixels.
    ///
    /// Hashing the raw values would redraw on every tick forever, because a
    /// float almost never repeats. Hashing the *pixel row each value lands on*
    /// asks the only question that matters -- would this look different? -- so a
    /// flat idle graph costs a hash and nothing else, tick after tick.
    static func changeKey(
        for window: [Float],
        scale: (min: Double, max: Double),
        pixelHeight: Int
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(scale.max)
        hasher.combine(scale.min)
        hasher.combine(window.count)

        let rows = Swift.max(1, pixelHeight)
        for sample in window {
            guard sample.isFinite else {
                hasher.combine(Int.min)  // a gap is visually distinct from zero
                continue
            }
            hasher.combine(Int(fraction(Double(sample), in: scale) * Double(rows)))
        }

        return hasher.finalize()
    }
}
