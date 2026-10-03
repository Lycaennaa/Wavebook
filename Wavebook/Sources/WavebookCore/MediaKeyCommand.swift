import Foundation

/// A normalized media-key playback command.
public enum MediaKeyCommand: Equatable, Sendable {
    /// Toggles playback.
    case togglePlayPause
    /// Starts playback.
    case play
    /// Pauses playback.
    case pause
    /// Advances to the next track.
    case nextTrack
    /// Returns to the previous track.
    case previousTrack
}

/// Parses system media-key event payloads.
public enum MediaKeyEventParser {
    /// Converts an encoded media-key payload into a command.
    public static func command(data1: Int) -> MediaKeyCommand? {
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyState = (data1 & 0x0000FF00) >> 8
        let isRepeat = data1 & 0x1 != 0
        guard keyState == 0x0A, !isRepeat else { return nil }

        switch keyCode {
        case 16:
            return .togglePlayPause
        case 17, 19:
            return .nextTrack
        case 18, 20:
            return .previousTrack
        default:
            return nil
        }
    }
}
