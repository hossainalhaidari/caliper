import Foundation

/// Access to Apple's HID sensor services, where Apple Silicon keeps its
/// temperature and fan readings.
///
/// There are no headers for any of this. `IOHIDEventSystemClient` is private, so
/// the symbols are resolved at runtime and the signatures written out by hand,
/// which means a mistake produces silence or nonsense rather than a compile
/// error. It cost one debugging round already: the temperature field constant is
/// `IOHIDEventFieldBase(type)`, and using `base | 1` returns a perfectly
/// plausible 0.00 for all 47 sensors rather than failing.
///
/// Everything here is behind a capability probe. If a future macOS renames or
/// removes these symbols, `isSupported` is false, the sources publish no
/// descriptors, and the app simply does not offer temperatures -- rather than
/// shipping a picker full of metrics that can never produce a reading.
final class HIDSensorInterface: @unchecked Sendable {
    static let shared = HIDSensorInterface()

    /// Apple's vendor HID page, where the sensors live.
    static let appleVendorPage = 0xff00
    /// Verified on an M4: 47 services, names like "PMU tdie6".
    static let temperatureUsage = 5
    /// Not present on any fanless Mac, and this was developed on a MacBook Air.
    /// See `FanSource` for what that means.
    static let fanUsage = 12

    private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Void
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatValue = @convention(c) (AnyObject, Int32) -> Double

    private let create: ClientCreate?
    private let setMatching: SetMatching?
    private let copyServices: CopyServices?
    private let copyProperty: CopyProperty?
    private let copyEvent: CopyEvent?
    private let floatValue: GetFloatValue?

    let isSupported: Bool

    private init() {
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        create = symbol("IOHIDEventSystemClientCreate", ClientCreate.self)
        setMatching = symbol("IOHIDEventSystemClientSetMatching", SetMatching.self)
        copyServices = symbol("IOHIDEventSystemClientCopyServices", CopyServices.self)
        copyProperty = symbol("IOHIDServiceClientCopyProperty", CopyProperty.self)
        copyEvent = symbol("IOHIDServiceClientCopyEvent", CopyEvent.self)
        floatValue = symbol("IOHIDEventGetFloatValue", GetFloatValue.self)

        isSupported = create != nil && setMatching != nil && copyServices != nil
            && copyProperty != nil && copyEvent != nil && floatValue != nil
    }

    func makeClient() -> AnyObject? {
        guard let create else { return nil }
        return create(kCFAllocatorDefault)?.takeRetainedValue()
    }

    /// Services matching a usage, with their reported names.
    ///
    /// Names are not unique: this machine has six sensors all called "gas gauge
    /// battery". Callers must disambiguate rather than keying on the name.
    func services(from client: AnyObject, usage: Int) -> [(name: String, service: AnyObject)] {
        guard let setMatching, let copyServices, let copyProperty else { return [] }

        setMatching(client, [
            "PrimaryUsagePage": Self.appleVendorPage,
            "PrimaryUsage": usage,
        ] as CFDictionary)

        guard let raw = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return [] }

        return raw.map { service in
            let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String
            return (name ?? "Sensor", service)
        }
    }

    /// Reads one sensor. `nil` when the service has no current event, which
    /// happens routinely and is not an error.
    func read(_ service: AnyObject, eventType: Int64) -> Double? {
        guard let copyEvent, let floatValue else { return nil }
        guard let event = copyEvent(service, eventType, 0, 0)?.takeRetainedValue() else { return nil }
        // The value field is the event type's base, with no offset. Getting this
        // wrong returns zero, not an error.
        return floatValue(event, Int32(eventType << 16))
    }

    /// kIOHIDEventTypeTemperature
    static let temperatureEvent: Int64 = 15
    /// kIOHIDEventTypeFanSpeed
    static let fanEvent: Int64 = 16
}
