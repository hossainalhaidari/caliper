import Foundation
import IOKit

/// GPU utilisation and memory, from the accelerator's own statistics.
///
/// The least private thing in this milestone: `PerformanceStatistics` is an
/// ordinary IORegistry property on the accelerator service, requiring no
/// undocumented symbols. Verified on an M4 (`AGXAcceleratorG16G`), which reports
/// device, renderer and tiler utilisation alongside allocation figures.
///
/// On Apple Silicon "GPU memory" is a share of unified memory rather than
/// dedicated VRAM, so the metric is named for what it is -- memory the GPU has
/// allocated -- instead of implying a separate pool.
public final class GPUSource: MetricSource, @unchecked Sendable {
    public static let utilization: MetricID = "gpu.utilization"
    public static let rendererUtilization: MetricID = "gpu.renderer.utilization"
    public static let tilerUtilization: MetricID = "gpu.tiler.utilization"
    public static let allocatedMemory: MetricID = "gpu.memory.allocated.bytes"
    public static let inUseMemory: MetricID = "gpu.memory.inuse.bytes"

    private static let statisticsKey = "PerformanceStatistics"

    private var accelerators: [io_object_t] = []
    private let available: Bool

    public init() {
        // Probed once: a machine with no matching accelerator publishes no GPU
        // metrics at all, rather than offering a picker entry that can never
        // produce a reading.
        available = Self.matchingServices().count > 0
        Self.release(Self.matchingServices())
    }

    public var cadence: Cadence { .live }

    public var descriptors: [MetricDescriptor] {
        guard available else { return [] }
        return [
            MetricDescriptor(id: Self.utilization, displayName: String(localized: "GPU Usage", comment: "Metric name, in the metric picker and the detail panel"), group: "GPU", unit: .percent, range: .percentage),
            MetricDescriptor(id: Self.rendererUtilization, displayName: String(localized: "GPU Renderer", comment: "Metric name, in the metric picker and the detail panel"), group: "GPU", unit: .percent, range: .percentage),
            MetricDescriptor(id: Self.tilerUtilization, displayName: String(localized: "GPU Tiler", comment: "Metric name, in the metric picker and the detail panel"), group: "GPU", unit: .percent, range: .percentage),
            MetricDescriptor(id: Self.allocatedMemory, displayName: String(localized: "GPU Memory Allocated", comment: "Metric name, in the metric picker and the detail panel"), group: "GPU", unit: .bytes, range: .unbounded(min: 0)),
            MetricDescriptor(id: Self.inUseMemory, displayName: String(localized: "GPU Memory In Use", comment: "Metric name, in the metric picker and the detail panel"), group: "GPU", unit: .bytes, range: .unbounded(min: 0)),
        ]
    }

    public func activate() {
        accelerators = Self.matchingServices()
    }

    public func deactivate() {
        Self.release(accelerators)
        accelerators.removeAll(keepingCapacity: true)
    }

    public func sample(into sink: inout SampleSink, context: SampleContext) {
        var utilisation = 0.0
        var renderer = 0.0
        var tiler = 0.0
        var allocated = 0.0
        var inUse = 0.0
        var found = false

        for accelerator in accelerators {
            guard let statistics = IORegistryEntryCreateCFProperty(
                accelerator, Self.statisticsKey as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }

            found = true
            // Several GPUs would each report their own utilisation; taking the
            // busiest is more useful than averaging, for the same reason the core
            // matrix alerts on its hottest core.
            utilisation = max(utilisation, number(statistics, "Device Utilization %"))
            renderer = max(renderer, number(statistics, "Renderer Utilization %"))
            tiler = max(tiler, number(statistics, "Tiler Utilization %"))
            allocated += number(statistics, "Alloc system memory")
            inUse += number(statistics, "In use system memory")
        }

        guard found else { return }
        sink.emit(Self.utilization, utilisation)
        sink.emit(Self.rendererUtilization, renderer)
        sink.emit(Self.tilerUtilization, tiler)
        sink.emit(Self.allocatedMemory, allocated)
        sink.emit(Self.inUseMemory, inUse)
    }

    private func number(_ statistics: [String: Any], _ key: String) -> Double {
        (statistics[key] as? NSNumber)?.doubleValue ?? 0
    }

    // MARK: - IOKit

    private static func matchingServices() -> [io_object_t] {
        guard let matching = IOServiceMatching("IOAccelerator") else { return [] }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [io_object_t] = []
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            result.append(service)
        }
        return result
    }

    private static func release(_ services: [io_object_t]) {
        for service in services { IOObjectRelease(service) }
    }

    deinit {
        Self.release(accelerators)
    }
}
