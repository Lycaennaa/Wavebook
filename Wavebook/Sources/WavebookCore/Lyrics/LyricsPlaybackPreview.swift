import Foundation

/// Semantic playback state for synchronized or plain lyrics.
public enum LyricsPlaybackPreview: Equatable, Sendable {
    case unavailable
    case loading
    case waiting(firstLine: LRCLyricLine, timeUntil: TimeInterval)
    case current(LRCLyricLine)
    case untimed(LRCLyricLine)
    case instrumental

    /// Creates playback state for the supplied lyric position.
    public init(lyrics: LRCLyrics?, elapsed: TimeInterval) {
        guard let lyrics, let firstLine = lyrics.lines.first else {
            self = .unavailable
            return
        }

        if lyrics.isInstrumental {
            self = .instrumental
            return
        }

        if let index = lyrics.lineIndex(at: elapsed) {
            self = .current(lyrics.lines[index])
            return
        }

        guard lyrics.isSynchronized else {
            self = .untimed(firstLine)
            return
        }

        guard firstLine.time.isFinite,
              elapsed.isFinite,
              firstLine.time > elapsed else {
            self = .unavailable
            return
        }
        self = .waiting(firstLine: firstLine, timeUntil: firstLine.time - elapsed)
    }

    /// Whether a timestamped lyric is active at the position.
    public var isCurrent: Bool {
        if case .current = self { return true }
        return false
    }
}
