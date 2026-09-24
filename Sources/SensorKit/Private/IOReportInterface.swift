import Foundation

/// Access to IOReport, the kernel's performance counter plumbing.
///
/// Two things about this were only discoverable by trying:
///
/// **It is not in IOKit.** The symbols live in `/usr/lib/libIOReport.dylib`,
/// which is in the dyld shared cache and therefore does not exist as a file on
/// disk -- `ls` finds nothing while `dlopen` succeeds.
///
/// **Channels in one group do not share a unit.** A single "Energy Model" sample
/// on an M4 returns CPU energy in mJ, GPU energy in nJ, and PCIe energy in uJ,
/// all at once. Assuming a unit would be wrong by a factor of a million, so the
/// label is read per channel and converted.
final class IOReportInterface: @unchecked Sendable {
    static let shared = IOReportInterface()

    private typealias CopyChannelsInGroup = @convention(c)
        (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription = @convention(c)
        (UnsafeMutableRawPointer?, CFMutableDictionary,
         UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> Unmanaged<AnyObject>?
    private typealias CreateSamples = @convention(c)
        (AnyObject, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta = @convention(c)
        (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias IterateChannels = @convention(c)
        (CFDictionary, @convention(block) (CFDictionary) -> Int32) -> Void
    private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias ChannelInteger = @convention(c) (CFDictionary, Int32) -> Int64

    private let copyChannelsInGroup: CopyChannelsInGroup?
    private let createSubscription: CreateSubscription?
    private let createSamples: CreateSamples?
    private let createSamplesDelta: CreateSamplesDelta?
    private let iterate: IterateChannels?
    private let channelName: ChannelString?
    private let channelUnit: ChannelString?
    private let integerValue: ChannelInteger?

    let isSupported: Bool

    private init() {
        let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY)

        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        copyChannelsInGroup = symbol("IOReportCopyChannelsInGroup", CopyChannelsInGroup.self)
        createSubscription = symbol("IOReportCreateSubscription", CreateSubscription.self)
        createSamples = symbol("IOReportCreateSamples", CreateSamples.self)
        createSamplesDelta = symbol("IOReportCreateSamplesDelta", CreateSamplesDelta.self)
        iterate = symbol("IOReportIterate", IterateChannels.self)
        channelName = symbol("IOReportChannelGetChannelName", ChannelString.self)
        channelUnit = symbol("IOReportChannelGetUnitLabel", ChannelString.self)
        integerValue = symbol("IOReportSimpleGetIntegerValue", ChannelInteger.self)

        isSupported = copyChannelsInGroup != nil && createSubscription != nil
            && createSamples != nil && createSamplesDelta != nil && iterate != nil
            && channelName != nil && channelUnit != nil && integerValue != nil
    }

    /// A live subscription to one channel group.
    final class Subscription {
        let subscription: AnyObject
        let channels: CFMutableDictionary

        init(subscription: AnyObject, channels: CFMutableDictionary) {
            self.subscription = subscription
            self.channels = channels
        }
    }

    func subscribe(group: String) -> Subscription? {
        guard isSupported,
              let copyChannelsInGroup, let createSubscription,
              let channels = copyChannelsInGroup(group as CFString, nil, 0, 0, 0)?.takeRetainedValue()
        else { return nil }

        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let handle = createSubscription(nil, channels, &subscribed, 0, nil)?.takeRetainedValue(),
              let subscribedChannels = subscribed?.takeRetainedValue()
        else { return nil }

        return Subscription(subscription: handle, channels: subscribedChannels)
    }

    func sample(_ subscription: Subscription) -> CFDictionary? {
        guard let createSamples else { return nil }
        return createSamples(subscription.subscription, subscription.channels, nil)?.takeRetainedValue()
    }

    /// Energy accumulated per channel between two samples, in **joules**.
    func energyDelta(from first: CFDictionary, to second: CFDictionary) -> [String: Double] {
        guard let createSamplesDelta, let iterate, let channelName, let channelUnit, let integerValue,
              let delta = createSamplesDelta(first, second, nil)?.takeRetainedValue()
        else { return [:] }

        var result: [String: Double] = [:]
        iterate(delta) { channel in
            guard let name = channelName(channel)?.takeUnretainedValue() as String? else { return 0 }
            let unit = channelUnit(channel)?.takeUnretainedValue() as String? ?? ""
            let raw = integerValue(channel, 0)
            // Zero is a real reading: an idle Neural Engine genuinely consumed
            // no energy this interval, and reporting nothing would leave the
            // cell showing a dash as though the sensor were missing. Negatives
            // are a different matter -- state channels sharing the group report
            // Int64.min as a sentinel, which is not energy at all.
            guard raw >= 0, let joules = Self.joules(raw, unit: unit) else { return 0 }
            result[name] = joules
            return 0
        }
        return result
    }

    /// Converts a raw counter to joules using the channel's own unit label.
    ///
    /// Returns nil for units that are not energy, so a state or event counter
    /// that happens to share the group cannot be mistaken for power.
    static func joules(_ raw: Int64, unit: String) -> Double? {
        let value = Double(raw)
        return switch unit.lowercased() {
        case "nj": value / 1_000_000_000
        case "uj", "\u{00b5}j": value / 1_000_000
        case "mj": value / 1_000
        case "j": value
        default: nil
        }
    }
}
