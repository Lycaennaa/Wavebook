import XCTest

final class BluetoothDisconnectResumeTrackerTests: XCTestCase {
    func testDoesNotCorrelatePauseBeforeDisconnect() {
        var tracker = BluetoothDisconnectResumeTracker()

        XCTAssertFalse(tracker.recordRemotePause(at: 10))
        tracker.recordBluetoothToNonBluetoothOutputChange(at: 10.1)
    }

    func testCorrelatesDisconnectBeforeRemotePause() {
        var tracker = BluetoothDisconnectResumeTracker()

        tracker.recordBluetoothToNonBluetoothOutputChange(at: 10)
        XCTAssertTrue(tracker.recordRemotePause(at: 10.1))
    }

    func testDoesNotCorrelatePauseOutsideWindow() {
        var tracker = BluetoothDisconnectResumeTracker()

        tracker.recordBluetoothToNonBluetoothOutputChange(at: 10)
        XCTAssertFalse(tracker.recordRemotePause(at: 10.51))
    }

    func testPauseWithoutPendingDisconnectDoesNotResume() {
        var tracker = BluetoothDisconnectResumeTracker()

        XCTAssertFalse(tracker.recordRemotePause(at: 10))
        tracker.recordBluetoothToNonBluetoothOutputChange(at: 10.1)
    }

    func testResetClearsPendingEvents() {
        var tracker = BluetoothDisconnectResumeTracker()
        tracker.recordBluetoothToNonBluetoothOutputChange(at: 10)

        tracker.reset()

        XCTAssertFalse(tracker.recordRemotePause(at: 10.1))
    }
    func testDisconnectRequiresBluetoothDeviceToBeUnavailable() {
        XCTAssertTrue(
            BluetoothDisconnectDetection.isBluetoothDisconnect(
                activeOutputIsBluetooth: true,
                defaultOutputIsBluetooth: false,
                activeOutputDeviceIsAvailable: false,
                reconciledOutputIsBluetooth: false
            )
        )
        XCTAssertFalse(
            BluetoothDisconnectDetection.isBluetoothDisconnect(
                activeOutputIsBluetooth: true,
                defaultOutputIsBluetooth: false,
                activeOutputDeviceIsAvailable: true,
                reconciledOutputIsBluetooth: false
            )
        )
        XCTAssertFalse(
            BluetoothDisconnectDetection.isBluetoothDisconnect(
                activeOutputIsBluetooth: true,
                defaultOutputIsBluetooth: false,
                activeOutputDeviceIsAvailable: nil,
                reconciledOutputIsBluetooth: false
            )
        )
    }

    func testDisconnectRequiresReconciledNonBluetoothOutput() {
        XCTAssertFalse(
            BluetoothDisconnectDetection.isBluetoothDisconnect(
                activeOutputIsBluetooth: true,
                defaultOutputIsBluetooth: false,
                activeOutputDeviceIsAvailable: false,
                reconciledOutputIsBluetooth: true
            )
        )
        XCTAssertFalse(
            BluetoothDisconnectDetection.isBluetoothDisconnect(
                activeOutputIsBluetooth: true,
                defaultOutputIsBluetooth: false,
                activeOutputDeviceIsAvailable: false,
                reconciledOutputIsBluetooth: nil
            )
        )
    }

    func testDoesNotCorrelateOutOfOrderPauseOutsideWindow() {
        var outputFirst = BluetoothDisconnectResumeTracker()
        outputFirst.recordBluetoothToNonBluetoothOutputChange(at: 10)
        XCTAssertFalse(outputFirst.recordRemotePause(at: 9.25))
        XCTAssertTrue(outputFirst.recordRemotePause(at: 10.25))

        var pauseFirst = BluetoothDisconnectResumeTracker()
        XCTAssertFalse(pauseFirst.recordRemotePause(at: 9.25))
        pauseFirst.recordBluetoothToNonBluetoothOutputChange(at: 10)
        XCTAssertTrue(pauseFirst.recordRemotePause(at: 10.25))
    }

    func testDoesNotCorrelatePauseAfterTheTightWindow() {
        var tracker = BluetoothDisconnectResumeTracker()

        tracker.recordBluetoothToNonBluetoothOutputChange(at: 10)
        XCTAssertFalse(tracker.recordRemotePause(at: 10.51))
    }

    func testCorrelatesEventTimestampWhenHandlerIsDelayed() {
        var tracker = BluetoothDisconnectResumeTracker()
        tracker.recordBluetoothToNonBluetoothOutputChange(at: 10)

        let pauseEventTimestamp: TimeInterval = 10.25
        let handlerTimestamp: TimeInterval = 11
        XCTAssertGreaterThan(handlerTimestamp - pauseEventTimestamp, 0.5)
        XCTAssertTrue(tracker.recordRemotePause(at: pauseEventTimestamp))
    }

    func testNormalizesRemoteTimestampFromSystemUptime() {
        XCTAssertEqual(
            MediaPlayerCommandTimestamp.systemUptime(
                from: 99.75,
                receivedAtUptime: 100,
                receivedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            99.75
        )
    }

    func testNormalizesRemoteTimestampFromUnixAndReferenceDateClocks() {
        let receivedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let unixTimestamp = receivedAt.timeIntervalSince1970 - 0.25
        let referenceTimestamp = receivedAt.timeIntervalSinceReferenceDate - 0.25

        XCTAssertEqual(
            MediaPlayerCommandTimestamp.systemUptime(
                from: unixTimestamp,
                receivedAtUptime: 100,
                receivedAt: receivedAt
            ),
            99.75
        )
        XCTAssertEqual(
            MediaPlayerCommandTimestamp.systemUptime(
                from: referenceTimestamp,
                receivedAtUptime: 100,
                receivedAt: receivedAt
            ),
            99.75
        )
    }

    func testRejectsRemoteTimestampOutsideKnownClockDomains() {
        XCTAssertNil(
            MediaPlayerCommandTimestamp.systemUptime(
                from: 1_000_000,
                receivedAtUptime: 100,
                receivedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
    }

}
