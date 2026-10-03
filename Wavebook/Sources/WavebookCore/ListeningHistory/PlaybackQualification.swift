import Foundation

/// Origin of a listening event.
public enum ListeningPlaybackSourceKind: String, CaseIterable, Codable, Sendable {
    /// Library playback.
    case library
    /// Playlist playback.
    case playlist
}

/// Source metadata attached to a listening event.
public struct ListeningPlaybackSource: Equatable, Hashable, Sendable {
    /// Source kind.
    public let kind: ListeningPlaybackSourceKind
    /// Persistent source identifier, if supplied.
    public let persistentID: Int64?
    /// Display name of the source, if supplied.
    public let sourceName: String?

    /// Creates source metadata.
    public init(
        kind: ListeningPlaybackSourceKind,
        persistentID: Int64? = nil,
        sourceName: String? = nil
    ) {
        self.kind = kind
        self.persistentID = persistentID
        self.sourceName = sourceName?.listeningTrimmedOrNil
    }
}

/// Reason a listening event ended.
public enum ListeningEventEndReason: String, CaseIterable, Codable, Sendable {
    /// Playback reached natural completion.
    case naturalCompletion
    /// Playback advanced to the next track.
    case next
    /// Playback returned to the previous track.
    case previous
    /// Another track was selected.
    case differentTrackSelection
    /// The same track was restarted.
    case sameTrackRestart
    /// Playback was stopped.
    case stop
    /// The app terminated.
    case appTermination
    /// Playback failed and could not recover.
    case unrecoverablePlaybackError
    /// Private mode changed during playback.
    case privateModeBoundary
    /// The event was abandoned.
    case abandoned

    /// Whether the reason represents explicit track departure.
    public var isExplicitTrackDeparture: Bool {
        switch self {
        case .next, .previous, .differentTrackSelection:
            return true
        case .naturalCompletion, .sameTrackRestart, .stop, .appTermination,
             .unrecoverablePlaybackError, .privateModeBoundary, .abandoned:
            return false
        }
    }
}

/// Threshold constants for listening history qualification.
public enum ListeningHistoryThresholds {
    /// Maximum play threshold, in seconds.
    public static let maximumPlaySeconds: TimeInterval = 30
    /// Fraction of known duration required for a play.
    public static let knownDurationFraction = 0.5
    /// Minimum listened seconds for a skip.
    public static let skipSeconds: TimeInterval = 5

    /// Returns the play threshold for a duration.
    public static func playThreshold(for openedDuration: TimeInterval) -> TimeInterval {
        ListeningPlayThreshold(openedDuration: openedDuration).seconds
    }

    /// Returns whether a departure qualifies as a skip.
    public static func qualifiesSkip(
        after actualListenedSeconds: TimeInterval,
        endReason: ListeningEventEndReason
    ) -> Bool {
        endReason.isExplicitTrackDeparture
            && actualListenedSeconds.isFinite
            && actualListenedSeconds >= skipSeconds
    }
}

/// Play-qualification threshold for one listening session.
public struct ListeningPlayThreshold: Equatable, Sendable {
    /// Threshold in seconds.
    public let seconds: TimeInterval
    /// Whether the threshold used known media duration.
    public let usesKnownDuration: Bool

    /// Creates a threshold from opened media duration.
    public init(openedDuration: TimeInterval) {
        if openedDuration.isFinite, openedDuration > 0 {
            seconds = min(
                ListeningHistoryThresholds.maximumPlaySeconds,
                openedDuration * ListeningHistoryThresholds.knownDurationFraction
            )
            usesKnownDuration = true
        } else {
            seconds = ListeningHistoryThresholds.maximumPlaySeconds
            usesKnownDuration = false
        }
    }

    /// Returns whether enough listening time has elapsed.
    public func isReached(after actualListenedSeconds: TimeInterval) -> Bool {
        actualListenedSeconds.isFinite && actualListenedSeconds >= seconds
    }
}

/// Mutable qualification state for one listening session.
public struct ListeningQualificationState: Equatable, Sendable {
    /// Threshold used by the session.
    public let threshold: ListeningPlayThreshold
    /// Whether the session has qualified as a play.
    public private(set) var didQualify: Bool

    /// Creates qualification state from opened media duration.
    public init(openedDuration: TimeInterval) {
        self.init(threshold: ListeningPlayThreshold(openedDuration: openedDuration))
    }

    /// Creates qualification state from a threshold.
    public init(threshold: ListeningPlayThreshold) {
        self.threshold = threshold
        didQualify = false
    }

    /// Updates qualification state and returns whether it newly qualified.
    @discardableResult
    public mutating func update(actualListenedSeconds: TimeInterval) -> Bool {
        guard !didQualify, threshold.isReached(after: actualListenedSeconds) else {
            return false
        }

        didQualify = true
        return true
    }
}
