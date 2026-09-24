import AppKit
import Foundation
import SensorKit
import Testing
@testable import RenderKit

@Suite("Clock formatting")
struct ClockFormatTests {
    /// 2026-08-25 13:13:15 UTC, a Tuesday.
    private let moment = Date(timeIntervalSince1970: 1_787_663_595)

    @Test("both dialects describe the same instant")
    func dialectsAgree() {
        let pattern = ClockFormat(format: "yyyy-MM-dd HH:mm:ss", syntax: .pattern, timeZone: "UTC")
        let strftime = ClockFormat(format: "%Y-%m-%d %H:%M:%S", syntax: .strftime, timeZone: "UTC")

        #expect(pattern.string(at: moment) == "2026-08-25 13:13:15")
        // Someone arriving from a Linux status bar should be able to paste their
        // format in and get the same answer.
        #expect(strftime.string(at: moment) == pattern.string(at: moment))
    }

    @Test("an explicit time zone shifts the reading")
    func timeZonesApply() {
        let tokyo = ClockFormat(format: "HH:mm", syntax: .pattern, timeZone: "Asia/Tokyo")
        let utc = ClockFormat(format: "HH:mm", syntax: .pattern, timeZone: "UTC")

        #expect(utc.string(at: moment) == "13:13")
        #expect(tokyo.string(at: moment) == "22:13")
    }

    @Test("the zone offset follows the requested zone, not the machine's")
    func zoneOffsetIsSubstituted() {
        // Darwin's strftime ignores `tm_gmtoff`: asked for Tokyo it printed the
        // *process* zone for %z and "UTC" for %Z. Both specifiers are resolved
        // before the string reaches strftime, and this is what proves it.
        let tokyo = ClockFormat(format: "%z", syntax: .strftime, timeZone: "Asia/Tokyo")
        #expect(tokyo.string(at: moment) == "+0900")

        let newYork = ClockFormat(format: "%z", syntax: .strftime, timeZone: "America/New_York")
        #expect(newYork.string(at: moment) == "-0400")

        let utc = ClockFormat(format: "%z", syntax: .strftime, timeZone: "UTC")
        #expect(utc.string(at: moment) == "+0000")
    }

    @Test("an escaped percent is not mistaken for a specifier")
    func escapedPercentSurvives() {
        let zone = TimeZone(identifier: "Asia/Tokyo")!
        let substituted = ClockFormatting.substituteZoneSpecifiers(
            in: "%%z %z %%Z", zone: zone, date: moment, offset: 32400
        )
        // The literal `%%z` must pass through untouched while the real `%z` is
        // replaced.
        #expect(substituted == "%%z +0900 %%Z")
    }

    @Test("a newline stacks the clock into two rows")
    func newlineStacks() {
        let format = ClockFormat(format: "EEE d MMM\nHH:mm", syntax: .pattern, timeZone: "UTC")
        let lines = ClockFormatting.shared.lines(at: moment.timeIntervalSince1970, format: format)

        #expect(lines.count == 2)
        #expect(lines[0] == "Tue 25 Aug")
        #expect(lines[1] == "13:13")
    }
}

@Suite("Clock width")
struct ClockWidthTests {
    private let context = RenderContext()

    private func input(_ timestamp: Double) -> CellInput {
        CellInput(value: timestamp, unit: .timestamp, range: .unbounded(min: 0))
    }

    @Test("width never changes as time passes")
    func widthIsStable() {
        // "9:05" and "12:58" are different widths, and "Wednesday" is much wider
        // than "May". A clock that resized as the minutes ticked would shove the
        // whole menu bar sideways all day.
        for format in [
            ClockFormat(format: "h:mm a", syntax: .pattern),
            ClockFormat(format: "EEEE d MMMM", syntax: .pattern),
            ClockFormat(format: "%a %d %b %H:%M", syntax: .strftime),
        ] {
            let renderer = ClockRenderer(format: format)
            let base = Date(timeIntervalSince1970: 1_704_067_200)  // 2024-01-01

            var widths = Set<CGFloat>()
            // Every hour across a full year, which covers every weekday name in
            // every month and both halves of the twelve-hour clock.
            for step in stride(from: 0, to: 366 * 24, by: 7) {
                let moment = base.addingTimeInterval(Double(step) * 3600)
                widths.insert(renderer.width(for: input(moment.timeIntervalSince1970), in: context))
            }
            #expect(widths.count == 1, "\(format.format) varied: \(widths.sorted())")
        }
    }

    @Test("the reservation actually fits the longest rendering")
    func reservationFitsEveryValue() {
        let format = ClockFormat(format: "EEEE d MMMM HH:mm", syntax: .pattern)
        let renderer = ClockRenderer(format: format)
        let widest = ClockFormatting.shared.widestCandidates(for: format).flatMap { $0 }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)

        func measure(_ text: String) -> CGFloat {
            NSAttributedString(string: text, attributes: [.font: font]).size().width
        }

        let reserved = widest.map(measure).max() ?? 0
        let base = Date(timeIntervalSince1970: 1_704_067_200)
        for step in stride(from: 0, to: 366 * 24, by: 11) {
            let moment = base.addingTimeInterval(Double(step) * 3600)
            let rendered = format.string(at: moment)
            #expect(measure(rendered) <= reserved + 0.5, "\(rendered) overflows")
        }
        #expect(renderer.width(for: input(base.timeIntervalSince1970), in: context) > reserved)
    }

    @Test("a clock only redraws when its text changes")
    func redrawsOnlyWhenVisiblyDifferent() {
        // Sampled every second, but a format showing hours and minutes should
        // rasterise once a minute.
        let renderer = ClockRenderer(format: ClockFormat(format: "HH:mm", syntax: .pattern))
        let base = 1_787_663_595.0

        #expect(renderer.changeKey(for: input(base), in: context)
                == renderer.changeKey(for: input(base + 30), in: context))
        #expect(renderer.changeKey(for: input(base), in: context)
                != renderer.changeKey(for: input(base + 90), in: context))
    }

    @Test("no reading renders as the shared placeholder")
    func missingValue() {
        let renderer = ClockRenderer()
        var empty = input(0)
        empty.value = nil
        #expect(renderer.changeKey(for: empty, in: context).contains(ValueFormatter.placeholder))
    }
}
