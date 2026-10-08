import XCTest

final class OutputDeviceVolumeRoutingTests: XCTestCase {
    func testSelectedOutputDeviceTakesPrecedenceOverSystemDefault() {
        XCTAssertEqual(
            OutputDeviceVolumeRouting.outputDeviceUID(selectedOutputUID: "selected", defaultOutputUID: "system"),
            "selected"
        )
    }

    func testSystemDefaultOwnsVolumeWhenNoOutputIsSelected() {
        XCTAssertEqual(
            OutputDeviceVolumeRouting.outputDeviceUID(selectedOutputUID: nil, defaultOutputUID: "system"),
            "system"
        )
    }

    func testMissingSelectedAndDefaultOutputsHaveNoVolumeOwner() {
        XCTAssertNil(OutputDeviceVolumeRouting.outputDeviceUID(selectedOutputUID: nil, defaultOutputUID: nil))
    }
}
