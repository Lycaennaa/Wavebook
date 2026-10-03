import CryptoKit
import Foundation

/// Lifecycle state of replay-gain analysis.
public enum ReplayGainAnalysisState: String, Codable, Sendable {
    /// Analysis has not started.
    case pending
    /// Analysis is currently running.
    case running
    /// Analysis completed successfully.
    case ready
    /// Analysis failed.
    case failed
}

/// Two-level file fingerprint used to validate cached replay-gain values.
public struct ReplayGainFileFingerprint: Equatable, Hashable, Sendable {
    /// File modification date, if available.
    public let modificationDate: Date?
    /// File size in bytes, if available.
    public let fileSize: Int64?
    /// Full-file SHA-256 hash, if available.
    public let contentFingerprint: String?

    /// Creates a file fingerprint.
    public init(modificationDate: Date?, fileSize: Int64?, contentFingerprint: String? = nil) {
        self.modificationDate = modificationDate
        self.fileSize = fileSize
        self.contentFingerprint = contentFingerprint
    }
}

extension ReplayGainFileFingerprint {
    private static let contentHashChunkBytes = 1 * 1_024 * 1_024

    static func metadata(path: String) -> ReplayGainFileFingerprint {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return ReplayGainFileFingerprint(
            modificationDate: values?.contentModificationDate,
            fileSize: values?.fileSize.map { Int64($0) }
        )
    }

    static func current(path: String) -> ReplayGainFileFingerprint {
        current(path: path, checkingCancellation: true)
    }

    static func currentIgnoringCancellation(path: String) -> ReplayGainFileFingerprint {
        current(path: path, checkingCancellation: false)
    }

    private static func current(
        path: String,
        checkingCancellation: Bool
    ) -> ReplayGainFileFingerprint {
        let metadata = metadata(path: path)
        return ReplayGainFileFingerprint(
            modificationDate: metadata.modificationDate,
            fileSize: metadata.fileSize,
            contentFingerprint: contentFingerprint(
                at: URL(fileURLWithPath: path),
                checkingCancellation: checkingCancellation
            )
        )
    }

    static func metadataMatches(
        _ lhs: ReplayGainFileFingerprint,
        _ rhs: ReplayGainFileFingerprint
    ) -> Bool {
        lhs.modificationDate == rhs.modificationDate && lhs.fileSize == rhs.fileSize
    }

    static func matches(
        _ current: ReplayGainFileFingerprint,
        _ expected: ReplayGainFileFingerprint
    ) -> Bool {
        switch (current.contentFingerprint, expected.contentFingerprint) {
        case let (.some(currentHash), .some(expectedHash)):
            return currentHash == expectedHash
        case (.none, .none):
            return metadataMatches(current, expected)
        case (.some, .none), (.none, .some):
            return false
        }
    }

