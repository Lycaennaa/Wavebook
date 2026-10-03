import Foundation

/// A track and the source that started its current playback.
public struct PlaybackTrackContext: Equatable, Sendable {
    /// Track currently being played.
    public let track: Track
    /// History source for the current track.
    public let source: ListeningPlaybackSource

    /// Creates a current-playback context.
    public init(track: Track, source: ListeningPlaybackSource) {
        self.track = track
        self.source = source
    }
}
