import Foundation
import IOKit

/// Read and write throughput, aggregated across physical block devices.
///
/// Comes from the IORegistry rather than from any per-process accounting, so it
/// reflects what the hardware is actually doing -- including the paging that a
/// memory-pressured Mac is quietly performing on your behalf, which is usually
/// the interesting part.
///
/// The device list is enumerated once and the IOKit object references are held,
/// because `IOServiceGetMatchingServices` is comparatively expensive and running
/// it every second to rediscover the same internal SSD would be wasteful. Only
/// the `Statistics` sub-dictionary is fetched per sample, not the device's whole
/// property list, which is a large dictionary to build and throw away 86,400
/// times a day.
public final class DiskActivitySource: MetricSource, @unchecked Sendable {
    public static let readRate: MetricID = "disk.io.read.rate"
    public static let writeRate: MetricID = "disk.io.write.rate"
    public static let sessionRead: MetricID = "disk.io.session.read.bytes"
    public static let sessionWritten: MetricID = "disk.io.session.written.bytes"

    // Declared as literals because these are C string #defines, which do not
    // reliably import into Swift as constants.
    private static let statisticsKey = "Statistics"
    private static let bytesReadKey = "Bytes (Read)"
    private static let bytesWrittenKey = "Bytes (Write)"

    private var devices: [io_object_t] = []
    private var previousRead: UInt64?
    private var previousWritten: UInt64?
    private var sessionReadBytes: Double = 0
    private var sessionWrittenBytes: Double = 0

    public init() {}

    public var cadence: Cadence { .live }

    public var descriptors: [MetricDescriptor] {
        [
            MetricDescriptor(
                id: Self.readRate,
                displayName: String(localized: "Disk Read", comment: "Metric name, in the metric picker and the detail panel"),
                group: "Disk",
                unit: .bytesPerSecond,
                range: .unbounded(min: 0)
            ),
            MetricDescriptor(
                id: Self.writeRate,
                displayName: String(localized: "Disk Write", comment: "Metric name, in the metric picker and the detail panel"),
                group: "Disk",
                unit: .bytesPerSecond,
                range: .unbounded(min: 0)
            ),
            MetricDescriptor(
                id: Self.sessionRead,
                displayName: String(localized: "Read This Session", comment: "Metric name, in the metric picker and the detail panel"),
                group: "Disk",
                unit: .bytes,
                range: .unbounded(min: 0)
            ),
            MetricDescriptor(
                id: Self.sessionWritten,
                displayName: String(localized: "Written This Session", comment: "Metric name, in the metric picker and the detail panel"),
                group: "Disk",
                unit: .bytes,
                range: .unbounded(min: 0)
            ),
        ]
    }

    public func activate() {
        rescanDevices()
        let totals = readTotals()
        previousRead = totals?.read
        previousWritten = totals?.written
    }

    public func deactivate() {
        releaseDevices()
        previousRead = nil
        previousWritten = nil
    }

    /// Re-enumerates block devices. Call when a volume is mounted or unmounted;
    /// otherwise a drive plugged in after launch contributes nothing.
    public func rescanDevices() {
        releaseDevices()

        // IOServiceGetMatchingServices consumes a reference to the matching
        // dictionary, so it must not be released here.
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            devices.append(service)
        }
    }

    private func releaseDevices() {
        for device in devices { IOObjectRelease(device) }
        devices.removeAll(keepingCapacity: true)
    }

    public func sample(into sink: inout SampleSink, context: SampleContext) {
        guard let totals = readTotals() else { return }
        defer {
            previousRead = totals.read
            previousWritten = totals.written
        }

        guard context.hasInterval,
              let lastRead = previousRead,
              let lastWritten = previousWritten else { return }

        // These counters are 64-bit and reset only on unplug, but a device
        // disappearing between samples shrinks the aggregate. Clamping at zero
        // avoids reporting a nonsensical negative rate in that moment.
        let read = Double(totals.read >= lastRead ? totals.read - lastRead : 0)
        let written = Double(totals.written >= lastWritten ? totals.written - lastWritten : 0)

        sink.emit(Self.readRate, read / context.elapsed)
        sink.emit(Self.writeRate, written / context.elapsed)

        sessionReadBytes += read
        sessionWrittenBytes += written
        sink.emit(Self.sessionRead, sessionReadBytes)
        sink.emit(Self.sessionWritten, sessionWrittenBytes)
    }

    // MARK: - IORegistry

    private func readTotals() -> (read: UInt64, written: UInt64)? {
        guard !devices.isEmpty else { return nil }

        var read: UInt64 = 0
        var written: UInt64 = 0

        for device in devices {
            guard let property = IORegistryEntryCreateCFProperty(
                device,
                Self.statisticsKey as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] else { continue }

            read += (property[Self.bytesReadKey] as? NSNumber)?.uint64Value ?? 0
            written += (property[Self.bytesWrittenKey] as? NSNumber)?.uint64Value ?? 0
        }

        return (read, written)
    }

    deinit {
        releaseDevices()
    }
}
