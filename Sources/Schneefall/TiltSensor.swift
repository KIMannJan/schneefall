import Foundation
import IOKit
import IOKit.hid
import SnowCore

/// Reads the (undocumented) accelerometer in the sensor processor (SPU) of
/// Apple-silicon MacBooks. It sleeps by default; we wake it only while snow is
/// visible and put it back to sleep afterwards. No permission is needed.
/// Reports (50/s) are 22 bytes; x, y, z are little-endian Int32 at offsets 6, 10, 14
/// in 1/65536 g. `TiltReading` smooths them and decides whether to trust them.
final class TiltSensor {
    private var manager: IOHIDManager?
    private var reading = TiltReading()

    static var isAvailable: Bool {
        let services = driverServices()
        services.forEach { IOObjectRelease($0) }
        return !services.isEmpty
    }

    /// Gravity on screen (0 = down, +π/2 = toward the right edge), nil while unknown.
    var screenAngle: Double? { manager == nil ? nil : reading.screenAngle }

    func start() {
        guard manager == nil else { return }
        Self.setDriver(awake: true)
        reading = TiltReading(trusted: reading.trusted)    // fresh smoothing, trust carries over
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 0x05AC, kIOHIDProductIDKey: 0x8104,
                                          kIOHIDPrimaryUsagePageKey: 0xFF00, kIOHIDPrimaryUsageKey: 3] as CFDictionary)
        IOHIDManagerRegisterInputReportCallback(m, { context, _, _, _, _, report, length in
            guard let context, length >= 18 else { return }
            Unmanaged<TiltSensor>.fromOpaque(context).takeUnretainedValue().handle(report)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            Self.setDriver(awake: false)
            return
        }
        manager = m
    }

    func stop() {
        guard let m = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
        Self.setDriver(awake: false)
    }

    private func handle(_ r: UnsafeMutablePointer<UInt8>) {
        func axis(_ o: Int) -> Double {
            Double(Int32(bitPattern: UInt32(r[o]) | UInt32(r[o + 1]) << 8 | UInt32(r[o + 2]) << 16 | UInt32(r[o + 3]) << 24)) / 65536
        }
        reading.add(x: axis(6), y: axis(10), z: axis(14))
    }

    /// Wakes the accelerometer (a report every 20 ms) or puts it back to sleep. Also
    /// called once at launch, in case a crash or kill left it awake.
    static func setDriver(awake: Bool) {
        let values: [(String, Int)] = awake
            ? [("SensorPropertyReportingState", 1), ("SensorPropertyPowerState", 1), ("ReportInterval", 20_000)]
            : [("ReportInterval", 0), ("SensorPropertyReportingState", 0), ("SensorPropertyPowerState", 0)]
        for service in driverServices() {
            for (key, value) in values { IORegistryEntrySetCFProperty(service, key as CFString, value as CFNumber) }
            IOObjectRelease(service)
        }
    }

    /// The SPU accelerometer driver(s); the caller releases them.
    private static func driverServices() -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            func number(_ key: String) -> Int? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
            }
            if number("PrimaryUsagePage") == 0xFF00 && number("PrimaryUsage") == 3 { found.append(service) } else { IOObjectRelease(service) }
        }
        return found
    }
}
