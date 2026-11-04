import Foundation
import IOKit.hidsystem

/// The connected mice, through the HID event system: each one's pointer resolution and
/// acceleration, the same per-device properties System Settings → Mouse sets. Trackpads keep the
/// system's settings.
///
/// Writes last until the mouse is unplugged or the Mac restarts, so whatever NyCopilot changed is
/// put back (`restore`) when the feature is turned off or NyCopilot quits.
@MainActor
final class PointerDevices {
    struct Mouse {
        let service: IOHIDServiceClient
        let id: UInt64
        let name: String
    }

    /// A mouse was connected, or the system's own pointer settings changed (which resets every
    /// mouse's acceleration to them).
    var onChange: () -> Void = {}

    private let client: IOHIDEventSystemClient
    /// Takes the client off the run loop when this object goes: the callbacks hold an unretained pointer to it.
    private var scheduling: Scheduling?
    /// Each mouse's own resolution and linear setting from before NyCopilot first wrote to it.
    private var originals: [UInt64: (resolution: Double?, linear: Int?)] = [:]
    /// Mice NyCopilot changed, so `restore` leaves untouched ones alone.
    private var changed: Set<UInt64> = []
    private var lastSystem: (Double?, Int?)

    private static let resolutionKey = "HIDPointerResolution" as CFString
    private static let mouseAccelerationKey = "HIDMouseAcceleration" as CFString
    private static let accelerationTypeKey = "HIDPointerAccelerationType" as CFString
    private static let linearKey = "HIDUseLinearScalingMouseAcceleration" as CFString
    /// macOS's acceleration when it has none set, and the resolution most mice report.
    private static let defaultAcceleration = 0.6875
    private static let defaultResolution = 400.0

