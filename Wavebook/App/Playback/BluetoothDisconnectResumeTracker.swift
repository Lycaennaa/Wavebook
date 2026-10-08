import Foundation

/// Correlates a media pause shortly after a confirmed Bluetooth output loss.
struct BluetoothDisconnectResumeTracker: Sendable {
    private static let correlationWindow: TimeInterval = 0.5

    private var outputChangeTimestamp: TimeInterval?

    /// Creates a tracker with a short event-correlation window.
    init() {}

    /// Returns true when a Bluetooth output change was recently recorded.
    mutating func recordRemotePause(at timestamp: TimeInterval) -> Bool {
        guard let outputChangeTimestamp else { return false }
        let difference = timestamp - outputChangeTimestamp
        guard difference >= 0 else { return false }
        self.outputChangeTimestamp = nil
        guard difference <= Self.correlationWindow else { return false }
        return true
    }

    /// Records a confirmed Bluetooth output loss.
    mutating func recordBluetoothToNonBluetoothOutputChange(at timestamp: TimeInterval) {
        outputChangeTimestamp = timestamp
    }

    /// Clears any pending disconnect event.
    mutating func reset() {
        outputChangeTimestamp = nil
    }
}

enum BluetoothDisconnectDetection {
    static func isBluetoothDisconnect(
        activeOutputIsBluetooth: Bool,
        defaultOutputIsBluetooth: Bool?,
        activeOutputDeviceIsAvailable: Bool?,
        reconciledOutputIsBluetooth: Bool?
    ) -> Bool {
        activeOutputIsBluetooth
            && defaultOutputIsBluetooth == false
            && activeOutputDeviceIsAvailable == false
            && reconciledOutputIsBluetooth == false
    }
}

enum MediaPlayerCommandTimestamp {
    private static let maximumEventAge: TimeInterval = 60

    static func systemUptime(
        from eventTimestamp: TimeInterval,
        receivedAtUptime: TimeInterval,
        receivedAt: Date
    ) -> TimeInterval? {
        let clockOffsets = [
            0,
            receivedAt.timeIntervalSince1970 - receivedAtUptime,
            receivedAt.timeIntervalSinceReferenceDate - receivedAtUptime
        ]
        return clockOffsets
            .map { eventTimestamp - $0 }
            .filter {
                $0.isFinite
                    && $0 <= receivedAtUptime
                    && receivedAtUptime - $0 <= Self.maximumEventAge
            }
            .max()
    }
}
