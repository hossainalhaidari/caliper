import Darwin
import Foundation

/// Converts mach absolute time units to seconds.
///
/// `proc_pid_rusage` reports `ri_user_time` and `ri_system_time` in **mach
/// units**, not nanoseconds, despite the field names suggesting otherwise.
/// Dividing by a billion looks right and under-reports by the timebase ratio --
/// 41.67x on Apple Silicon, where numer/denom is 125/3.
///
/// It is silent, plausible and wrong: a process pegging one core reads 2.4%
/// instead of 100%. Verified by spinning a busy loop and checking the answer
/// came to exactly 100.0% of a core once converted.
public enum MachTime {
    private static let timebase: (numer: Double, denom: Double) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (Double(info.numer), Double(info.denom))
    }()

    public static func seconds(_ units: UInt64) -> Double {
        Double(units) * timebase.numer / timebase.denom / 1_000_000_000
    }
}

/// One process, as the panel shows it.
public struct ProcessUsage: Sendable, Equatable, Identifiable {
    public let pid: pid_t
    public let name: String
    /// Percent of one core, averaged over the interval since the last refresh.
    public let cpuPercent: Double
    public let memoryBytes: Double

    public var id: pid_t { pid }
}

/// Ranks running processes by CPU or memory.
///
/// Deliberately **not** a `MetricSource`. Everything on the bus is one number
/// per metric, and a process list is neither -- forcing it into that shape would
/// mean inventing metric ids for whatever happens to be running, which change
/// every time something launches.
///
/// It is also not on the bus because it should not run when nobody is looking.
/// A full sweep costs about 2.7ms across 650 processes, which is fine for a
/// panel that is open and indefensible once a second forever. The panel owns one
/// of these and refreshes it only while it is on screen.
public final class ProcessSampler: @unchecked Sendable {

    public enum Ranking: Sendable {
        case cpu
        case memory
    }

    /// CPU is a delta, so the sampler needs two readings and a real interval
    /// between them. Below this, the previous result is returned unchanged
    /// rather than dividing by a near-zero elapsed time.
    public static let minimumInterval: TimeInterval = 2

    private var previousCPU: [pid_t: Double] = [:]
    private var lastSweep: Date?
    private var cached: [ProcessUsage] = []

    /// Whether a CPU figure can be computed at all.
    ///
    /// CPU is a delta, so the first sweep has nothing to compare against and
    /// every process reads 0%. Ranking by that produces a list in arbitrary
    /// order -- on the first attempt it was `disclaimer`, `sleep` and `tail`,
    /// none of which were doing anything. Callers use this to say "measuring"
    /// rather than to show a confident list of noise.
    public private(set) var hasBaseline = false

    public init() {}

    /// Re-reads the process table, at most once per `minimumInterval`.
    @discardableResult
    public func refresh(now: Date = Date()) -> [ProcessUsage] {
        if let lastSweep, now.timeIntervalSince(lastSweep) < Self.minimumInterval {
            return cached
        }

        let elapsed = lastSweep.map { now.timeIntervalSince($0) } ?? 0
        var usages: [ProcessUsage] = []
        var currentCPU: [pid_t: Double] = [:]
        usages.reserveCapacity(cached.count)

        for pid in Self.runningPIDs() {
            // Processes owned by another user, and most of the system's, refuse
            // to report. That is expected -- roughly 187 of 653 on a normal Mac
            // -- and they are skipped rather than shown as zero.
            guard let reading = Self.usage(of: pid) else { continue }
            currentCPU[pid] = reading.cpuSeconds

            let cpu: Double
            if elapsed > 0, let before = previousCPU[pid] {
                cpu = max(0, (reading.cpuSeconds - before) / elapsed * 100)
            } else {
                // First sweep, or a process that has only just appeared: there
                // is no interval to divide by, and guessing would put a
                // fictional spike at the top of the list.
                cpu = 0
            }

            usages.append(
                ProcessUsage(
                    pid: pid,
                    name: Self.name(of: pid),
                    cpuPercent: cpu,
                    memoryBytes: Double(reading.footprint)
                )
            )
        }

        // A baseline exists once two sweeps have been taken with real time
        // between them.
        if lastSweep != nil, elapsed > 0 { hasBaseline = true }
        previousCPU = currentCPU
        lastSweep = now
        cached = usages
        return usages
    }

    /// Empty for `.cpu` until a baseline exists -- see `hasBaseline`. Memory is
    /// an instantaneous reading and is available from the first sweep.
    public func top(_ count: Int, by ranking: Ranking, now: Date = Date()) -> [ProcessUsage] {
        let usages = refresh(now: now)
        guard ranking != .cpu || hasBaseline else { return [] }
        let sorted = switch ranking {
        case .cpu: usages.sorted { $0.cpuPercent > $1.cpuPercent }
        case .memory: usages.sorted { $0.memoryBytes > $1.memoryBytes }
        }
        return Array(sorted.prefix(count))
    }

    /// Forgets history, so the next refresh starts a fresh interval.
    public func reset() {
        previousCPU.removeAll()
        lastSweep = nil
        cached = []
        hasBaseline = false
    }

    // MARK: - libproc

    static func runningPIDs() -> [pid_t] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bytes)
        guard written > 0 else { return [] }

        return Array(pids.prefix(Int(written) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    private static let bufferSize = MemoryLayout<rusage_info_v6>.stride * 4

    static func usage(of pid: pid_t) -> (cpuSeconds: Double, footprint: UInt64)? {
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferSize,
            alignment: MemoryLayout<rusage_info_v6>.alignment
        )
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: bufferSize)

        // Same pointer contract as ProcessProbe in the benchmark: the kernel
        // writes the struct *at* this address, not through it.
        let typed = buffer.bindMemory(
            to: rusage_info_t?.self,
            capacity: bufferSize / MemoryLayout<rusage_info_t?>.stride
        )
        guard proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, typed) == 0 else { return nil }

        let info = buffer.loadUnaligned(as: rusage_info_v6.self)
        return (
            MachTime.seconds(info.ri_user_time + info.ri_system_time),
            info.ri_phys_footprint
        )
    }

    static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(2 * MAXCOMLEN) + 1)
        proc_name(pid, &buffer, UInt32(buffer.count))
        let text = String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return text.isEmpty ? "pid \(pid)" : text
    }
}
