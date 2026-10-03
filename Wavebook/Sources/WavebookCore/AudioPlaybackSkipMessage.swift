import Foundation

/// User-facing playback skip messages.
public struct AudioPlaybackSkipMessage {
    /// Describes detected leading and trailing silence.
    public static func detected(leadingDuration: TimeInterval, trailingDuration: TimeInterval) -> String? {
        var segments = [String]()
        if leadingDuration > 0.01 {
            segments.append("\(durationString(leadingDuration)) at start")
        }
        if trailingDuration > 0.01 {
            segments.append("\(durationString(trailingDuration)) at end")
        }
        guard !segments.isEmpty else { return nil }
        return "Silence detected: \(segments.joined(separator: " and "))"
    }

    /// Describes completed trailing-silence skipping.
    public static func completed(trailingDuration: TimeInterval) -> String? {
        guard trailingDuration > 0.01 else { return nil }
        return "Skipped \(durationString(trailingDuration)) of trailing silence"
    }

    private static func durationString(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded())
        if totalSeconds >= 60 {
            return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
        }
        return String(format: "%.1fs", duration)
    }
}
