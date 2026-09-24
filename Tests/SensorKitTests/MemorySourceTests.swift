import Testing
@testable import SensorKit

@Suite("Memory source")
struct MemorySourceTests {

    private func sample() -> [MetricID: Double] {
        let source = MemorySource()
        source.activate()
        var sink = SampleSink()
        source.sample(into: &sink, context: SampleContext(elapsed: 1.0))
        return Dictionary(uniqueKeysWithValues: sink.readings.map { ($0.id, $0.value) })
    }

    @Test("reports immediately, with no baseline needed")
    func noPriming() throws {
        // Unlike the tick-counter sources, these are instantaneous levels. A
        // first sample that reported nothing would leave the menu bar blank for
        // a second on every launch for no reason.
        let values = sample()
        #expect(values[MemorySource.usagePercent] != nil)
    }

    @Test("used memory is the sum of its parts")
    func decompositionIsConsistent() throws {
        let values = sample()
        let used = try #require(values[MemorySource.used])
        let app = try #require(values[MemorySource.app])
        let wired = try #require(values[MemorySource.wired])
        let compressed = try #require(values[MemorySource.compressed])

        #expect(abs(used - (app + wired + compressed)) < 1)
    }

    @Test("usage percent is consistent with the byte figures")
    func percentMatchesBytes() throws {
        let values = sample()
        let percent = try #require(values[MemorySource.usagePercent])
        let used = try #require(values[MemorySource.used])

        #expect(percent > 0 && percent <= 100)

        // The descriptor's upper bound is installed RAM, so it can be recovered
        // and cross-checked against the percentage independently.
        let descriptor = try #require(
            MemorySource().descriptors.first { $0.id == MemorySource.used }
        )
        guard case .bounded(_, let total) = descriptor.range else {
            Issue.record("used memory should be bounded by installed RAM")
            return
        }
        #expect(abs(percent - used / total * 100) < 0.01)
    }

    @Test("pressure is one of the three normalised levels")
    func pressureIsNormalised() throws {
        let pressure = try #require(sample()[MemorySource.pressure])
        // Never the kernel's raw 1/2/4 bitmask -- a user threshold of "1" has to
        // mean "warning or worse".
        #expect([0.0, 1.0, 2.0].contains(pressure))
    }

    @Test("every emitted metric is declared")
    func descriptorsCoverEmissions() {
        let declared = Set(MemorySource().descriptors.map(\.id))
        for id in sample().keys {
            #expect(declared.contains(id), "undeclared metric \(id)")
        }
    }
}

@Suite("CPU core source")
struct CPUCoreSourceTests {

    @Test("clusters are contiguous, ordered, and cover every core")
    func clusterTopology() throws {
        let source = CPUCoreSource()
        let clusters = source.clusters
        guard !clusters.isEmpty else { return }  // single-perf-level Mac

        // Contiguity matters because the whole cluster mapping is derived from
        // consecutive index ranges rather than from a per-core query.
        var expectedStart = 0
        for cluster in clusters {
            #expect(cluster.indices.lowerBound == expectedStart)
            #expect(!cluster.indices.isEmpty)
            expectedStart = cluster.indices.upperBound
        }

        let cores = source.descriptors.filter { $0.group == "CPU Cores" }.count
        #expect(expectedStart == cores, "clusters must account for every core")
    }

    @Test("efficiency cores come first in processor index order")
    func efficiencyFirst() throws {
        let clusters = CPUCoreSource().clusters
        guard clusters.count > 1 else { return }

        // host_processor_info reports least-performant first, which is the
        // reverse of hw.perflevelN numbering. Verified empirically on an M4:
        // background work landed on indices 0-3, user-interactive on 6-9.
        // If a future macOS flips this, the P and E labels silently swap -- so
        // it is worth failing loudly here.
        #expect(clusters.first?.name == "Efficiency")
        #expect(clusters.last?.name == "Performance")
    }

    @Test("reports a usage figure per core, all within range")
    func perCoreValues() async throws {
        let source = CPUCoreSource()
        source.activate()
        defer { source.deactivate() }

        var sink = SampleSink()
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            sink.reset()
            source.sample(into: &sink, context: SampleContext(elapsed: 0.1))
            if !sink.readings.isEmpty { break }
        }

        #expect(!sink.readings.isEmpty, "should have produced per-core readings")
        for reading in sink.readings {
            #expect(reading.value >= 0 && reading.value <= 100,
                    "\(reading.id) out of range at \(reading.value)")
        }
    }
}
