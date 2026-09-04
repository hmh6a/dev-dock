import Foundation

/// Reads the Mac's temperature sensors.
///
/// macOS has no public temperature API. On Apple Silicon the sensors are exposed
/// as HID services (usage page `0xff00`, usage `5`) through `IOHIDEventSystemClient`,
/// which is private — so the four functions we need are looked up with `dlsym`
/// instead of linked against. That keeps the app buildable and launchable even if
/// a future macOS drops them: the lookup fails, and the UI shows temperatures as
/// unavailable rather than crashing.
///
/// Unlike `powermetrics`, this needs no root.
///
/// Stateful (it caches the client and the service list, which never change while
/// the app runs), hence a reference type with a lock.
public final class ThermalSensorReader: @unchecked Sendable {

    private let lock = NSLock()
    private var api: HIDAPI?
    private var client: AnyObject?
    private var services: [AnyObject] = []
    private var unavailable = false

    public init() {}

    /// Current temperatures, grouped and summarized.
    ///
    /// Returns ``ThermalSnapshot/empty`` on a Mac that exposes no HID thermal
    /// sensors (Intel Macs report theirs through the SMC instead).
    public func read() -> ThermalSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard prepare(), let api else { return .empty }

        let readings: [(name: String, celsius: Double)] = services.compactMap { service in
            guard let name = api.copyProperty(service, "Product" as CFString)?
                    .takeRetainedValue() as? String,
                  let event = api.copyEvent(service, Self.temperatureEventType, 0, 0)?
                    .takeRetainedValue()
            else { return nil }
            return (name, api.eventFloatValue(event, Self.temperatureField))
        }
        return ThermalSensorClassifier.summarize(readings)
    }

    /// Whether this Mac exposes any readable thermal sensor.
    public var isSupported: Bool {
        lock.lock()
        defer { lock.unlock() }
        return prepare() && !services.isEmpty
    }

    // MARK: - Private

    /// `kIOHIDEventTypeTemperature`.
    private static let temperatureEventType: Int64 = 15
    /// Event fields are `(type << 16) | index`; index 0 is the level itself.
    private static let temperatureField = Int32(temperatureEventType << 16)

    /// Look up the private API and the sensor services once. Caller holds the lock.
    private func prepare() -> Bool {
        if unavailable { return false }
        if client != nil { return true }

        guard let api = api ?? HIDAPI(),
              let created = api.createClient(kCFAllocatorDefault)?.takeRetainedValue()
        else {
            unavailable = true
            return false
        }
        self.api = api

        // Match only temperature sensors — the same client would otherwise return
        // every HID service on the machine, keyboards included.
        api.setMatching(created, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        services = (api.copyServices(created)?.takeRetainedValue() as? [AnyObject]) ?? []
        client = created
        return true
    }
}

/// The four private `IOHIDEventSystemClient` entry points, resolved at runtime.
private struct HIDAPI {
    typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Void
    typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<CFTypeRef>?
    typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    typealias EventFloatValue = @convention(c) (AnyObject, Int32) -> Double

    let createClient: CreateClient
    let setMatching: SetMatching
    let copyServices: CopyServices
    let copyProperty: CopyProperty
    let copyEvent: CopyEvent
    let eventFloatValue: EventFloatValue

    init?() {
        // IOKit is already loaded in-process; this just gets us a handle to look
        // the unexported-in-headers symbols up by name.
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else {
            return nil
        }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let create = symbol("IOHIDEventSystemClientCreate", CreateClient.self),
              let matching = symbol("IOHIDEventSystemClientSetMatching", SetMatching.self),
              let servicesFn = symbol("IOHIDEventSystemClientCopyServices", CopyServices.self),
              let property = symbol("IOHIDServiceClientCopyProperty", CopyProperty.self),
              let event = symbol("IOHIDServiceClientCopyEvent", CopyEvent.self),
              let float = symbol("IOHIDEventGetFloatValue", EventFloatValue.self)
        else { return nil }

        createClient = create
        setMatching = matching
        copyServices = servicesFn
        copyProperty = property
        copyEvent = event
        eventFloatValue = float
    }
}
