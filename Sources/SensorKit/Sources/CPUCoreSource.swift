import Darwin

/// Per-core CPU load, plus aggregates for each performance cluster.
///
/// Deliberately separate from `CPULoadSource` rather than an option on it,
/// because this is the expensive one: `host_processor_info` makes the *kernel*
/// allocate an array on every sample, which the caller must then `vm_deallocate`
/// -- a malloc/free pair every second for as long as it runs. Splitting it out
/// means the refcounting in `MetricBus` can keep that cost switched off entirely
/// unless a widget actually shows per-core data.
///
/// ## Cluster ordering
///
/// On Apple Silicon `host_processor_info` reports cores **least-performant
/// first**, which is the reverse of how `hw.perflevelN` numbers them
/// (`perflevel0` is the *most* performant). Verified empirically on an M4 with
/// 4 Performance + 6 Efficiency cores: user-interactive work landed on indices
/// 6-9, background work on 0-3.
///
/// The mapping is derived from the sysctls rather than hardcoded, so it holds on
/// any Apple Silicon layout and collapses correctly on Intel, where there is one
/// performance level and therefore no cluster split worth showing.
public final class CPUCoreSource: MetricSource, @unchecked Sendable {

    /// One contiguous run of processor indices sharing a performance level.
    public struct Cluster: Sendable {
        /// As reported by the kernel: "Performance", "Efficiency".
        public let name: String
        public let metric: MetricID
        public let indices: Range<Int>
    }

    public static func core(_ index: Int) -> MetricID {
        MetricID("cpu.core.\(index).usage")
    }

    private let host: mach_port_t = mach_host_self()
    private let coreCount: Int
    public let clusters: [Cluster]

    private var previous: [ProcessorTicks] = []

    struct ProcessorTicks {
        var user: natural_t = 0
        var system: natural_t = 0
        var idle: natural_t = 0
        var nice: natural_t = 0
    }

    public init() {
        self.coreCount = Int(Self.sysctlInt("hw.logicalcpu") ?? 1)
        self.clusters = Self.discoverClusters(totalCores: coreCount)
    }

    public var cadence: Cadence { .live }

    public var descriptors: [MetricDescriptor] {
        var result: [MetricDescriptor] = []

        for index in 0..<coreCount {
            // Cores are named by cluster where one exists, because "P2" is
            // meaningful to someone reading a strip and "core 8" is not.
            let label = clusterLabel(for: index)
                ?? String(localized: "Core \(index)", comment: "Metric name: one processor core, numbered from 0")
            result.append(
                MetricDescriptor(
                    id: Self.core(index),
                    displayName: label,
                    group: "CPU Cores",
                    unit: .percent,
                    range: .percentage
                )
            )
        }

        for cluster in clusters {
            result.append(
                MetricDescriptor(
                    id: cluster.metric,
                    displayName: String(localized: "\(cluster.name) Cores", comment: "Metric name, in the metric picker and the detail panel"),
                    group: "CPU",
                    unit: .percent,
                    range: .percentage
                )
            )
        }

        return result
    }

    /// Short name for a core, e.g. "P0" / "E3", or nil on a machine with a
    /// single performance level.
    private func clusterLabel(for index: Int) -> String? {
        guard clusters.count > 1 else { return nil }
        guard let cluster = clusters.first(where: { $0.indices.contains(index) }),
              let initial = cluster.name.first else { return nil }
        return "\(initial)\(index - cluster.indices.lowerBound)"
    }

    public func activate() {
        previous = readTicks()
    }

    public func deactivate() {
        previous = []
    }

    public func sample(into sink: inout SampleSink, context: SampleContext) {
        let current = readTicks()
        guard current.count == previous.count, !current.isEmpty else {
            previous = current
            return
        }
        defer { previous = current }

        // Reused across the loop so cluster aggregates can be accumulated in the
        // same pass rather than re-walking the arrays.
        var clusterBusy = [Double](repeating: 0, count: clusters.count)
        var clusterTotal = [Double](repeating: 0, count: clusters.count)

        for index in current.indices {
            let now = current[index]
            let last = previous[index]

            let user = now.user &- last.user
            let system = now.system &- last.system
            let idle = now.idle &- last.idle
            let nice = now.nice &- last.nice

            let busy = Double(user &+ system &+ nice)
            let total = busy + Double(idle)

            // Same lazy-counter behaviour as CPULoadSource: an unchanged
            // snapshot means "no information", not "zero percent".
            guard total > 0 else { continue }
            sink.emit(Self.core(index), busy / total * 100)

            if let slot = clusters.firstIndex(where: { $0.indices.contains(index) }) {
                clusterBusy[slot] += busy
                clusterTotal[slot] += total
            }
        }

        // A single-cluster machine would just be reporting cpu.usage.total again
        // under a different name, so those aggregates are not published at all.
        guard clusters.count > 1 else { return }
        for (slot, cluster) in clusters.enumerated() where clusterTotal[slot] > 0 {
            sink.emit(cluster.metric, clusterBusy[slot] / clusterTotal[slot] * 100)
        }
    }

    // MARK: - Mach plumbing

    private func readTicks() -> [ProcessorTicks] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }

        // The kernel allocated this; failing to hand it back leaks a page per
        // sample, which at 1 Hz is a few megabytes an hour.
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        var result = [ProcessorTicks]()
        result.reserveCapacity(Int(count))
        for core in 0..<Int(count) {
            let base = core * Int(CPU_STATE_MAX)
            result.append(
                ProcessorTicks(
                    user: natural_t(bitPattern: info[base + Int(CPU_STATE_USER)]),
                    system: natural_t(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                    idle: natural_t(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                    nice: natural_t(bitPattern: info[base + Int(CPU_STATE_NICE)])
                )
            )
        }
        return result
    }

    // MARK: - Topology

    public static func discoverClusters(totalCores: Int) -> [Cluster] {
        let levels = Int(sysctlInt("hw.nperflevels") ?? 1)
        guard levels > 1 else { return [] }

        var result: [Cluster] = []
        var start = 0

        // Reverse order: perflevel0 is the most performant, but processor
        // indices begin with the least performant.
        for level in stride(from: levels - 1, through: 0, by: -1) {
            guard let count = sysctlInt("hw.perflevel\(level).logicalcpu"), count > 0 else { continue }
            let name = sysctlString("hw.perflevel\(level).name") ?? "Level \(level)"
            let end = min(start + Int(count), totalCores)
            guard start < end else { break }

            result.append(
                Cluster(
                    name: name,
                    metric: MetricID("cpu.cluster.\(name.lowercased()).usage"),
                    indices: start..<end
                )
            )
            start = end
        }

        return result
    }

    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let status = buffer.withUnsafeMutableBytes {
            sysctlbyname(name, $0.baseAddress, &size, nil, 0)
        }
        guard status == 0 else { return nil }
        // sysctl reports the buffer length including the NUL terminator, which
        // would otherwise become a trailing character inside a metric id.
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
