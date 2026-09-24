import Foundation
import RenderKit
import SensorKit

/// Decides when a threshold crossing is worth telling someone about.
///
/// The naive version -- notify whenever the value goes past the threshold -- is
/// unusable. CPU crosses 70% dozens of times an hour on an idle machine, so an
/// app built that way gets muted within a day and then never tells you anything
/// again, including the one time it mattered.
///
/// Two mechanisms fix that, and both are necessary:
///
/// **A minimum duration.** A value must stay past its threshold continuously
/// before anything is said. A spike while a build starts is not a condition; the
/// same value still there half a minute later is.
///
/// **Hysteresis on the way down.** Recovery is only declared once the value has
/// fallen meaningfully *below* the threshold, not merely back under it. Without
/// this, a metric hovering at exactly 70% produces an endless alternation of
/// alert and recovery, which is worse than either.
public struct AlertTracker: Sendable {

    /// How long a breach must persist before it is reported.
    public var minimumDuration: TimeInterval
    /// How far below the threshold a value must fall to count as recovered,
    /// as a fraction of the threshold itself.
    public var recoveryMargin: Double

    public init(minimumDuration: TimeInterval = 30, recoveryMargin: Double = 0.1) {
        self.minimumDuration = minimumDuration
        self.recoveryMargin = recoveryMargin
    }

    /// What the tracker believes about one metric.
    public struct State: Sendable, Equatable {
        public init() {}

        public var severity: Severity = .nominal
        /// When the current candidate severity was first seen. Nil once it has
        /// been reported.
        var pendingSince: Date?
        var pendingSeverity: Severity = .nominal
    }

    /// Something worth telling the user.
    public struct Event: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case raised(Severity)
            case recovered
        }

        public let metric: MetricID
        public let kind: Kind
        public let value: Double
    }

    /// Advances one metric's state. Returns an event only at the moment a
    /// change becomes reportable, never on every sample.
    public func update(
        _ state: inout State,
        metric: MetricID,
        value: Double,
        thresholds: Thresholds,
        now: Date
    ) -> Event? {
        guard value.isFinite else { return nil }

        let observed = severity(for: value, thresholds: thresholds, current: state.severity)

        // Nothing new: the observation agrees with what has already been
        // reported, so any pending change is abandoned rather than allowed to
        // mature.
        guard observed != state.severity else {
            state.pendingSince = nil
            state.pendingSeverity = state.severity
            return nil
        }

        // A different candidate than last time restarts the clock, so a value
        // oscillating between elevated and critical does not accumulate time
        // towards either.
        if state.pendingSeverity != observed {
            state.pendingSeverity = observed
            state.pendingSince = now
            return nil
        }

        guard let since = state.pendingSince,
              now.timeIntervalSince(since) >= minimumDuration else { return nil }

        state.severity = observed
        state.pendingSince = nil

        return Event(
            metric: metric,
            kind: observed == .nominal ? .recovered : .raised(observed),
            value: value
        )
    }

    /// Severity of a reading, with the recovery margin applied when descending.
    ///
    /// Asymmetric on purpose: going up uses the threshold, coming down uses the
    /// threshold minus the margin. A metric sitting exactly on its threshold
    /// therefore settles in whichever state it is already in, rather than
    /// flapping between them.
    func severity(for value: Double, thresholds: Thresholds, current: Severity) -> Severity {
        func exceeds(_ threshold: Double?, alreadyThere: Bool) -> Bool {
            guard let threshold else { return false }
            let effective = alreadyThere ? threshold * (1 - recoveryMargin) : threshold
            return value >= effective
        }

        if exceeds(thresholds.critical, alreadyThere: current == .critical) { return .critical }
        if exceeds(thresholds.elevated, alreadyThere: current != .nominal) { return .elevated }
        return .nominal
    }
}

public extension AlertTracker.Event {
    /// A sentence for a notification body.
    func message(displayName: String, unit: MetricUnit) -> String {
        let formatter = ValueFormatter(decimals: unit == .percent ? 0 : 1)
        let reading = formatter.string(for: value, unit: unit)

        return switch kind {
        case .raised(.critical), .raised(.nominal):
            String(
                localized: "\(displayName) is at \(reading).",
                comment: "Alert notification body: a metric crossed its critical threshold. A metric's name, then its reading")
        case .raised(.elevated):
            String(
                localized: "\(displayName) has been high for a while: \(reading).",
                comment: "Alert notification body: a metric stayed past its warning threshold. A metric's name, then its reading")
        case .recovered:
            String(
                localized: "\(displayName) is back to normal: \(reading).",
                comment: "Alert notification body: a metric came back under its threshold. A metric's name, then its reading")
        }
    }

    var title: String {
        switch kind {
        case .raised(.critical):
            String(localized: "Critical", comment: "Alert notification title: past the critical threshold")
        case .raised:
            String(localized: "Heads up", comment: "Alert notification title: past the warning threshold")
        case .recovered:
            String(localized: "Recovered", comment: "Alert notification title: back under the threshold")
        }
    }
}
