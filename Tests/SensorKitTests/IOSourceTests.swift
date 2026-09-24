import Foundation
import Testing
@testable import SensorKit

@Suite("Network source")
struct NetworkSourceTests {

    @Test("stays silent without a measured interval")
    func needsAnInterval() {
        let source = NetworkSource()
        source.activate()
        defer { source.deactivate() }

        var sink = SampleSink()
        // elapsed == 0 is what the bus reports for the first sample after
        // activation. Dividing a byte delta by it would be infinity; guessing
        // 1.0 would invent a rate. Silence is the only correct answer.
        source.sample(into: &sink, context: SampleContext(elapsed: 0))
        #expect(sink.readings.isEmpty)
    }

    @Test("reports non-negative rates for the primary interface")
    func reportsRates() async throws {
        let source = NetworkSource()
        source.activate()
        defer { source.deactivate() }

        var sink = SampleSink()
        source.sample(into: &sink, context: SampleContext(elapsed: 0))
        try await Task.sleep(for: .milliseconds(300))
        sink.reset()
        source.sample(into: &sink, context: SampleContext(elapsed: 0.3))

        for reading in sink.readings {
            #expect(reading.value >= 0, "\(reading.id) was negative")
            #expect(reading.value.isFinite, "\(reading.id) was not finite")
        }
    }

    @Test("session totals accumulate rather than resetting")
    func sessionTotalsAccumulate() async throws {
        let source = NetworkSource()
        source.activate()
        defer { source.deactivate() }

        var sink = SampleSink()
        var previousTotal: Double?

        for _ in 0..<3 {
            source.sample(into: &sink, context: SampleContext(elapsed: 0.2))
            try await Task.sleep(for: .milliseconds(200))
            sink.reset()
            source.sample(into: &sink, context: SampleContext(elapsed: 0.2))

            guard let total = sink.readings.first(where: { $0.id == NetworkSource.sessionReceived })?.value
            else { continue }
            if let previous = previousTotal {
                // Monotonic: these are accumulated in 64 bits from wrap-safe
                // deltas, precisely so they cannot go backwards when the
                // kernel's 32-bit counter rolls over.
                #expect(total >= previous)
            }
            previousTotal = total
            sink.reset()
        }
    }
}

@Suite("Disk sources")
struct DiskSourceTests {

    @Test("finds exactly one boot volume")
    func bootVolume() {
        let volumes = DiskCapacitySource.scan()
        #expect(volumes.filter(\.isBoot).count == 1)
    }

    @Test("excludes system, read-only, and network volumes")
    func filtersNoise() {
        let volumes = DiskCapacitySource.scan()
        let names = volumes.map(\.name)

        // These are all mounted on a current Mac and all hidden from Finder.
        for hidden in ["VM", "Preboot", "Update", "xART", "iSCPreboot", "Hardware"] {
            #expect(!names.contains(hidden), "\(hidden) should be filtered out")
        }
        // Simulator runtimes mount read-only and would otherwise flood the list.
        #expect(!names.contains { $0.contains("Simulator") })
    }

    @Test("reports plausible capacity for the boot volume")
    func bootCapacity() throws {
        let source = DiskCapacitySource()
        var sink = SampleSink()
        source.sample(into: &sink, context: SampleContext(elapsed: 30))

        let values = Dictionary(uniqueKeysWithValues: sink.readings.map { ($0.id, $0.value) })
        let total = try #require(values[DiskCapacitySource.bootTotal])
        let free = try #require(values[DiskCapacitySource.bootFree])
        let percent = try #require(values[DiskCapacitySource.bootUsagePercent])

        #expect(total > 0)
        #expect(free >= 0 && free <= total)
        #expect(percent >= 0 && percent <= 100)
        #expect(abs(percent - (total - free) / total * 100) < 0.01)
    }

    @Test("volume names survive becoming metric ids")
    func slugStability() {
        // Volume names end up inside shared JSON documents, so two spellings of
        // the same name must not produce two different metric ids.
        #expect(DiskCapacitySource.slug("Time Machine") == "time-machine")
        #expect(DiskCapacitySource.slug("Time  Machine") == "time-machine")
        #expect(DiskCapacitySource.slug("Time-Machine") == "time-machine")
        #expect(DiskCapacitySource.slug("Macintosh HD") == "macintosh-hd")
        #expect(DiskCapacitySource.slug("Backup (2TB)") == "backup-2tb")
    }

    @Test("disk activity reports non-negative rates")
    func activityRates() async throws {
        let source = DiskActivitySource()
        source.activate()
        defer { source.deactivate() }

        var sink = SampleSink()
        source.sample(into: &sink, context: SampleContext(elapsed: 0))
        try await Task.sleep(for: .milliseconds(300))
        sink.reset()
        source.sample(into: &sink, context: SampleContext(elapsed: 0.3))

        #expect(!sink.readings.isEmpty, "should find at least one block device")
        for reading in sink.readings {
            #expect(reading.value >= 0 && reading.value.isFinite)
        }
    }
}
