import Darwin
import Foundation

/// Free and used space on the volumes a person actually cares about.
///
/// Volume selection is the entire difficulty here. A current Mac mounts far more
/// than it shows you: the machine this was developed on has sixteen volumes, of
/// which fifteen are APFS system volumes (`VM`, `Preboot`, `xART`, `Update`) or
/// read-only simulator disk images. Exactly one, `Macintosh HD`, is a thing a
/// person would want in their menu bar.
///
/// The boot volume needs its own rule, because since Big Sur there is no single
/// volume that *is* your startup disk. `/` is the read-only signed system volume
/// and `/System/Volumes/Data` is the writable one, marked don't-browse; the
/// "Macintosh HD" Finder shows is a synthesised view of that firmlinked pair.
/// Filtering on "browsable and writable" therefore matches *neither* of them and
/// finds no boot volume at all. `MNT_ROOTFS` identifies it directly, and because
/// both halves live in one APFS container the capacity figures it reports are
/// the container's -- which is what a person means by "space left on my Mac".
///
/// Every other volume is filtered on **local, browsable, writable**, which picks
/// out exactly what Finder shows in the sidebar. Read-only volumes are excluded
/// deliberately rather than incidentally: free space on a volume that cannot be
/// written to is a constant, and a menu bar is for things that change.
///
/// Uses `getmntinfo` with `MNT_NOWAIT` rather than `FileManager`'s volume
/// enumeration, because it reads the kernel's cached mount table and cannot
/// block. Fetching volume properties the ordinary way can stall on an
/// unreachable network mount, and a sampler that blocks is worse than one that
/// reports nothing.
public final class DiskCapacitySource: MetricSource, @unchecked Sendable {
    public static let bootTotal: MetricID = "disk.boot.total.bytes"
    public static let bootFree: MetricID = "disk.boot.free.bytes"
    public static let bootUsed: MetricID = "disk.boot.used.bytes"
    public static let bootUsagePercent: MetricID = "disk.boot.usage.percent"

    /// Named metrics for a non-boot volume.
    ///
    /// Note these are *not* portable between Macs -- `disk.volume.backup.*`
    /// means nothing on a machine with no volume called Backup. `disk.boot.*` is
    /// the portable spelling and is what shared widgets should prefer. M4's
    /// import step reports unresolvable metrics rather than failing silently.
    public static func volumeUsagePercent(_ name: String) -> MetricID {
        MetricID("disk.volume.\(slug(name)).usage.percent")
    }

    public static func volumeFree(_ name: String) -> MetricID {
        MetricID("disk.volume.\(slug(name)).free.bytes")
    }

    struct Volume {
        let name: String
        let mountPoint: String
        let isBoot: Bool
        let totalBytes: Double
        let freeBytes: Double
    }

    public init() {}

    /// Capacity moves slowly and is worth almost nothing to sample often.
    public var cadence: Cadence { .idle }

    public var descriptors: [MetricDescriptor] {
        var result: [MetricDescriptor] = []
        let volumes = Self.scan()

        if let boot = volumes.first(where: \.isBoot) {
            result += [
                MetricDescriptor(
                    id: Self.bootUsagePercent,
                    displayName: String(localized: "Disk Used", comment: "Metric name, in the metric picker and the detail panel"),
                    group: "Disk",
                    unit: .percent,
                    range: .percentage
                ),
                MetricDescriptor(
                    id: Self.bootFree,
                    displayName: String(localized: "Disk Free", comment: "Metric name, in the metric picker and the detail panel"),
                    group: "Disk",
                    unit: .bytes,
                    range: .bounded(min: 0, max: boot.totalBytes)
                ),
                MetricDescriptor(
                    id: Self.bootUsed,
                    displayName: String(localized: "Disk Used", comment: "Metric name, in the metric picker and the detail panel"),
                    group: "Disk",
                    unit: .bytes,
                    range: .bounded(min: 0, max: boot.totalBytes)
                ),
                MetricDescriptor(
                    id: Self.bootTotal,
                    displayName: String(localized: "Disk Capacity", comment: "Metric name, in the metric picker and the detail panel"),
                    group: "Disk",
                    unit: .bytes,
                    range: .bounded(min: 0, max: boot.totalBytes)
                ),
            ]
        }

        for volume in volumes where !volume.isBoot {
            result += [
                MetricDescriptor(
                    id: Self.volumeUsagePercent(volume.name),
                    displayName: String(localized: "\(volume.name) Used", comment: "Metric name, in the metric picker and the detail panel"),
                    group: "Volumes",
                    unit: .percent,
                    range: .percentage
                ),
                MetricDescriptor(
                    id: Self.volumeFree(volume.name),
                    displayName: String(localized: "\(volume.name) Free", comment: "Metric name, in the metric picker and the detail panel"),
                    group: "Volumes",
                    unit: .bytes,
                    range: .bounded(min: 0, max: volume.totalBytes)
                ),
            ]
        }

        return result
    }

