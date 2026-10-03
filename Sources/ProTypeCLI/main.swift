import Foundation
import IOKit.hid
import KeyboardCore
import KeyboardHID

func printJSON<T:Encodable>(_ value:T) throws {
    let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
    print(String(decoding:try encoder.encode(value),as:UTF8.self))
}
var arguments=Array(CommandLine.arguments.dropFirst())
var deviceID:String?
if let index=arguments.firstIndex(of:"--device"), arguments.count > index+1 {
    deviceID=arguments[index+1]; arguments.removeSubrange(index...index+1)
}
do {
    switch arguments.first ?? "help" {
    case "list": try printJSON(HIDDevices.list())
    case "probe": try printJSON(Hardware.read(deviceID:deviceID))
    case "permission": print(HIDDevices.permissionGranted() ? "Input Monitoring granted" : "Input Monitoring required")
    case "helper-status":
        try printJSON(HelperClient().exchange(.status))
    case "configure":
        guard arguments.count == 2 else { throw RazerError.invalidRequest }
        let settings=try ProfileStore.decode(Data(contentsOf:URL(fileURLWithPath:arguments[1])))
        try printJSON(HelperClient().exchange(.configure(HelperConfiguration(enabled:settings.remappingEnabled,deviceID:settings.selectedDevice,settings:settings))))
    case "enable", "disable":
        var settings=try ProfileStore.load(); settings.remappingEnabled = arguments[0] == "enable"
        try ProfileStore.save(settings)
        try printJSON(HelperClient().exchange(.configure(HelperConfiguration(enabled:settings.remappingEnabled,deviceID:settings.selectedDevice,settings:settings))))
    case "brightness":
        guard arguments.count == 2, let value=UInt8(arguments[1]) else { throw RazerError.invalidRequest }
        let s=try Hardware.session(deviceID:deviceID)
        _ = try s.perform(.brightness(value)); print("Readback:",try s.perform(.brightness)[2])
    case "effect":
        guard arguments.count == 2, let effect=LightingEffect(rawValue:arguments[1]) else { throw RazerError.invalidRequest }
        _ = try Hardware.session(deviceID:deviceID).perform(.effect(effect)); print("Effect accepted; verify visually.")
    case "idle":
        guard arguments.count == 2, let seconds=Int(arguments[1]) else { throw RazerError.invalidRequest }
        let s=try Hardware.session(deviceID:deviceID); _ = try s.perform(.idle(seconds:seconds))
        let a=try s.perform(.idle); print("Readback seconds:",Int(a[0])*256+Int(a[1]))
    case "roundtrip-brightness":
        let s=try Hardware.session(deviceID:deviceID)
        let original=try s.perform(.brightness)[2]
        let target:UInt8 = original == 0 ? 1 : original-1
        do {
            _ = try s.perform(.brightness(target))
            guard try s.perform(.brightness)[2] == target else { throw RazerError.malformedResponse("brightness readback") }
        } catch {
            _ = try? s.perform(.brightness(original)); throw error
        }
        _ = try s.perform(.brightness(original))
        guard try s.perform(.brightness)[2] == original else { throw RazerError.malformedResponse("restoration") }
        print("PASS: brightness \(original) → \(target) → \(original); original restored.")
    case "roundtrip-idle":
        let s=try Hardware.session(deviceID:deviceID)
        let a=try s.perform(.idle)
        let original=Int(a[0])*256+Int(a[1])
        let restore=try RazerCommand.idle(seconds:original)
        let target=original == 900 ? 840 : 900
        do {
            _ = try s.perform(.idle(seconds:target))
            let b=try s.perform(.idle)
            guard Int(b[0])*256+Int(b[1]) == target else { throw RazerError.malformedResponse("idle readback") }
        } catch { _ = try? s.perform(restore); throw error }
        _ = try s.perform(restore)
        let b=try s.perform(.idle)
        guard Int(b[0])*256+Int(b[1]) == original else { throw RazerError.malformedResponse("idle restoration") }
        print("PASS: idle \(original) → \(target) → \(original); original restored.")
    case "validate":
        guard arguments.count == 2 else { throw RazerError.invalidRequest }
        _ = try ProfileStore.decode(Data(contentsOf:URL(fileURLWithPath:arguments[1]))); print("Valid settings")
    case "watch":
        let seconds = arguments.count > 1 ? min(60,max(1,Double(arguments[1]) ?? 10)) : 10
        let devices=HIDDevices.enumerate().filter { deviceID == nil || HIDDevices.identity($0) == deviceID }
        guard !devices.isEmpty else { throw RazerError.unavailable("Connect the keyboard") }
        print("Explicit input diagnostic for \(seconds) seconds. Press only test keys; no output is saved.")
        for d in devices {
            guard IOHIDDeviceOpen(d,0) == 0 else { throw RazerError.unavailable("Input Monitoring required") }
            IOHIDDeviceRegisterInputValueCallback(d,{ _,_,_,value in
                let e=IOHIDValueGetElement(value)
                print(String(format:"page=%04x usage=%04x value=%ld",IOHIDElementGetUsagePage(e),IOHIDElementGetUsage(e),IOHIDValueGetIntegerValue(value)))
            },nil)
            IOHIDDeviceScheduleWithRunLoop(d,CFRunLoopGetCurrent(),CFRunLoopMode.defaultMode.rawValue)
        }
        CFRunLoopRunInMode(.defaultMode,seconds,false)
        for d in devices { IOHIDDeviceClose(d,0); IOHIDDeviceUnscheduleFromRunLoop(d,CFRunLoopGetCurrent(),CFRunLoopMode.defaultMode.rawValue) }
    default:
        print("""
        protype list | probe | permission | helper-status | validate FILE
        protype enable | disable | configure SETTINGS.json   (pushes your settings to the helper)
        protype brightness RAW_0_255 | effect off|staticWhite|breathing | idle SECONDS
        protype roundtrip-brightness | roundtrip-idle | watch [SECONDS]
        Add --device ID when multiple devices are connected. Writes affect real hardware.
        """)
    }
} catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
