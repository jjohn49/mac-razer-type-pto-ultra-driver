import Foundation
import IOKit.hid
import KeyboardCore

public struct DeviceInfo: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var product: String
    public var productID: Int
    public var transport: String
    public var interfaces: Int
    public var hasControlInterface: Bool
    public var label: String { "\(product) — \(transport)" }
}

public enum HIDDevices {
    public static func value(_ d: IOHIDDevice, _ key: String) -> Int { (IOHIDDeviceGetProperty(d, key as CFString) as? NSNumber)?.intValue ?? 0 }
    public static func string(_ d: IOHIDDevice, _ key: String) -> String { IOHIDDeviceGetProperty(d, key as CFString) as? String ?? "" }
    public static func supported(_ d: IOHIDDevice) -> Bool {
        guard value(d,"VendorID") == 0x1532, value(d,"Built-In") == 0 else { return false }
        let pid = value(d,"ProductID")
        return pid == 0x0277 || pid == 0x027B ||
            (string(d,"Transport").lowercased().contains("bluetooth") && string(d,"Product").lowercased().contains("pro type ultra"))
    }
    public static func identity(_ d: IOHIDDevice) -> String {
        let location = value(d,"LocationID")
        if location != 0 { return "\(value(d,"ProductID")):\(string(d,"Transport")):\(location)" }
        let serial = string(d,"SerialNumber")
        if !serial.isEmpty && serial != "000000000000" { return "\(value(d,"ProductID")):\(string(d,"Transport")):\(serial)" }
        // A registry parent identifies one physical device without grouping unrelated
        // keyboards with missing/placeholder serial numbers. It can change on reconnect.
        var parent: io_registry_entry_t = 0
        var id: UInt64 = 0
        if IORegistryEntryGetParentEntry(IOHIDDeviceGetService(d), kIOServicePlane, &parent) == KERN_SUCCESS {
            IORegistryEntryGetRegistryEntryID(parent, &id); IOObjectRelease(parent)
        }
        return "\(value(d,"ProductID")):\(string(d,"Transport")):\(id)"
    }
    public static func enumerate() -> [IOHIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, ["VendorID":0x1532] as CFDictionary)
        return Array(IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []).filter(supported)
    }
    public static func list() -> [DeviceInfo] {
        Dictionary(grouping: enumerate(), by: identity).map { id, devices in
            let d = devices[0]
            return DeviceInfo(id:id, product:string(d,"Product"), productID:value(d,"ProductID"), transport:string(d,"Transport"), interfaces:devices.count, hasControlInterface:devices.contains { value($0,"MaxFeatureReportSize") == 90 })
        }.sorted { $0.id < $1.id }
    }
    /// Automatic choice: wired keyboard, then receiver, then anything else. An
    /// explicit override wins only while that device is present.
    public static func preferred(_ devices: [DeviceInfo], override: String?) -> DeviceInfo? {
        if let override, let chosen = devices.first(where: { $0.id == override }) { return chosen }
        func rank(_ d: DeviceInfo) -> Int { d.productID == 0x0277 ? 0 : d.productID == 0x027B ? 1 : 2 }
        return devices.sorted { (rank($0), $0.id) < (rank($1), $1.id) }.first
    }
    /// The HyperSpeed receiver answers only the wireless transaction ID (0x9F);
    /// the wired transaction (0x1F) gets status 0x04.
    public static func isReceiver(deviceID: String) -> Bool { deviceID.hasPrefix("\(0x027B):") }
    /// Interfaces that produce keystrokes, consumer keys, or system-control keys
    /// are seized. The control interface (mouse usages plus a 90-byte feature
    /// report) is left alone so the app can configure the keyboard meanwhile.
    public static func isInputInterface(usagePairs: [(page: UInt32, usage: UInt32)]) -> Bool {
        usagePairs.contains { ($0.page == 1 && [6, 7, 0x80].contains($0.usage)) || ($0.page == 12 && $0.usage == 1) }
    }
    public static func usagePairs(_ d: IOHIDDevice) -> [(page: UInt32, usage: UInt32)] {
        let pairs = IOHIDDeviceGetProperty(d, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Int]] ?? []
        return pairs.compactMap { pair in
            guard let page = pair[kIOHIDDeviceUsagePageKey], let usage = pair[kIOHIDDeviceUsageKey] else { return nil }
            return (UInt32(page), UInt32(usage))
        }
    }
    public static func inputInterfaces(for id: String) -> [IOHIDDevice] {
        enumerate().filter { identity($0) == id && isInputInterface(usagePairs: usagePairs($0)) }
    }
    public static func permissionGranted() -> Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }
    public static func requestPermission() { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
}

