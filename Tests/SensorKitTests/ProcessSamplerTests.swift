import Darwin
import Foundation
import Testing
@testable import SensorKit

@Suite("Process sampling")
struct ProcessSamplerTests {

    @Test("CPU time is read in mach units, not nanoseconds")
    func machUnitsNotNanoseconds() {
        // The bug this pins cost every CPU figure in this project a factor of
        // 41.67. `ri_user_time` sounds like nanoseconds and is mach absolute
        // time; dividing by a billion makes a process pegging one core read
        // 2.4% instead of 100%, which is plausible enough to go unnoticed.
        let pid = getpid()
        guard let before = ProcessSampler.usage(of: pid)?.cpuSeconds else {
            Issue.record("could not read own usage")
            return
        }

        // Spin one thread for a known stretch.
        let start = Date()
        var sink = 0.0
        while Date().timeIntervalSince(start) < 0.4 { sink += 1 }
        _ = sink
        let elapsed = Date().timeIntervalSince(start)

        guard let after = ProcessSampler.usage(of: pid)?.cpuSeconds else { return }
        let cores = (after - before) / elapsed

        // One busy thread is about one core. Read as nanoseconds this comes out
        // near 0.024, so the threshold catches the mistake with room to spare.
        #expect(cores > 0.5, "measured \(cores) cores; units are probably wrong")
        #expect(cores < 4, "measured \(cores) cores, which is more than the loop can use")
    }

    @Test("mach conversion matches the system timebase")
    func conversionMatchesTimebase() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let expected = 1_000_000_000 * Double(info.denom) / Double(info.numer)

        // One second's worth of mach units should convert back to one second.
        #expect(abs(MachTime.seconds(UInt64(expected)) - 1.0) < 0.001)
        #expect(MachTime.seconds(0) == 0)
    }

    @Test("the first sweep reports no CPU rather than a fabricated ranking")
    func firstSweepHasNoBaseline() {
        // With no interval to divide by, every process reads 0% and the order is
        // arbitrary -- the first attempt listed `disclaimer`, `sleep` and `tail`,
        // none of which were doing anything.
        let sampler = ProcessSampler()
        #expect(!sampler.hasBaseline)
        #expect(sampler.top(5, by: .cpu).isEmpty)

        // Memory is an instantaneous reading and needs no baseline.
        #expect(!sampler.top(5, by: .memory).isEmpty)
    }

    @Test("a second sweep produces a usable ranking")
    func secondSweepRanks() async throws {
        let sampler = ProcessSampler()
        let start = Date()
        _ = sampler.refresh(now: start)
        // Past the minimum interval, so the sweep is not served from cache.
        let later = start.addingTimeInterval(ProcessSampler.minimumInterval + 0.5)
        try await Task.sleep(for: .milliseconds(300))

        let top = sampler.top(5, by: .cpu, now: later)
        #expect(sampler.hasBaseline)
        #expect(top.count <= 5)
        for usage in top {
            #expect(usage.cpuPercent >= 0)
            #expect(usage.cpuPercent.isFinite)
            #expect(!usage.name.isEmpty)
        }
    }

    @Test("sweeps are throttled so an open panel does not re-scan every tick")
    func throttled() {
        // A full sweep is ~2.7ms across 650 processes; running it on every
        // redraw would put that on the main actor several times a second.
        let sampler = ProcessSampler()
        let now = Date()
        let first = sampler.refresh(now: now)
        let immediate = sampler.refresh(now: now.addingTimeInterval(0.1))
        #expect(first.count == immediate.count)
    }

    @Test("ranking by memory finds real processes")
    func memoryRanking() {
        let top = ProcessSampler().top(5, by: .memory)
        #expect(!top.isEmpty)
        #expect(top.allSatisfy { $0.memoryBytes > 0 })
        // Sorted, descending.
        #expect(top == top.sorted { $0.memoryBytes > $1.memoryBytes })
    }
}
