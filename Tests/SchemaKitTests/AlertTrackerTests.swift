import Foundation
import RenderKit
import SensorKit
import Testing
@testable import SchemaKit

@Suite("Alert hysteresis")
struct AlertTrackerTests {
    private let thresholds = Thresholds(elevated: 70, critical: 90)
    private let metric: MetricID = "cpu.usage.total"

    /// Feeds a series of readings one second apart and collects what was reported.
    private func run(
        _ values: [Double],
        tracker: AlertTracker = AlertTracker(minimumDuration: 30, recoveryMargin: 0.1),
        interval: TimeInterval = 1
    ) -> [AlertTracker.Event] {
        var state = AlertTracker.State()
        var now = Date(timeIntervalSince1970: 0)
        var events: [AlertTracker.Event] = []

        for value in values {
            if let event = tracker.update(
                &state, metric: metric, value: value, thresholds: thresholds, now: now
            ) {
                events.append(event)
            }
            now.addTimeInterval(interval)
        }
        return events
    }

    @Test("a brief spike says nothing")
    func ignoresSpikes() {
        // Ten seconds at 85%, then back to idle. This is a build starting, not a
        // condition, and an app that notifies here gets muted within a day.
        let events = run([Double](repeating: 5, count: 20)
                         + [Double](repeating: 85, count: 10)
                         + [Double](repeating: 5, count: 20))
        #expect(events.isEmpty)
    }

    @Test("a sustained breach is reported once")
    func reportsSustained() {
        let events = run([Double](repeating: 85, count: 120))
        #expect(events.count == 1)
        #expect(events.first?.kind == .raised(.elevated))
    }

    @Test("nothing is reported before the minimum duration elapses")
    func waitsForDuration() {
        // 29 seconds is not enough; the report lands on the 31st sample.
        #expect(run([Double](repeating: 85, count: 29)).isEmpty)
        #expect(run([Double](repeating: 85, count: 31)).count == 1)
    }

    @Test("a value hovering on the threshold does not flap")
    func hysteresisPreventsFlapping() {
        // Alternating either side of 70 is the case that makes a naive
        // implementation emit an endless alert/recover chatter.
        var values = [Double](repeating: 85, count: 40)   // establish elevated
        for index in 0..<200 { values.append(index.isMultiple(of: 2) ? 69.5 : 70.5) }

        let events = run(values)
        #expect(events.count == 1, "expected only the initial alert, got \(events.map(\.kind))")
        #expect(events.first?.kind == .raised(.elevated))
    }

    @Test("recovery needs a real drop, not just dipping under")
    func recoveryRequiresMargin() {
        // 65 is below the threshold but inside the 10% margin, so it is not
        // recovery. 55 is clear of it.
        let hovering = run([Double](repeating: 85, count: 40) + [Double](repeating: 65, count: 60))
        #expect(hovering.count == 1)

        let recovered = run([Double](repeating: 85, count: 40) + [Double](repeating: 55, count: 60))
        #expect(recovered.count == 2)
        #expect(recovered.last?.kind == .recovered)
    }

    @Test("escalation from elevated to critical is reported")
    func escalates() {
        let events = run([Double](repeating: 85, count: 40) + [Double](repeating: 95, count: 40))
        #expect(events.map(\.kind) == [.raised(.elevated), .raised(.critical)])
    }

    @Test("oscillating between severities matures into neither")
    func alternatingSeveritiesDoNotAccumulate() {
        // Each change of candidate restarts the clock, so a value bouncing
        // between elevated and critical never accrues thirty seconds of either.
        var values = [Double](repeating: 5, count: 5)
        for index in 0..<200 { values.append(index.isMultiple(of: 2) ? 85 : 95) }

        let events = run(values)
        #expect(events.isEmpty, "got \(events.map(\.kind))")
    }

    @Test("a cell with no thresholds is silent whatever it reads")
    func noThresholdsNeverAlerts() {
        let tracker = AlertTracker()
        var state = AlertTracker.State()
        var now = Date(timeIntervalSince1970: 0)

        for _ in 0..<200 {
            let event = tracker.update(&state, metric: metric, value: 100, thresholds: .none, now: now)
            #expect(event == nil)
            now.addTimeInterval(1)
        }
    }

    @Test("messages read like sentences, not like log lines")
    func messagesAreReadable() {
        let raised = AlertTracker.Event(metric: metric, kind: .raised(.critical), value: 94.2)
        #expect(raised.message(displayName: "CPU Usage", unit: .percent) == "CPU Usage is at 94%.")
        #expect(raised.title == "Critical")

        let recovered = AlertTracker.Event(metric: metric, kind: .recovered, value: 12.0)
        #expect(recovered.message(displayName: "CPU Usage", unit: .percent).contains("back to normal"))
    }
}