/// Opens the keyboard's control interface without seizing it and exchanges one
/// 90-byte feature report at a time. Uses the synchronous IOKit calls, so it can
/// be driven from any serial queue without a run loop.
public final class HIDTransport: ReportTransport {
    private let device: IOHIDDevice
    public let wireless: Bool
    public init(deviceID: String? = nil) throws {
        let candidates = HIDDevices.enumerate().filter {
            HIDDevices.value($0,"MaxFeatureReportSize") == 90 && (deviceID == nil || HIDDevices.identity($0) == deviceID)
        }
        guard candidates.count == 1, let d = candidates.first else {
            throw RazerError.unavailable(candidates.isEmpty ? "No supported configuration interface. Connect the USB cable or receiver." : "Select a device; more than one configuration interface is connected.")
        }
        device = d; wireless = HIDDevices.value(d,"ProductID") == 0x027B
        let result = IOHIDDeviceOpen(d, 0)
        guard result == kIOReturnSuccess else { throw Self.error(result) }
    }
    deinit { IOHIDDeviceClose(device, 0) }
    private static func error(_ result: IOReturn) -> RazerError {
        if result == kIOReturnNotPermitted { return .transport("Input Monitoring is required. Enable the hosting app in System Settings, then relaunch it.") }
        if result == kIOReturnNotAttached || result == kIOReturnNoDevice { return .unavailable("Keyboard disconnected") }
        return .transport(String(format:"HID operation failed: 0x%08X",result))
    }
    public func send(_ request: [UInt8]) throws {
        guard request.count == 90 else { throw RazerError.invalidRequest }
        var out = request
        let set = out.withUnsafeMutableBufferPointer { IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, $0.baseAddress!, 90) }
        guard set == kIOReturnSuccess else { throw Self.error(set) }
    }
    public func exchange(_ request: [UInt8]) throws -> [UInt8] {
        guard request.count == 90 else { throw RazerError.invalidRequest }
        var out = request
        let set = out.withUnsafeMutableBufferPointer { IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, $0.baseAddress!, 90) }
        guard set == kIOReturnSuccess else { throw Self.error(set) }
        Thread.sleep(forTimeInterval: wireless ? 0.12 : 0.08)
        var response = [UInt8](repeating: 0, count: 90)
        var length: CFIndex = 90
        let get = response.withUnsafeMutableBufferPointer { IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, $0.baseAddress!, &length) }
        guard get == kIOReturnSuccess else { throw Self.error(get) }
        guard (0...90).contains(length) else { throw RazerError.malformedResponse("report size") }
        return Array(response[0..<length])
    }
}

/// Routes packets through the helper, which owns the control interface.
public final class HelperTransport: ReportTransport {
    private let client: HelperClient
    public let wireless: Bool
    public init(client: HelperClient, wireless: Bool) { self.client = client; self.wireless = wireless }
    public func exchange(_ request: [UInt8]) throws -> [UInt8] {
        let reply = try client.exchange(.hardware(request))
        guard let packet = reply.packet else { throw RazerError.transport("Helper returned no data") }
        return packet
    }
}

public struct HardwareSnapshot: Codable, Sendable {
    public var readings: [String:String] = [:]
    public var errors: [String:String] = [:]
    public init() {}
}
public enum Hardware {
    /// Prefers the helper when it is running and has the keyboard; otherwise talks
    /// to the control interface directly (no helper installed, or hardware-only use).
    public static func session(deviceID: String?) throws -> RazerSession {
        let client = HelperClient()
        if let reply = try? client.exchange(.status), reply.hardwareAvailable, deviceID == nil || reply.deviceID == deviceID {
            // The receiver also reports a USB transport, so the product ID decides.
            // Device IDs start with the decimal product ID.
            let wireless = reply.deviceID.map(HIDDevices.isReceiver) ?? false
            return RazerSession(transport: HelperTransport(client: client, wireless: wireless), wireless: wireless)
        }
        let transport = try HIDTransport(deviceID:deviceID)
        return RazerSession(transport:transport, wireless:transport.wireless)
    }
    public static func read(deviceID: String?) throws -> HardwareSnapshot {
        let session = try session(deviceID:deviceID)
        var snapshot = HardwareSnapshot()
        let commands: [(String,RazerCommand)] = [("Firmware",.firmware),("Mode",.mode),("Brightness (raw)",.brightness),("Battery (raw, unvalidated)",.battery),("Charging",.charging),("Idle seconds",.idle)]
        for (name,command) in commands {
            do {
                let args = try session.perform(command)
                switch name {
                case "Firmware": snapshot.readings[name] = "\(args[0]).\(args[1])"
                case "Mode": snapshot.readings[name] = args[0] == 0 ? "Normal" : "\(args[0])"
                case "Brightness (raw)": snapshot.readings[name] = "\(args[2])"
                case "Charging": snapshot.readings[name] = args[1] == 1 ? "Yes" : "No"
                case "Idle seconds": snapshot.readings[name] = "\(Int(args[0]) * 256 + Int(args[1]))"
                default: snapshot.readings[name] = "\(args[1])"
                }
            } catch { snapshot.errors[name] = error.localizedDescription }
        }
        return snapshot
    }
}
