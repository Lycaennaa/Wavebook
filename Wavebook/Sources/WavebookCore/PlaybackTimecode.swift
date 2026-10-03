import Foundation

/// Parses and formats playback timecodes.
public enum PlaybackTimecode {
    /// Parses a playback timecode into seconds.
    public nonisolated static func parse(_ text: String) -> TimeInterval? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count) else { return nil }
        let numbers = components.compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard numbers.count == components.count,
              numbers.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            return nil
        }

        let seconds: TimeInterval
        switch numbers.count {
        case 1:
            seconds = numbers[0]
        case 2:
            guard numbers[1] < 60 else { return nil }
            seconds = numbers[0] * 60 + numbers[1]
        case 3:
            guard numbers[1] < 60, numbers[2] < 60 else { return nil }
            seconds = numbers[0] * 3_600 + numbers[1] * 60 + numbers[2]
        default:
            return nil
        }
        guard seconds.isFinite else { return nil }
        return seconds
    }

    /// Formats seconds as a playback timecode.
    public nonisolated static func string(
        from seconds: TimeInterval,
        includingFractionalSeconds: Bool = true
    ) -> String {
        let maximumCentiseconds = Int64.max - 1_000
        let maximum = Double(maximumCentiseconds) / 100
        let safeSeconds = min(max(seconds.isFinite ? seconds : 0, 0), maximum)
        let totalCentiseconds = min(Int64((safeSeconds * 100).rounded()), maximumCentiseconds)
        let totalSeconds = includingFractionalSeconds
            ? totalCentiseconds / 100
            : totalCentiseconds / 100 + (totalCentiseconds % 100 >= 50 ? 1 : 0)
        let minutes = (totalSeconds / 60) % 60
        let wholeSeconds = totalSeconds % 60
        let base: String
        if totalSeconds >= 3_600 {
            base = "\(totalSeconds / 3_600):\(twoDigits(minutes)):\(twoDigits(wholeSeconds))"
        } else {
            base = "\(totalSeconds / 60):\(twoDigits(wholeSeconds))"
        }
        guard includingFractionalSeconds else { return base }
        let fraction = includingFractionalSeconds ? totalCentiseconds % 100 : 0
        return fraction == 0 ? base : "\(base).\(twoDigits(fraction))"
    }

    private nonisolated static func twoDigits(_ value: Int64) -> String {
        String(format: "%02d", Int(value))
    }
}