    /// Nil when this macOS lacks the event system calls a full client needs.
    init?() {
        guard let calls = Self.calls, let client = calls.create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        self.client = client
        let pointers = [[kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
                        [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer]]
        calls.setMatchingMultiple(client, pointers as CFArray)
        lastSystem = (nil, nil)
        lastSystem = system
        let target = Unmanaged.passUnretained(self).toOpaque()
        calls.registerDeviceMatching(client, { target, _, _ in
            guard let target else { return }
            MainActor.assumeIsolated { Unmanaged<PointerDevices>.fromOpaque(target).takeUnretainedValue().onChange() }
        }, target, nil)
        for key in [Self.mouseAccelerationKey, Self.linearKey] {
            calls.registerPropertyChanged(client, key, { target, _, _, _ in
                guard let target else { return }
                MainActor.assumeIsolated { Unmanaged<PointerDevices>.fromOpaque(target).takeUnretainedValue().systemChanged() }
            }, target, nil)
        }
        scheduling = Scheduling(client: client, calls: calls)
    }

    private final class Scheduling: @unchecked Sendable {
        private let client: IOHIDEventSystemClient
        private let calls: Calls

        init(client: IOHIDEventSystemClient, calls: Calls) {
            self.client = client
            self.calls = calls
            calls.schedule(client, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }

        deinit { calls.unschedule?(client, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) }
    }

    /// The mice connected now: anything that moves the pointer with mouse-style acceleration.
    var mice: [Mouse] {
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        return services.compactMap { service in
            let type = IOHIDServiceClientCopyProperty(service, Self.accelerationTypeKey) as? String
            guard type == Self.mouseAccelerationKey as String
                    || (type == nil && IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0
                        && (IOHIDServiceClientCopyProperty(service, kIOHIDBuiltInKey as CFString) as? Bool) != true),
                  let id = (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value else { return nil }
            let name = (IOHIDServiceClientCopyProperty(service, kIOHIDProductKey as CFString) as? String)?
                .trimmingCharacters(in: .whitespaces)
            return Mouse(service: service, id: id, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? L("Mouse"))
        }
    }

    /// System Settings' acceleration for mice (its tracking speed), if it has one.
    var systemAcceleration: Double? { system.0 }

    /// The same, for showing: the SDK's own simple client may read this one property.
    static var systemSetting: Double? {
        number(IOHIDEventSystemClientCopyProperty(IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault), mouseAccelerationKey))
            .map { $0 / 65536 }
    }

    /// Speed, then acceleration: a new resolution takes effect only when acceleration is set after it.
    func set(_ mouse: Mouse, resolution: Double, acceleration: Double, linear: Bool) {
        _ = original(of: mouse)
        changed.insert(mouse.id)
        IOHIDServiceClientSetProperty(mouse.service, Self.linearKey, NSNumber(value: linear ? 1 : 0))
        IOHIDServiceClientSetProperty(mouse.service, Self.resolutionKey, Self.fixed(resolution))
        IOHIDServiceClientSetProperty(mouse.service, Self.mouseAccelerationKey, Self.fixed(acceleration))
    }

    /// Back to the mouse's own resolution and the system's settings, if NyCopilot changed it.
    func restore(_ mouse: Mouse) {
        guard changed.remove(mouse.id) != nil else { return }
        let original = original(of: mouse)
        IOHIDServiceClientSetProperty(mouse.service, Self.linearKey, NSNumber(value: original.linear ?? system.1 ?? 0))
        IOHIDServiceClientSetProperty(mouse.service, Self.resolutionKey, Self.fixed(original.resolution ?? Self.defaultResolution))
        IOHIDServiceClientSetProperty(mouse.service, Self.mouseAccelerationKey, Self.fixed(systemAcceleration ?? Self.defaultAcceleration))
    }

    // MARK: Private

    private var system: (Double?, Int?) {
        (Self.number(IOHIDEventSystemClientCopyProperty(client, Self.mouseAccelerationKey)).map { $0 / 65536 },
         Self.number(IOHIDEventSystemClientCopyProperty(client, Self.linearKey)).map(Int.init))
    }

    /// Writes to a mouse can be reported as a system change too; only a real one counts.
    private func systemChanged() {
        let now = system
        guard now.0 != lastSystem.0 || now.1 != lastSystem.1 else { return }
        lastSystem = now
        onChange()
    }

    private func original(of mouse: Mouse) -> (resolution: Double?, linear: Int?) {
        if let known = originals[mouse.id] { return known }
        let read = (Self.number(IOHIDServiceClientCopyProperty(mouse.service, Self.resolutionKey)).map { $0 / 65536 },
                    Self.number(IOHIDServiceClientCopyProperty(mouse.service, Self.linearKey)).map(Int.init))
        originals[mouse.id] = read
        return read
    }

    private static func number(_ value: CFTypeRef?) -> Double? { (value as? NSNumber)?.doubleValue }

    /// The event system's 16.16 fixed-point numbers.
    private static func fixed(_ value: Double) -> CFNumber { NSNumber(value: Int(value * 65536)) }

    // MARK: Event system calls

    /// The calls a full event system client needs: IOKit exports them, but only the read-mostly
    /// simple client is declared in the SDK, and it can't reach pointer resolution.
    private struct Calls: Sendable {
        typealias ServiceCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, IOHIDServiceClient?) -> Void
        typealias PropertyCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, CFString?, CFTypeRef?) -> Void
        let create: @convention(c) (CFAllocator?) -> Unmanaged<IOHIDEventSystemClient>?
        let setMatchingMultiple: @convention(c) (IOHIDEventSystemClient, CFArray) -> Void
        let registerDeviceMatching: @convention(c) (IOHIDEventSystemClient, ServiceCallback, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
        let registerPropertyChanged: @convention(c) (IOHIDEventSystemClient, CFString, PropertyCallback, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
        let schedule: @convention(c) (IOHIDEventSystemClient, CFRunLoop, CFString) -> Void
        /// Undoes `schedule`, so no callback reaches a client that's gone.
        let unschedule: (@convention(c) (IOHIDEventSystemClient, CFRunLoop, CFString) -> Void)?
    }

    private static let calls: Calls? = {
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) } // RTLD_DEFAULT
        }
        guard let create = symbol("IOHIDEventSystemClientCreate", as: (@convention(c) (CFAllocator?) -> Unmanaged<IOHIDEventSystemClient>?).self),
              let matching = symbol("IOHIDEventSystemClientSetMatchingMultiple", as: (@convention(c) (IOHIDEventSystemClient, CFArray) -> Void).self),
              let device = symbol("IOHIDEventSystemClientRegisterDeviceMatchingCallback", as:
                (@convention(c) (IOHIDEventSystemClient, Calls.ServiceCallback, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void).self),
              let property = symbol("IOHIDEventSystemClientRegisterPropertyChangedCallback", as:
                (@convention(c) (IOHIDEventSystemClient, CFString, Calls.PropertyCallback, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void).self),
              let schedule = symbol("IOHIDEventSystemClientScheduleWithRunLoop", as: (@convention(c) (IOHIDEventSystemClient, CFRunLoop, CFString) -> Void).self)
        else {
            Diagnostics.note("mouse", "the HID event system calls aren’t available")
            return nil
        }
        return Calls(create: create, setMatchingMultiple: matching, registerDeviceMatching: device, registerPropertyChanged: property,
                     schedule: schedule,
                     unschedule: symbol("IOHIDEventSystemClientUnscheduleWithRunLoop", as: (@convention(c) (IOHIDEventSystemClient, CFRunLoop, CFString) -> Void).self))
    }()
}
