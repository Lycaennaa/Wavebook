@testable import WavebookCore
import XCTest

final class OutputDeviceTests: XCTestCase {
    func testDeviceOrderingUsesDefaultLocalizedNameRawNameAndUIDTieBreaks() {
        let devices = [
            OutputDevice(id: 1, uid: "uid-z", name: "Echo", isDefault: false),
            OutputDevice(id: 2, uid: "uid-y", name: "echo", isDefault: false),
            OutputDevice(id: 3, uid: "uid-a", name: "Echo", isDefault: false),
            OutputDevice(id: 4, uid: "uid-default", name: "Zulu", isDefault: true),
            OutputDevice(id: 5, uid: "uid-alpha", name: "Alpha", isDefault: false)
        ]

        let sorted = devices.sorted(by: OutputDeviceProvider.devicePrecedes)

        XCTAssertEqual(sorted.map(\.id), [4, 5, 3, 1, 2])
    }

    func testBluetoothTransportFlagIsPreserved() {
        let bluetooth = OutputDevice(id: 1, uid: "bluetooth", name: "Headphones", isDefault: false, isBluetooth: true)
        let wired = OutputDevice(id: 2, uid: "wired", name: "Headphones", isDefault: false, isBluetooth: false)
        let unknown = OutputDevice(id: 3, uid: "unknown", name: "Unknown", isDefault: false, isBluetooth: nil)

        XCTAssertEqual(bluetooth.isBluetooth, true)
        XCTAssertEqual(wired.isBluetooth, false)
        XCTAssertNil(unknown.isBluetooth)
    }
}
