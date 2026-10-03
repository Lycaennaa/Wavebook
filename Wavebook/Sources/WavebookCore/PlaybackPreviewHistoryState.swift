import Foundation

/// Tracks pending playback-preview analysis and restoration state.
public enum PlaybackPreviewHistoryState: Equatable, Sendable {
    /// A track and optional position waiting to be restored.
    public struct Pending: Equatable, Sendable {
        /// Track awaiting restoration.
        public let track: Track
        /// Position to restore, if known.
        public let position: TimeInterval?

        /// Creates a pending preview value.
        public init(track: Track, position: TimeInterval?) {
            self.track = track
            self.position = position
        }
    }

    /// No preview restoration is pending.
    case none
    /// Waiting for silence analysis before restoring a track.
    case awaitingAnalysis(Track)
    /// Waiting to restore a track after previewing it.
    case awaitingPreview(Track, position: TimeInterval?)

    /// Marks a track as waiting for analysis.
    public mutating func setAwaitingAnalysis(for track: Track) {
        self = .awaitingAnalysis(track)
    }

    /// Resolves analysis and returns a pending restoration when ready.
    @discardableResult
    public mutating func resolveAnalysis(
        successfully: Bool,
        position: TimeInterval?,
        whilePreviewing: Bool
    ) -> Pending? {
        guard case let .awaitingAnalysis(track) = self else { return nil }
        let pending = Pending(track: track, position: successfully ? position : nil)
        if whilePreviewing {
            self = .awaitingPreview(track, position: pending.position)
            return nil
        }
        self = .none
        return pending
    }

    /// Takes a preview waiting for restoration.
    @discardableResult
    public mutating func takeAwaitingPreview() -> Pending? {
        guard case let .awaitingPreview(track, position) = self else { return nil }
        self = .none
        return Pending(track: track, position: position)
    }

    /// Takes whichever pending restoration is available.
    @discardableResult
    public mutating func takePending() -> Pending? {
        switch self {
        case .none:
            return nil
        case let .awaitingAnalysis(track):
            self = .none
            return Pending(track: track, position: nil)
        case let .awaitingPreview(track, position):
            self = .none
            return Pending(track: track, position: position)
        }
    }

    /// Clears all pending restoration state.
    public mutating func clear() {
        self = .none
    }
}

/// Keeps pending preview state and its history source together.
public struct PlaybackPreviewHistoryContext: Equatable, Sendable {
    /// A pending preview restoration with its history source.
    public struct Pending: Equatable, Sendable {
        /// Track awaiting restoration.
        public let track: Track
        /// Position to restore, if known.
        public let position: TimeInterval?
        /// Source that started the track.
        public let source: ListeningPlaybackSource
    }

    private var state: PlaybackPreviewHistoryState = .none
    private var source: ListeningPlaybackSource?

    /// Creates an empty preview-history context.
    public init() {}

    /// Whether analysis or preview restoration is pending.
    public var hasPending: Bool {
        if case .none = state { return false }
        return true
    }

    /// Marks a track as waiting for analysis.
    public mutating func setAwaitingAnalysis(
        for track: Track,
        source: ListeningPlaybackSource
    ) {
        self.source = source
        state.setAwaitingAnalysis(for: track)
    }

    /// Resolves analysis and returns a source-aware pending restoration when ready.
    @discardableResult
    public mutating func resolveAnalysis(
        successfully: Bool,
        position: TimeInterval?,
        whilePreviewing: Bool
    ) -> Pending? {
        guard let pending = state.resolveAnalysis(
            successfully: successfully,
            position: position,
            whilePreviewing: whilePreviewing
        ) else { return nil }
        return take(pending)
    }

    /// Takes a preview waiting for restoration.
    @discardableResult
    public mutating func takeAwaitingPreview() -> Pending? {
        guard let pending = state.takeAwaitingPreview() else { return nil }
        return take(pending)
    }

    /// Takes whichever pending restoration is available.
    @discardableResult
    public mutating func takePending() -> Pending? {
        guard let pending = state.takePending() else { return nil }
        return take(pending)
    }

    /// Clears pending preview state and its source.
    public mutating func clear() {
        state.clear()
        source = nil
    }

    private mutating func take(_ pending: PlaybackPreviewHistoryState.Pending) -> Pending? {
        guard let source else {
            clear()
            return nil
        }
        self.source = nil
        return Pending(track: pending.track, position: pending.position, source: source)
    }
}
