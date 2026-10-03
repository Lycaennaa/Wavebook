import Foundation

/// Errors raised while discovering a library root.
public enum LibraryScannerError: Error, LocalizedError, Sendable {
    /// The root could not be enumerated.
    case cannotEnumerate(URL)
    /// The root exceeded the filesystem-entry traversal limit.
    case tooManyDiscoveredEntries(URL, limit: Int)
    /// The root exceeded the audio-file limit.
    case tooManyAudioFiles(URL, limit: Int)
    /// The root exceeded the lyric-file limit.
    case tooManyLyricFiles(URL, limit: Int)
    /// Too many unreadable paths were encountered to reconcile safely.
    case tooManyPreservedFailurePaths(URL, limit: Int)

    public var errorDescription: String? {
        switch self {
        case let .tooManyDiscoveredEntries(root, limit):
            return "Scan of \(root.path) exceeded the \(limit)-entry traversal limit; " +
                "existing catalog data was left unchanged."
        case let .tooManyPreservedFailurePaths(root, limit):
            return "Scan of \(root.path) exceeded the \(limit)-failure preservation limit; " +
                "existing catalog data was left unchanged."
        default:
            return nil
        }
    }
}
