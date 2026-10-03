import Foundation
import GRDB

enum CatalogReconcileTesting {
    enum Phase: Sendable, Equatable {
        case canonicalizing
        case saving
        case deleting
        case invalidating
        case unchangedScanTimestampUpdated
    }

    @TaskLocal
    static var checkpointHandler: (@Sendable (Phase) -> Void)?
    @TaskLocal
    static var albumInvalidationHandler: (@Sendable (Set<AlbumKey>) -> Void)?

    static func recordAlbumInvalidation(_ albumKeys: Set<AlbumKey>) {
        albumInvalidationHandler?(albumKeys)
    }

    static func checkpoint(_ phase: Phase) {
        checkpointHandler?(phase)
    }
}

struct CatalogReconcileInput {
    let rootPath: String
    let tracks: [Track]
    let expectedPaths: Set<String>?
    let lyricFiles: [URL]
    let preservedPaths: Set<String>
    let preservedLyricPaths: Set<String>
}
private struct CatalogReconcileResult {
    let rootID: Int64
    let tracks: [Track]
    let changedLyricKeys: Set<String>
}

extension LibraryDatabase {

    private struct CatalogReconcileRequest {
        let rootPath: String
        let tracks: [Track]
        let fingerprints: [String: ReplayGainFileFingerprint]
        let lyricFiles: [URL]
        let preservedPaths: Set<String>
        let preservedLyricPaths: Set<String>
        let expectedPaths: Set<String>?
    }

    private struct CanonicalizedCatalog {
        let tracks: [Track]
        let preservedPaths: Set<String>
        let preservedLyricPaths: Set<String>
        let existingPaths: Set<String>
    }

    /// Reconciles tracks and lyric files for a library root. Returns saved tracks with persisted catalog IDs; preserved failed paths are omitted.
    @discardableResult
    public func reconcile(
        rootPath: String,
        tracks: [Track],
        lyricFiles: [URL],
        preservedPaths: Set<String> = [],
        preservedLyricPaths: Set<String> = []
    ) throws -> [Track] {
        try reconcileTracks(
            CatalogReconcileInput(
                rootPath: rootPath,
                tracks: tracks,
                expectedPaths: nil,
                lyricFiles: lyricFiles,
                preservedPaths: preservedPaths,
                preservedLyricPaths: preservedLyricPaths
            )
        )
    }
    func reconcileIncremental(_ input: CatalogReconcileInput) throws -> [Track] {
        try reconcileTracks(input, refreshTrackSnapshots: true)
    }

