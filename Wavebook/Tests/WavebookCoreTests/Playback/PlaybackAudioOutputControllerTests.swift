import WavebookCore
import XCTest

@MainActor
final class PlaybackAudioOutputControllerTests: XCTestCase {
    func testReconciliationReplacesOrClearsBluetoothClassification() {
        let controller = PlaybackAudioOutputController(audioPlayer: AudioFilePlayer())

        controller.reconcileOutputDevice(id: 1, isBluetooth: true)
        XCTAssertEqual(controller.isBluetoothOutput, true)
        XCTAssertEqual(controller.activeOutputDeviceID, 1)

        controller.reconcileOutputDevice(id: 2, isBluetooth: false)
        XCTAssertEqual(controller.isBluetoothOutput, false)
        XCTAssertEqual(controller.activeOutputDeviceID, 2)

        controller.reconcileOutputDevice(id: nil, isBluetooth: nil)
        XCTAssertNil(controller.isBluetoothOutput)
    }
}
