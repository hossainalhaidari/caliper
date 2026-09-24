import Darwin

/// Physical memory, swap, and the kernel's own view of memory pressure.
///
/// macOS reports memory in a way that regularly alarms people for no reason: a
/// healthy Mac aggressively fills RAM with cache and compressed pages, so "used"
/// sits high by design. A machine can read 78% used while the kernel considers
/// memory perfectly healthy -- which is exactly the state the machine this was
/// developed on was in.
///
/// So this source publishes both stories and lets the widget decide which one to
/// show and which one to alert on. The default widget shows `usagePercent`,
/// because that is the number people expect, and alerts on `pressure`, because
/// that is the number that is true. See `Cell.alertMetric`.
public final class MemorySource: MetricSource, @unchecked Sendable {
    public static let usagePercent: MetricID = "memory.usage.percent"
    public static let used: MetricID = "memory.used.bytes"
    public static let app: MetricID = "memory.app.bytes"
    public static let wired: MetricID = "memory.wired.bytes"
    public static let compressed: MetricID = "memory.compressed.bytes"
    public static let cached: MetricID = "memory.cached.bytes"
    public static let free: MetricID = "memory.free.bytes"
    public static let pressure: MetricID = "memory.pressure"
    public static let swapUsed: MetricID = "memory.swap.used.bytes"
    public static let swapTotal: MetricID = "memory.swap.total.bytes"

    /// Kernel pressure levels, normalised to something a threshold can compare.
    ///
    /// The raw sysctl reports 1 / 2 / 4 -- a bitmask, not a scale. Remapping to
    /// 0 / 1 / 2 means a widget can say "alert at 1" and mean "warning or worse",
    /// which is what a user setting a threshold expects.
    public enum Pressure: Double {
        case normal = 0
        case warning = 1
        case critical = 2
    }

    private let host: mach_port_t = mach_host_self()
    /// Total RAM never changes, so it is read once rather than every second.
    private let totalBytes: Double
    private let pageSize: Double

    public init() {
        var size = MemoryLayout<UInt64>.size
        var bytes: UInt64 = 0
        sysctlbyname("hw.memsize", &bytes, &size, nil, 0)
        self.totalBytes = Double(bytes)

        // Asked of the kernel rather than read from the `vm_kernel_page_size`
        // global, which Swift 6 rejects as shared mutable state -- and rightly
        // so. This is also the page size that `host_statistics64` counts in,
        // which is the one that matters here: 16 KB on Apple Silicon, 4 KB on
        // Intel, and getting it wrong scales every memory figure by four.
        var kernelPageSize: vm_size_t = 0
        host_page_size(host, &kernelPageSize)
        self.pageSize = Double(kernelPageSize)
    }

    public var cadence: Cadence { .live }

    public var descriptors: [MetricDescriptor] {
        func bytes(_ id: MetricID, _ name: String) -> MetricDescriptor {
            MetricDescriptor(
                id: id,
                displayName: name,
                group: "Memory",
                unit: .bytes,
                // Bounded by installed RAM, which lets these drive a proportional
                // renderer (arc, pie) and not just a number.
                range: .bounded(min: 0, max: totalBytes)
            )
        }

        return [
            MetricDescriptor(
                id: Self.usagePercent,
                displayName: String(localized: "Memory Used", comment: "Metric name, in the metric picker and the detail panel"),
                group: "Memory",
                unit: .percent,
                range: .percentage
            ),
            bytes(Self.used, String(localized: "Memory Used", comment: "Metric name, in the metric picker and the detail panel")),
            bytes(Self.app, String(localized: "App Memory", comment: "Metric name, in the metric picker and the detail panel")),
            bytes(Self.wired, String(localized: "Wired Memory", comment: "Metric name, in the metric picker and the detail panel")),
            bytes(Self.compressed, String(localized: "Compressed Memory", comment: "Metric name, in the metric picker and the detail panel")),
            bytes(Self.cached, String(localized: "Cached Files", comment: "Metric name, in the metric picker and the detail panel")),
            bytes(Self.free, String(localized: "Free Memory", comment: "Metric name, in the metric picker and the detail panel")),
            MetricDescriptor(
                id: Self.pressure,
                displayName: String(localized: "Memory Pressure", comment: "Metric name, in the metric picker and the detail panel"),
                group: "Memory",
                unit: .count,
                range: .bounded(min: 0, max: 2)
            ),
            MetricDescriptor(
                id: Self.swapUsed,
                displayName: String(localized: "Swap Used", comment: "Metric name, in the metric picker and the detail panel"),
                group: "Memory",
                unit: .bytes,
                range: .unbounded(min: 0)
            ),
            MetricDescriptor(
                id: Self.swapTotal,
                displayName: String(localized: "Swap Size", comment: "Metric name, in the metric picker and the detail panel"),
                group: "Memory",
                unit: .bytes,
                range: .unbounded(min: 0)
            ),
        ]
    }

    /// Every value here is an instantaneous level rather than a delta, so there
    /// is no baseline to prime and nothing to reset between activations.
    public func sample(into sink: inout SampleSink, context: SampleContext) {
        if let vm = readVMStatistics() {
            let wiredBytes = Double(vm.wire_count) * pageSize
            let compressedBytes = Double(vm.compressor_page_count) * pageSize
            let purgeableBytes = Double(vm.purgeable_count) * pageSize
            let externalBytes = Double(vm.external_page_count) * pageSize
            let internalBytes = Double(vm.internal_page_count) * pageSize

            // Activity Monitor's decomposition. "App Memory" is anonymous pages
            // minus the purgeable ones, because purgeable memory is a cache the
            // kernel can reclaim without swapping -- counting it as used would
            // overstate what the machine actually needs.
            let appBytes = max(0, internalBytes - purgeableBytes)
            let usedBytes = appBytes + wiredBytes + compressedBytes

            sink.emit(Self.app, appBytes)
            sink.emit(Self.wired, wiredBytes)
            sink.emit(Self.compressed, compressedBytes)
            sink.emit(Self.cached, externalBytes + purgeableBytes)
            sink.emit(Self.free, Double(vm.free_count) * pageSize)
            sink.emit(Self.used, usedBytes)

            if totalBytes > 0 {
                sink.emit(Self.usagePercent, usedBytes / totalBytes * 100)
            }
        }

        sink.emit(Self.pressure, readPressure().rawValue)

        if let swap = readSwap() {
            sink.emit(Self.swapUsed, Double(swap.xsu_used))
            sink.emit(Self.swapTotal, Double(swap.xsu_total))
        }
    }

    // MARK: - Kernel plumbing

    private func readVMStatistics() -> vm_statistics64? {
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
        )
        var info = vm_statistics64()

        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(host, HOST_VM_INFO64, rebound, &count)
            }
        }

        return status == KERN_SUCCESS ? info : nil
    }

    private func readPressure() -> Pressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .normal
        }

        // The sysctl reports the kernel's bitmask: 1 normal, 2 warn, 4 critical.
        return switch level {
        case 4: .critical
        case 2: .warning
        default: .normal
        }
    }

    private func readSwap() -> xsw_usage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage
    }
}