    private func reconcileTracks(
        _ input: CatalogReconcileInput,
        refreshTrackSnapshots: Bool = false
    ) throws -> [Track] {
        let rootPath = input.rootPath
        let tracks = input.tracks
        let expectedPaths = input.expectedPaths
        let lyricFiles = input.lyricFiles
        let preservedPaths = input.preservedPaths
        let preservedLyricPaths = input.preservedLyricPaths
        guard tracks.count <= Self.maximumReconciliationTrackCount else {
            throw LibraryDatabaseError.tooManyTracks(limit: Self.maximumReconciliationTrackCount)
        }
        guard (expectedPaths?.count ?? 0) <= Self.maximumReconciliationTrackCount else {
            throw LibraryDatabaseError.tooManyTracks(limit: Self.maximumReconciliationTrackCount)
        }
        guard lyricFiles.count <= Self.maximumReconciliationLyricFileCount else {
            throw LibraryDatabaseError.tooManyLyricFiles(limit: Self.maximumReconciliationLyricFileCount)
        }
        guard preservedPaths.count <= Self.maximumReconciliationTrackCount else {
            throw LibraryDatabaseError.tooManyTracks(limit: Self.maximumReconciliationTrackCount)
        }
        guard preservedLyricPaths.count <= Self.maximumReconciliationLyricFileCount else {
            throw LibraryDatabaseError.tooManyLyricFiles(limit: Self.maximumReconciliationLyricFileCount)
        }
        try Self.checkCatalogCancellation()
        let resolvedRootPath = try Self.resolveRootPath(rootPath)
        let fingerprints = try Self.precomputedFingerprints(for: tracks, underRoot: resolvedRootPath)
        let request = CatalogReconcileRequest(
            rootPath: rootPath,
            tracks: tracks,
            fingerprints: fingerprints,
            lyricFiles: lyricFiles,
            preservedPaths: preservedPaths,
            preservedLyricPaths: preservedLyricPaths,
            expectedPaths: expectedPaths
        )
        let savedTracks = try writeCatalog { database in
            let reconciliation = try Self.reconcile(request: request, database: database)
            guard refreshTrackSnapshots else { return reconciliation.tracks }
            let lyricAffectedTracks = try Self.tracks(
                matchingLyricKeys: reconciliation.changedLyricKeys,
                rootID: reconciliation.rootID,
                database: database
            )
            return try Self.persistedTrackSnapshots(
                for: reconciliation.tracks + lyricAffectedTracks,
                database: database
            )
        }
        try invalidateChangedReplayGainFiles(
            expected: fingerprints,
            ignoringCancellation: true
        )
        try Self.checkCatalogCancellation()
        return savedTracks
    }
    private static func persistedTrackSnapshots(
        for tracks: [Track],
        database: Database
    ) throws -> [Track] {
        var trackIDs: [Int64] = []
        var uniqueTrackIDs = Set<Int64>()
        for track in tracks {
            try Self.checkCatalogCancellation()
            guard let id = track.id else { throw LibraryDatabaseError.missingTrack(track.path) }
            if uniqueTrackIDs.insert(id).inserted { trackIDs.append(id) }
        }
        var snapshotsByID: [Int64: Track] = [:]
        for start in stride(from: 0, to: trackIDs.count, by: DatabaseQueryLimits.maximumSQLiteArgumentCount) {
            try Self.checkCatalogCancellation()
            let end = min(start + DatabaseQueryLimits.maximumSQLiteArgumentCount, trackIDs.count)
            let chunk = Array(trackIDs[start..<end])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT \(Self.trackSelection) FROM tracks WHERE tracks.id IN (\(placeholders))",
                arguments: StatementArguments(chunk)
            )
            for row in rows {
                let track = Self.track(from: row)
                if let id = track.id { snapshotsByID[id] = track }
            }
        }
        guard snapshotsByID.count == trackIDs.count else {
            throw LibraryDatabaseError.missingTrack("incremental catalog snapshot")
        }
        return trackIDs.compactMap { snapshotsByID[$0] }
    }

    private static func precomputedFingerprints(
        for tracks: [Track],
        underRoot rootPath: String
    ) throws -> [String: ReplayGainFileFingerprint] {
        var fingerprints: [String: ReplayGainFileFingerprint] = [:]
        fingerprints.reserveCapacity(tracks.count)
        for track in tracks {
            try Self.checkCatalogCancellation()
            let path = try Self.canonicalPath(track.path, underRoot: rootPath)
            fingerprints[path] = Self.fileFingerprint(path: path)
            try Self.checkCatalogCancellation()
        }
        try Self.checkCatalogCancellation()
        return fingerprints
    }

    private static func reconcile(
        request: CatalogReconcileRequest,
        database: Database
    ) throws -> CatalogReconcileResult {
        let rootID = try Self.ensureRoot(path: request.rootPath, db: database)
        guard let storedRootPath = try Self.rootPath(forID: rootID, db: database) else {
            throw LibraryDatabaseError.missingRoot(request.rootPath)
        }
        let canonical = try canonicalize(
            tracks: request.tracks,
            expectedPaths: request.expectedPaths,
            preservedPaths: request.preservedPaths,
            preservedLyricPaths: request.preservedLyricPaths,
            rootPath: storedRootPath
        )
        let changedPaths = Set(canonical.tracks.map(\.path))
        let protectedIdentityPaths = canonical.existingPaths.subtracting(changedPaths)
        let identityReconciliation = try CatalogIdentityReconciliation.reconcile(
            tracks: canonical.tracks,
            rootID: rootID,
            protectedIdentityPaths: protectedIdentityPaths,
            database: database
        )
        var changedAlbumKeys = identityReconciliation.changedAlbumKeys
        let savedTracks = try saveCatalogTracks(
            identityReconciliation.tracks,
            fingerprints: request.fingerprints,
            rootID: rootID,
            database: database
        )
        changedAlbumKeys.formUnion(savedTracks.albumKeys)
        let removedAlbumKeys = try removeMissingCatalogTracks(
            rootID: rootID,
            existingPaths: canonical.existingPaths,
            database: database
        )
        try Self.checkCatalogCancellation()
        try Self.reattachOrphanedPlaylistItems(db: database)
        changedAlbumKeys.formUnion(removedAlbumKeys)
        CatalogReconcileTesting.checkpoint(.invalidating)
        try Self.checkCatalogCancellation()
        try Self.invalidateAlbumValues(for: changedAlbumKeys, db: database)
        try Self.checkCatalogCancellation()
        let changedLyricKeys = try Self.reconcileLyricFiles(
            request.lyricFiles,
            rootID: rootID,
            preservedPaths: canonical.preservedLyricPaths,
            db: database
        )
        try Self.deleteOrphanNames(database: database)
        try Self.checkCatalogCancellation()
        try database.execute(
            sql: "UPDATE roots SET lastScanAt = ? WHERE id = ?",
            arguments: [Date(), rootID]
        )
        return CatalogReconcileResult(rootID: rootID, tracks: savedTracks.tracks, changedLyricKeys: changedLyricKeys)
    }

    private static func tracks(
        matchingLyricKeys keys: Set<String>,
        rootID: Int64,
        database: Database
    ) throws -> [Track] {
        let keys = keys.filter { !$0.isEmpty }.sorted()
        let chunkSize = max(1, DatabaseQueryLimits.maximumSQLiteArgumentCount - 1)
        var tracks: [Track] = []
        var start = 0
        while start < keys.count {
            try Self.checkCatalogCancellation()
            let end = min(start + chunkSize, keys.count)
            let chunk = Array(keys[start..<end])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            var arguments = StatementArguments([rootID])
            arguments += StatementArguments(chunk)
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT \(Self.trackSelection) FROM tracks WHERE rootId = ? AND lyricsKey IN (\(placeholders))",
                arguments: arguments
            )
            tracks.append(contentsOf: rows.map(Self.track(from:)))
            start = end
        }
        return tracks
    }

    private static func canonicalize(
        tracks: [Track],
        expectedPaths: Set<String>?,
        preservedPaths: Set<String>,
        preservedLyricPaths: Set<String>,
        rootPath: String
    ) throws -> CanonicalizedCatalog {
        var canonicalTracks = [Track]()
        canonicalTracks.reserveCapacity(tracks.count)
        var existingPaths = Set<String>()
        existingPaths.reserveCapacity(tracks.count + (expectedPaths?.count ?? 0) + preservedPaths.count)
        for track in tracks {
            try Self.checkCatalogCancellation()
            CatalogReconcileTesting.checkpoint(.canonicalizing)
            try Self.checkCatalogCancellation()
            var canonicalTrack = track
            canonicalTrack.path = try Self.canonicalPath(track.path, underRoot: rootPath)
            canonicalTracks.append(canonicalTrack)
            existingPaths.insert(canonicalTrack.path)
        }
        for path in expectedPaths ?? [] {
            try Self.checkCatalogCancellation()
            CatalogReconcileTesting.checkpoint(.canonicalizing)
            let canonicalPath = try Self.canonicalPath(path, underRoot: rootPath)
            existingPaths.insert(canonicalPath)
        }

        var canonicalPreservedPaths = Set<String>()
        canonicalPreservedPaths.reserveCapacity(preservedPaths.count)
        for path in preservedPaths {
            try Self.checkCatalogCancellation()
            CatalogReconcileTesting.checkpoint(.canonicalizing)
            try Self.checkCatalogCancellation()
            let canonicalPath = try Self.canonicalPathPreservingUnresolvedLeaf(path, underRoot: rootPath)
            canonicalPreservedPaths.insert(canonicalPath)
            existingPaths.insert(canonicalPath)
        }
        var canonicalPreservedLyricPaths = Set<String>()
        canonicalPreservedLyricPaths.reserveCapacity(preservedLyricPaths.count)
        for path in preservedLyricPaths {
            try Self.checkCatalogCancellation()
            CatalogReconcileTesting.checkpoint(.canonicalizing)
            try Self.checkCatalogCancellation()
            let canonicalPath = try Self.canonicalPathPreservingUnresolvedLeaf(path, underRoot: rootPath)
            canonicalPreservedLyricPaths.insert(canonicalPath)
        }
        return CanonicalizedCatalog(
            tracks: canonicalTracks,
            preservedPaths: canonicalPreservedPaths,
            preservedLyricPaths: canonicalPreservedLyricPaths,
            existingPaths: existingPaths
        )
    }

    private static func saveCatalogTracks(
        _ tracks: [Track],
        fingerprints: [String: ReplayGainFileFingerprint],
        rootID: Int64,
        database: Database
    ) throws -> (tracks: [Track], albumKeys: Set<AlbumKey>) {
        var changedAlbumKeys = Set<AlbumKey>()
        var savedTracks: [Track] = []
        savedTracks.reserveCapacity(tracks.count)
        for track in tracks {
            try Self.checkCatalogCancellation()
            CatalogReconcileTesting.checkpoint(.saving)
            try Self.checkCatalogCancellation()
            guard let fingerprint = fingerprints[track.path] else {
                throw LibraryDatabaseError.invalidSchema("Missing catalog fingerprint for \(track.path)")
            }
            let result = try Self.saveAndCollectAlbumChanges(
                track: track,
                rootID: rootID,
                fingerprint: fingerprint,
                database: database
            )
            changedAlbumKeys.formUnion(result.albumKeys)
            var savedTrack = track
            savedTrack.id = result.trackID
            savedTracks.append(savedTrack)
        }
        return (tracks: savedTracks, albumKeys: changedAlbumKeys)
    }

    private static func removeMissingCatalogTracks(
        rootID: Int64,
        existingPaths: Set<String>,
        database: Database
    ) throws -> Set<AlbumKey> {
        let rows = try Row.fetchCursor(
            database,
            sql: "SELECT id, path, albumTitle, albumArtist, artistDisplay FROM tracks WHERE rootId = ?",
            arguments: [rootID]
        )
        try Self.checkCatalogCancellation()
        var removedAlbumKeys = Set<AlbumKey>()
        while let row = try rows.next() {
            try Self.checkCatalogCancellation()
            let path: String = row["path"]
            guard !existingPaths.contains(path) else { continue }
            CatalogReconcileTesting.checkpoint(.deleting)
            try Self.checkCatalogCancellation()
            if let albumKey = Self.albumKey(from: row) {
                removedAlbumKeys.insert(albumKey)
            }
            let id: Int64 = row["id"]
            try Self.deleteTrackPreservingPlaylistIdentity(trackID: id, db: database)
        }
        return removedAlbumKeys
    }

}
