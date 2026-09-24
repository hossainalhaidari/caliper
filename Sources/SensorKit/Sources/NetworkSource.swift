import Darwin
import Foundation
import SystemConfiguration

/// Throughput on the interface that actually carries your traffic.
///
/// Summing every non-loopback interface is the obvious implementation and it
/// produces a visibly wrong number. On the machine this was developed on there
/// are six: `en0` (Wi-Fi), `utun4` (a VPN tunnel carrying 1.1 GB that *also*
/// traverses en0, so it would be counted twice), and `awdl0` / `llw0` -- Apple
/// Wireless Direct Link, used for AirDrop and Continuity -- which between them
/// had logged 3 GB of "output" that never touched the network you care about.
///
/// So the default follows the **default route**: whichever interface
/// SystemConfiguration currently reports as primary. It moves with you from
/// Wi-Fi to Ethernet without configuration, and it cannot double-count a tunnel
/// against the link underneath it. Per-interface metrics remain available for
/// anyone who deliberately wants to watch a tunnel.
public final class NetworkSource: MetricSource, @unchecked Sendable {
    public static let downloadRate: MetricID = "net.throughput.down"
    public static let uploadRate: MetricID = "net.throughput.up"
    public static let sessionReceived: MetricID = "net.session.received.bytes"
    public static let sessionSent: MetricID = "net.session.sent.bytes"

    public static func interfaceDownload(_ name: String) -> MetricID {
        MetricID("net.if.\(name).throughput.down")
    }

    public static func interfaceUpload(_ name: String) -> MetricID {
        MetricID("net.if.\(name).throughput.up")
    }

    private struct Counters {
        var received: UInt32
        var sent: UInt32
    }

    private var store: SCDynamicStore?
    private var previous: [String: Counters] = [:]

    /// Accumulated in 64 bits from wrap-safe deltas rather than read from the
    /// kernel's cumulative field, which is only 32 bits wide and wraps every
    /// 4 GB. Totals are therefore "since this source started", which is both
    /// honest and more useful in a menu bar than "since boot".
    private var sessionReceivedBytes: Double = 0
    private var sessionSentBytes: Double = 0

    /// Interfaces present when the app started. Hot-plugged hardware and VPN
    /// tunnels raised later will still be measured through the primary-interface
    /// metrics; what they lack is a *named* per-interface metric, because
    /// descriptors are enumerated once. Dynamic rescanning arrives with the
    /// editor in M3, which is the first thing that needs a live metric list.
    private let knownInterfaces: [String]

    public init() {
        self.knownInterfaces = Self.enumerateInterfaces()
    }

    public var cadence: Cadence { .live }

    public var descriptors: [MetricDescriptor] {
        var result: [MetricDescriptor] = [
            MetricDescriptor(
                id: Self.downloadRate,
                displayName: String(localized: "Download", comment: "Metric name, in the metric picker and the detail panel"),
                group: "Network",
                unit: .bytesPerSecond,
                range: .unbounded(min: 0)
            ),
            MetricDescriptor(
                id: Self.uploadRate,
                displayName: String(localized: "Upload", comment: "Metric name, in the metric picker and the detail panel"),
                group: "Network",
                unit: .bytesPerSecond,
                range: .unbounded(min: 0)
            ),
            MetricDescriptor(
                id: Self.sessionReceived,
                displayName: String(localized: "Received This Session", comment: "Metric name, in the metric picker and the detail panel"),
                group: "Network",
                unit: .bytes,
                range: .unbounded(min: 0)
            ),
            MetricDescriptor(
                id: Self.sessionSent,
                displayName: String(localized: "Sent This Session", comment: "Metric name, in the metric picker and the detail panel"),
                group: "Network",
                unit: .bytes,
                range: .unbounded(min: 0)
            ),
        ]

        for name in knownInterfaces {
            result.append(
                MetricDescriptor(
                    id: Self.interfaceDownload(name),
                    displayName: String(localized: "\(name) Download", comment: "Metric name, in the metric picker and the detail panel"),
                    group: "Network Interfaces",
                    unit: .bytesPerSecond,
                    range: .unbounded(min: 0)
                )
            )
            result.append(
                MetricDescriptor(
                    id: Self.interfaceUpload(name),
                    displayName: String(localized: "\(name) Upload", comment: "Metric name, in the metric picker and the detail panel"),
                    group: "Network Interfaces",
                    unit: .bytesPerSecond,
                    range: .unbounded(min: 0)
                )
            )
        }

        return result
    }

    public func activate() {
        store = SCDynamicStoreCreate(nil, "de.alhaidari.caliper" as CFString, nil, nil)
        previous = readCounters()
    }

    public func deactivate() {
        store = nil
        previous = [:]
    }

    public func sample(into sink: inout SampleSink, context: SampleContext) {
        let current = readCounters()
        defer { previous = current }

        // No baseline, or a resumed timer with no measured interval: a rate needs
        // both, and inventing either would put a false spike on the graph.
        guard context.hasInterval, !previous.isEmpty else { return }

        let primary = primaryInterface()

        for (name, counters) in current {
            guard let last = previous[name] else { continue }

            // Wrapping subtraction: these counters are 32-bit and do roll over.
            // At any sane cadence the delta is far below 4 GB, so `&-` gives the
            // right answer across the wrap.
            let received = Double(counters.received &- last.received)
            let sent = Double(counters.sent &- last.sent)

            let downRate = received / context.elapsed
            let upRate = sent / context.elapsed

            if knownInterfaces.contains(name) {
                sink.emit(Self.interfaceDownload(name), downRate)
                sink.emit(Self.interfaceUpload(name), upRate)
            }

            guard name == primary else { continue }
            sink.emit(Self.downloadRate, downRate)
            sink.emit(Self.uploadRate, upRate)

            sessionReceivedBytes += received
            sessionSentBytes += sent
            sink.emit(Self.sessionReceived, sessionReceivedBytes)
            sink.emit(Self.sessionSent, sessionSentBytes)
        }
    }

    // MARK: - Interface resolution

    /// The interface holding the default route, per SystemConfiguration.
    ///
    /// Re-read every sample rather than cached, because it changes the moment you
    /// plug in Ethernet or drop off Wi-Fi, and a stale answer would silently
    /// report throughput for a link no longer in use.
    private func primaryInterface() -> String? {
        guard let store else { return nil }
        let key = "State:/Network/Global/IPv4" as CFString
        guard let global = SCDynamicStoreCopyValue(store, key) as? [String: Any] else { return nil }
        return global["PrimaryInterface"] as? String
    }

    private func readCounters() -> [String: Counters] {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let addresses else { return [:] }
        defer { freeifaddrs(addresses) }

        var result: [String: Counters] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = addresses

        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }

            // Only the link-level entry carries traffic counters; the same
            // interface also appears once per assigned IP address.
            guard entry.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let raw = entry.pointee.ifa_data else { continue }

            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            result[String(cString: entry.pointee.ifa_name)] = Counters(
                received: data.ifi_ibytes,
                sent: data.ifi_obytes
            )
        }

        return result
    }

    private static func enumerateInterfaces() -> [String] {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let addresses else { return [] }
        defer { freeifaddrs(addresses) }

        var result: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = addresses

        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard entry.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            if !result.contains(name) { result.append(name) }
        }

        return result.sorted()
    }
}
