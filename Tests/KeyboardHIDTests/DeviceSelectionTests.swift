import XCTest
@testable import KeyboardHID

final class DeviceSelectionTests: XCTestCase {
    let usb = DeviceInfo(id: "631:USB:1", product: "Pro Type Ultra", productID: 0x277, transport: "USB", interfaces: 3, hasControlInterface: true)
    let dongle = DeviceInfo(id: "635:USB:2", product: "Pro Type Ultra", productID: 0x27B, transport: "USB", interfaces: 3, hasControlInterface: true)
    let bluetooth = DeviceInfo(id: "9:Bluetooth:x", product: "Pro Type Ultra", productID: 9, transport: "Bluetooth", interfaces: 1, hasControlInterface: false)

    func testPrefersWiredThenReceiverThenBluetooth() {
        XCTAssertEqual(HIDDevices.preferred([bluetooth, dongle, usb], override: nil)?.id, usb.id)
        XCTAssertEqual(HIDDevices.preferred([bluetooth, dongle], override: nil)?.id, dongle.id)
        XCTAssertEqual(HIDDevices.preferred([bluetooth], override: nil)?.id, bluetooth.id)
        XCTAssertNil(HIDDevices.preferred([], override: nil))
    }
    func testOverrideWinsWhenPresentAndFallsBackWhenAbsent() {
        XCTAssertEqual(HIDDevices.preferred([usb, dongle], override: dongle.id)?.id, dongle.id)
        XCTAssertEqual(HIDDevices.preferred([usb], override: "missing")?.id, usb.id)
    }
    func testReceiverIsRecognizedByProductIDNotTransport() {
        XCTAssertTrue(HIDDevices.isReceiver(deviceID: dongle.id))
        XCTAssertFalse(HIDDevices.isReceiver(deviceID: usb.id))
        XCTAssertFalse(HIDDevices.isReceiver(deviceID: bluetooth.id))
    }
    func testControlInterfaceIsNotInput() {
        XCTAssertTrue(HIDDevices.isInputInterface(usagePairs: [(1, 6)]))
        XCTAssertTrue(HIDDevices.isInputInterface(usagePairs: [(1, 6), (12, 1), (1, 0x80), (1, 0)]))
        // Interface 2 on this keyboard: mouse/pointer usages plus the 90-byte vendor feature report.
        XCTAssertFalse(HIDDevices.isInputInterface(usagePairs: [(1, 2), (1, 1)]))
        XCTAssertFalse(HIDDevices.isInputInterface(usagePairs: []))
    }
}