    public func sample(into sink: inout SampleSink, context: SampleContext) {
        // Rescanned every sample rather than cached, so a drive plugged in after
        // launch starts reporting on its own. At a 30 second cadence the cost of
        // reading the mount table is irrelevant.
        for volume in Self.scan() {
            let used = max(0, volume.totalBytes - volume.freeBytes)
            let percent = volume.totalBytes > 0 ? used / volume.totalBytes * 100 : 0

            if volume.isBoot {
                sink.emit(Self.bootTotal, volume.totalBytes)
                sink.emit(Self.bootFree, volume.freeBytes)
                sink.emit(Self.bootUsed, used)
                sink.emit(Self.bootUsagePercent, percent)
            } else {
                sink.emit(Self.volumeUsagePercent(volume.name), percent)
                sink.emit(Self.volumeFree(volume.name), volume.freeBytes)
            }
        }
    }

    // MARK: - Mount table

    /// Reads the kernel's cached mount table.
    ///
    /// Uses `getmntinfo_r_np`, the reentrant variant, rather than plain
    /// `getmntinfo`. The latter returns a pointer to a *static* buffer, so two
    /// concurrent callers silently corrupt each other's results -- which is
    /// exactly what happened the first time the parallel test runner called this
    /// from several tests at once, producing a machine with no boot volume.
    ///
    /// Being queue-confined by `MetricBus` would have made the static version
    /// safe in production, but a function that is only safe when called from one
    /// specific place is a trap set for whoever calls it next -- the M3 editor
    /// enumerating volumes from the main thread, for instance. One malloc every
    /// thirty seconds is a small price for it simply not being a hazard.
    static func scan() -> [Volume] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        // The reentrant variant hands over ownership of the buffer.
        defer { free(buffer) }

        var result: [Volume] = []

        for index in 0..<Int(count) {
            let entry = buffer[index]
            let flags = entry.f_flags

            // Local first: never touch a network mount, whatever else is true.
            guard flags & UInt32(MNT_LOCAL) != 0 else { continue }

            let isBoot = flags & UInt32(MNT_ROOTFS) != 0
            if !isBoot {
                // Browsable: skip the APFS system volumes Finder hides (VM,
                // Preboot, Update, Data). Writable: skip read-only disk images,
                // which is what every installed simulator runtime is -- eleven
                // of them on the machine this was written on.
                guard flags & UInt32(MNT_DONTBROWSE) == 0,
                      flags & UInt32(MNT_RDONLY) == 0 else { continue }
            }

            let mountPoint = withUnsafePointer(to: entry.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }

            let blockSize = Double(entry.f_bsize)
            let name = isBoot
                ? (FileManager.default.displayName(atPath: "/").isEmpty ? "Macintosh HD" : FileManager.default.displayName(atPath: "/"))
                : (mountPoint as NSString).lastPathComponent

            result.append(
                Volume(
                    name: name,
                    mountPoint: mountPoint,
                    isBoot: isBoot,
                    totalBytes: Double(entry.f_blocks) * blockSize,
                    // f_bavail, not f_bfree: blocks available to an ordinary
                    // user, excluding the reserve only root can touch.
                    freeBytes: Double(entry.f_bavail) * blockSize
                )
            )
        }

        return result
    }

    /// Volume names become part of a metric id, so they have to survive being
    /// written into a shared JSON document and read back.
    static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        let mapped = lowered.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        // Collapse runs of separators so "Time Machine  Backup" and
        // "Time-Machine-Backup" do not produce two different metric ids.
        return String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }
}
