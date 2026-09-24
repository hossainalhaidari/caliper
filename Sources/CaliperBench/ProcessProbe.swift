import Darwin
import Foundation
import SensorKit

/// Reads CPU time and memory footprint for a process.
///
/// Uses `proc_pid_rusage`, which works on any process owned by the same user,
/// so the same code path measures the benchmark itself and a separately running
/// copy of the app. `ri_phys_footprint` is specifically the number Activity
/// Monitor shows in its "Memory" column -- resident size would over-report by
/// counting shared framework pages the app did not cause to be loaded, and
/// quietly flatter us.
struct ProcessProbe {
    struct Reading {
        var cpuSeconds: Double
        var footprintBytes: UInt64
        var wallClock: Date
    }

    /// Heap buffer, generously oversized, rather than a stack struct.
    ///
    /// `proc_pid_rusage`'s third parameter is declared `rusage_info_t *`, and
    /// `rusage_info_t` is itself `void *` -- so the natural Swift spelling,
    /// passing `&someLocalPointer`, type-checks and is completely wrong. C
    /// callers pass `(rusage_info_t *)&someStruct`: the kernel writes the
    /// struct *at that address*, not through it. Getting this backwards hands
    /// the kernel an 8-byte stack slot to write ~200 bytes into, and the
    /// process dies in `__stack_chk_fail`.
    ///
    /// Sizing for `rusage_info_v6` with room to spare also covers the kernel
    /// writing the current layout regardless of the flavour requested. The
    /// `rusage_info_vN` structs are append-only, so the fields read below keep
    /// their offsets when a future macOS adds a v7.
    private static let bufferSize = MemoryLayout<rusage_info_v6>.stride * 4

    static func read(pid: pid_t) -> Reading? {
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferSize,
            alignment: MemoryLayout<rusage_info_v6>.alignment
        )
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: bufferSize)

        let typed = buffer.bindMemory(
            to: rusage_info_t?.self,
            capacity: bufferSize / MemoryLayout<rusage_info_t?>.stride
        )
        guard proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, typed) == 0 else { return nil }

        let info = buffer.loadUnaligned(as: rusage_info_v6.self)

        return Reading(
            // Mach units, not nanoseconds -- see `MachTime`. Getting this wrong
            // silently under-reported this app's own CPU use by a factor of
            // 41.67 in every measurement taken before it was found.
            cpuSeconds: MachTime.seconds(info.ri_user_time + info.ri_system_time),
            footprintBytes: info.ri_phys_footprint,
            wallClock: Date()
        )
    }

    /// Average CPU utilisation between two readings, as a percentage of one core.
    static func utilization(from start: Reading, to end: Reading) -> Double {
        let elapsed = end.wallClock.timeIntervalSince(start.wallClock)
        guard elapsed > 0 else { return 0 }
        return (end.cpuSeconds - start.cpuSeconds) / elapsed * 100
    }
}

enum Format {
    /// CPU seconds consumed by this process so far.
    static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
             + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }

    static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    static func microseconds(_ seconds: Double) -> String {
        String(format: "%.2f us", seconds * 1_000_000)
    }
}