    private static func contentFingerprint(at url: URL, checkingCancellation: Bool) -> String? {
        guard !checkingCancellation || !Task.isCancelled,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        do {
            while let data = try handle.read(upToCount: contentHashChunkBytes), !data.isEmpty {
                guard !checkingCancellation || !Task.isCancelled else { return nil }
                hasher.update(data: data)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// A track queued for replay-gain analysis.
public struct ReplayGainPendingItem: Equatable, Sendable {
    /// Track identifier.
    public let trackID: Int64
    /// Track file path.
    public let path: String
    /// Album grouping key.
    public let albumKey: AlbumKey
    /// Track duration in seconds.
    public let duration: TimeInterval
    /// Fingerprint captured when the item was queued.
    public let fingerprint: ReplayGainFileFingerprint
    /// Claim token for the pending work item.
    public let claimToken: String
    /// Cached track values, if available.
    public let cachedTrackValues: ReplayGainScopeValues?

    /// Creates a pending analysis item.
    public init(
        trackID: Int64,
        path: String,
        albumKey: AlbumKey,
        duration: TimeInterval = 0,
        fingerprint: ReplayGainFileFingerprint,
        claimToken: String,
        cachedTrackValues: ReplayGainScopeValues? = nil
    ) {
        self.trackID = trackID
        self.path = path
        self.albumKey = albumKey
        self.duration = duration
        self.fingerprint = fingerprint
        self.claimToken = claimToken
        self.cachedTrackValues = cachedTrackValues
    }
}

/// Cached replay-gain values and their analysis metadata.
public struct ReplayGainNormalizationData: Equatable, Sendable {
    /// Track identifier.
    public let trackID: Int64
    /// Track file path.
    public let path: String
    /// Track-level gain values.
    public let track: ReplayGainScopeValues?
    /// Album-level gain values.
    public let album: ReplayGainScopeValues?
    /// Album generation used for the values.
    public let albumGeneration: String?
    /// Current analysis state.
    public let state: ReplayGainAnalysisState
    /// Analysis failure reason, if any.
    public let errorReason: String?
    /// Time at which analysis failed, if any.
    public let errorAt: Date?
    /// Fingerprint associated with the values.
    public let fingerprint: ReplayGainFileFingerprint
    /// Track revision used for the values.
    public let trackRevision: Int
    /// Analyzer version used for the values.
    public let analyzerVersion: Int
    /// Tag schema version used for the values.
    public let tagSchemaVersion: Int
}

/// Current replay-gain analysis phase.
public enum ReplayGainAnalysisStage: String, Equatable, Sendable {
    /// No active analysis worker.
    case idle
    /// Claims are being recovered before analysis resumes.
    case recovering
    /// The worker is waiting for new library work.
    case waiting
    /// Track-level values are being analyzed.
    case tracks
    /// Album-level values are being analyzed.
    case albums
}

/// Progress across track and album values.
public struct ReplayGainAnalysisProgress: Equatable, Sendable {
    /// Number of library tracks.
    public let total: Int
    /// Tracks with complete track-level values.
    public let trackCompleted: Int
    /// Tracks with complete album-level values.
    public let albumCompleted: Int

    /// Creates analysis progress.
    public init(total: Int = 0, trackCompleted: Int = 0, albumCompleted: Int = 0) {
        self.total = total
        self.trackCompleted = trackCompleted
        self.albumCompleted = albumCompleted
    }
}

/// Counts of replay-gain analysis items by state.
public struct ReplayGainAnalysisStatusCounts: Equatable, Sendable {
    /// Number of pending items.
    public var pending: Int
    /// Number of running items.
    public var running: Int
    /// Number of ready items.
    public var ready: Int
    /// Number of failed items.
    public var failed: Int

    /// Creates analysis status counts.
    public init(pending: Int = 0, running: Int = 0, ready: Int = 0, failed: Int = 0) {
        self.pending = pending
        self.running = running
        self.ready = ready
        self.failed = failed
    }
}

/// A replay-gain analysis failure.
public struct ReplayGainAnalysisFailure: Equatable, Sendable {
    /// Track identifier.
    public let trackID: Int64
    /// Track file path.
    public let path: String
    /// Failure reason.
    public let reason: String
    /// UTC time of the failure.
    public let timestamp: Date
}

/// Track metadata included in an album analysis.
public struct ReplayGainAlbumMember: Equatable, Sendable {
    /// Track identifier.
    public let trackID: Int64
    /// Track fingerprint.
    public let fingerprint: ReplayGainFileFingerprint
    /// Track revision.
    public let trackRevision: Int

    /// Creates an album-analysis member.
    public init(trackID: Int64, fingerprint: ReplayGainFileFingerprint, trackRevision: Int) {
        self.trackID = trackID
        self.fingerprint = fingerprint
        self.trackRevision = trackRevision
    }
}

struct ReplayGainAlbumAnalysisItem: Equatable, Sendable {
    let albumKey: AlbumKey?
    let members: [ReplayGainAlbumMember]
    let trackCount: Int
    let allPaths: [String]
    let availablePaths: [String]
    let totalDuration: TimeInterval
    let displayPath: String

    var fingerprintsByPath: [String: ReplayGainFileFingerprint] {
        Dictionary(
            zip(allPaths, members.map(\.fingerprint)),
            uniquingKeysWith: { first, _ in first }
        )
    }
}

/// A replay-gain database failure.
public enum ReplayGainDatabaseError: Error, Equatable, Sendable {
    /// Required gain values were unavailable.
    case incompleteValues
    /// Tracks could not be grouped into a valid album.
    case invalidAlbumGroup
}
