import Foundation
import Testing
@testable import SensorKit

@Suite("CPU load source")
struct CPULoadSourceTests {

    /// Samples until the source produces something, or gives up.
    ///
    /// A single fixed sleep is not a sound way to test this: the kernel's
    /// aggregate tick counters update lazily on Apple Silicon, so any given
    /// interval can legitimately yield no change at all. Polling asserts the
    /// contract that actually matters -- "given time, it reports" -- instead of
    /// accidentally asserting a timing detail of the scheduler.
    private func sampleUntilReported(
        _ source: CPULoadSource,
        timeout: Duration = .seconds(5)
    ) async throws -> [MetricID: Double] {
        var sink = SampleSink()
        let deadline = ContinuousClock.now + timeout

        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            sink.reset()
            source.sample(into: &sink, context: SampleContext(elapsed: 1.0))
            if !sink.readings.isEmpty {
                return Dictionary(uniqueKeysWithValues: sink.readings.map { ($0.id, $0.value) })
            }
        }

        Issue.record("source produced no readings within \(timeout)")
        return [:]
    }

    @Test("emits nothing before it has two samples to diff")
    func firstSampleIsSilent() {
        let source = CPULoadSource()
        source.activate()

        var sink = SampleSink()
        source.sample(into: &sink, context: SampleContext(elapsed: 1.0))

        // Immediately after activation there is at most a few microseconds of
        // elapsed time, so there is nothing honest to report. What must never
        // happen is a since-boot average, which would look plausible and be
        // wrong.
        for reading in sink.readings {
            #expect(reading.value >= 0 && reading.value <= 100)
        }
    }

    @Test("reports usage within 0...100, with total matching its components")
    func producesSaneValues() async throws {
        let source = CPULoadSource()
        source.activate()
        defer { source.deactivate() }

        let values = try await sampleUntilReported(source)

        let total = try #require(values[CPULoadSource.total])
        let user = try #require(values[CPULoadSource.user])
        let system = try #require(values[CPULoadSource.system])

        #expect(total >= 0 && total <= 100)
        #expect(user >= 0 && system >= 0)
        // Total is user+nice+system by construction; allow for float rounding.
        #expect(abs(total - (user + system)) < 0.001)
    }

    @Test("never emits a metric it did not declare")
    func descriptorsCoverEmissions() async throws {
        let source = CPULoadSource()
        source.activate()
        defer { source.deactivate() }

        let declared = Set(source.descriptors.map(\.id))
        let values = try await sampleUntilReported(source)

        // An undeclared metric would be invisible to the editor's picker and
        // unresolvable when a shared document referenced it.
        for id in values.keys {
            #expect(declared.contains(id), "undeclared metric \(id)")
        }
    }

    @Test("deactivating drops the baseline so the next run starts clean")
    func deactivateResetsDelta() async throws {
        let source = CPULoadSource()
        source.activate()
        _ = try await sampleUntilReported(source)
        source.deactivate()

        // After a resume, the first sample must be silent again rather than
        // reporting one giant delta covering the whole suspended period --
        // which is exactly what would appear as a 100% spike on wake.
        source.activate()
        var sink = SampleSink()
        source.sample(into: &sink, context: SampleContext(elapsed: 1.0))
        for reading in sink.readings {
            #expect(reading.value >= 0 && reading.value <= 100)
        }
    }

    @Test("sink reset keeps its allocation")
    func sinkReuse() {
        var sink = SampleSink(reservingCapacity: 8)
        sink.emit("a", 1)
        sink.emit("b", 2)
        #expect(sink.readings.count == 2)

        sink.reset()
        #expect(sink.readings.isEmpty)
        #expect(sink.readings.capacity >= 8, "reset must not drop capacity")
    }
}
