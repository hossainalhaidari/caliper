import Darwin

/// Aggregate CPU load, read from the Mach kernel's cumulative tick counters.
///
/// Deliberately uses `host_statistics(HOST_CPU_LOAD_INFO)` rather than
/// `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`. The per-core call has the
/// kernel *allocate* an array on every single sample, which the caller must
/// then `vm_deallocate` -- a malloc/free pair every second, forever, for a
/// number that fits in 16 bytes. `host_statistics` fills a fixed struct we own.
/// The per-core matrix (M1) will pay that cost, but only when a widget actually
/// asks for per-core data.
///
/// The counters are monotonically increasing tick totals, so usage is a delta
/// between consecutive samples: the very first sample after `activate()`
/// produces nothing, because "since boot" is not what anyone wants to look at.
public final class CPULoadSource: MetricSource, @unchecked Sendable {
    public static let total: MetricID = "cpu.usage.total"
    public static let user: MetricID = "cpu.usage.user"
    public static let system: MetricID = "cpu.usage.system"

    /// `mach_host_self()` returns a *send right* and bumps a reference count on
    /// every call. Acquiring it once and holding it avoids leaking a port
    /// reference per sample -- a slow leak that only shows up after hours.
    private let host: mach_port_t = mach_host_self()


    private var previous: host_cpu_load_info?

    public init() {}

    public var cadence: Cadence { .live }

    public var descriptors: [MetricDescriptor] {
        [
            MetricDescriptor(
                id: Self.total,
                displayName: String(localized: "CPU Usage", comment: "Metric name, in the metric picker and the detail panel"),
                group: "CPU",
                unit: .percent,
                range: .percentage
            ),
            MetricDescriptor(
                id: Self.user,
                displayName: String(localized: "CPU User", comment: "Metric name, in the metric picker and the detail panel"),
                group: "CPU",
                unit: .percent,
                range: .percentage
            ),
            MetricDescriptor(
                id: Self.system,
                displayName: String(localized: "CPU System", comment: "Metric name, in the metric picker and the detail panel"),
                group: "CPU",
                unit: .percent,
                range: .percentage
            ),
        ]
    }

    public func activate() {
        // Prime the delta so the first *reported* value is a real interval and
        // not a since-boot average.
        previous = readTicks()
    }

    public func deactivate() {
        previous = nil
    }

    /// Ignores `context`: this source divides one tick delta by another, so the
    /// result is a ratio that is already independent of how long the interval was.
    public func sample(into sink: inout SampleSink, context: SampleContext) {
        guard let current = readTicks() else { return }
        defer { previous = current }
        guard let last = previous else { return }

        let user = Self.delta(current, last, CPU_STATE_USER)
        let system = Self.delta(current, last, CPU_STATE_SYSTEM)
        let idle = Self.delta(current, last, CPU_STATE_IDLE)
        let nice = Self.delta(current, last, CPU_STATE_NICE)

        let total = user + system + idle + nice
        // Two consecutive reads can legitimately return the *same* counters.
        //
        // On Apple Silicon these aggregates are updated lazily rather than on a
        // fixed timer tick, so a caller that stays on-core can read an
        // unchanged snapshot even hundreds of milliseconds apart -- and then
        // see a double-sized delta on the following read. Measured on an M4:
        // reads taken while sleeping advance smoothly, reads taken while
        // busy-looping return zero deltas roughly a third of the time.
        //
        // Emitting 0% here would put a visible, wrong dip in the graph. Emitting
        // nothing leaves the previous value on screen for one more tick, and
        // because the next delta covers the full elapsed period the percentage
        // stays accurate. Silence is the correct answer, not a fallback.
        guard total > 0 else { return }

        let scale = 100.0 / Double(total)
        // `nice` is user-priority work; folding it into user matches what every
        // other tool on the machine shows.
        sink.emit(Self.user, Double(user + nice) * scale)
        sink.emit(Self.system, Double(system) * scale)
        sink.emit(Self.total, Double(user + nice + system) * scale)
    }

    // MARK: - Mach plumbing

    private func readTicks() -> host_cpu_load_info? {
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride
        )
        var info = host_cpu_load_info()

        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(host, HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }

        return status == KERN_SUCCESS ? info : nil
    }

    /// Tick counters are `natural_t` and do wrap on long uptimes. `&-` gives
    /// the correct delta across the wrap instead of a nonsensical huge number
    /// (or a trap in a debug build).
    private static func delta(
        _ current: host_cpu_load_info,
        _ previous: host_cpu_load_info,
        _ state: Int32
    ) -> UInt32 {
        ticks(current, state) &- ticks(previous, state)
    }

    private static func ticks(_ info: host_cpu_load_info, _ state: Int32) -> natural_t {
        switch state {
        case CPU_STATE_USER: info.cpu_ticks.0
        case CPU_STATE_SYSTEM: info.cpu_ticks.1
        case CPU_STATE_IDLE: info.cpu_ticks.2
        default: info.cpu_ticks.3  // CPU_STATE_NICE
        }
    }
}
