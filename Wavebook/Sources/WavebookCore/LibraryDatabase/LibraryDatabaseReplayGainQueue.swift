import Foundation
import GRDB

extension LibraryDatabase {
    /// Claims the next pending track for replay-gain analysis.
    public func claimNextPendingReplayGainItem() throws -> ReplayGainPendingItem? {
        try writer.write { database in
            guard let row = try Row.fetchOne(database, sql: """
                SELECT tracks.id, tracks.path, tracks.albumTitle, tracks.albumArtist, tracks.artistDisplay,
                       tracks.duration,
                       replayGainAnalysis.sourceMtime, replayGainAnalysis.sourceFileSize,
                       replayGainAnalysis.sourceContentFingerprint,
                       replayGainAnalysis.trackGainDB, replayGainAnalysis.trackPeak, replayGainAnalysis.trackGainSource
                FROM replayGainAnalysis
                JOIN tracks ON tracks.id = replayGainAnalysis.trackId
                WHERE replayGainAnalysis.analysisState = ?
                ORDER BY tracks.id
                LIMIT 1
                """, arguments: [ReplayGainAnalysisState.pending.rawValue]) else {
                return nil
            }
            let trackID: Int64 = row["id"]
            let claimToken = UUID().uuidString
            try database.execute(
                sql: """
                UPDATE replayGainAnalysis
                SET analysisState = ?, claimToken = ?
                WHERE trackId = ? AND analysisState = ?
                """,
                arguments: [
                    ReplayGainAnalysisState.running.rawValue,
                    claimToken,
                    trackID,
                    ReplayGainAnalysisState.pending.rawValue
                ]
            )
            guard database.changesCount == 1 else { return nil }
            return Self.pendingReplayGainItem(from: row, claimToken: claimToken)
        }
    }

    func nextReplayGainAlbumAnalysisItem() throws -> ReplayGainAlbumAnalysisItem? {
        try writer.read { database in
            try Self.nextReplayGainAlbumAnalysisItem(database: database)
        }
    }

    private static func nextReplayGainAlbumAnalysisItem(
        database: Database
    ) throws -> ReplayGainAlbumAnalysisItem? {
        guard let candidate = try replayGainAlbumCandidate(database: database) else {
            return nil
        }
        guard let albumKey = Self.albumKey(from: candidate) else {
            return singleTrackReplayGainItem(candidate: candidate)
        }
        let albumStats = try Self.replayGainAlbumStats(for: albumKey, db: database)
        guard !albumStats.hasInProgress else { return nil }
        guard albumStats.trackCount <= ReplayGainAnalyzer.maximumAlbumTrackCount else {
            return ReplayGainAlbumAnalysisItem(
                albumKey: albumKey,
                members: [],
                trackCount: albumStats.trackCount,
                allPaths: [],
                availablePaths: [],
                totalDuration: 0,
                displayPath: candidate["path"]
            )
        }
        return try replayGainAlbumAnalysisItem(
            albumKey: albumKey,
            candidate: candidate,
            database: database
        )
    }

    private static func replayGainAlbumCandidate(database: Database) throws -> Row? {
        try Row.fetchOne(database, sql: """
            SELECT tracks.id, tracks.path, tracks.albumTitle, tracks.albumArtist, tracks.artistDisplay, tracks.duration,
                   replayGainAnalysis.analysisState, replayGainAnalysis.sourceMtime, replayGainAnalysis.sourceFileSize,
                   replayGainAnalysis.sourceContentFingerprint,
                   replayGainAnalysis.trackGainDB, replayGainAnalysis.trackPeak, replayGainAnalysis.trackRevision
            FROM replayGainAnalysis
            JOIN tracks ON tracks.id = replayGainAnalysis.trackId
            WHERE (replayGainAnalysis.albumGainDB IS NULL OR replayGainAnalysis.albumPeak IS NULL)
              AND (
                replayGainAnalysis.analysisState = ?
                OR (
                    replayGainAnalysis.analysisState = ?
                    AND (replayGainAnalysis.errorReason IS NULL OR replayGainAnalysis.errorReason NOT LIKE ?)
                )
              )
            ORDER BY tracks.id
            LIMIT 1
            """, arguments: [
                ReplayGainAnalysisState.ready.rawValue,
                ReplayGainAnalysisState.failed.rawValue,
                "\(Self.replayGainAlbumFailureMarker)%"
            ])
    }

    private static func singleTrackReplayGainItem(candidate: Row) -> ReplayGainAlbumAnalysisItem {
        let trackID: Int64 = candidate["id"]
        let gain: Double? = candidate["trackGainDB"]
        let peak: Double? = candidate["trackPeak"]
        return ReplayGainAlbumAnalysisItem(
            albumKey: nil,
            members: [ReplayGainAlbumMember(
                trackID: trackID,
                fingerprint: Self.fingerprint(from: candidate),
                trackRevision: candidate["trackRevision"]
            )],
            trackCount: 1,
            allPaths: [candidate["path"]],
            availablePaths: gain != nil && peak != nil ? [candidate["path"]] : [],
            totalDuration: candidate["duration"],
            displayPath: candidate["path"]
        )
    }

    private static func replayGainAlbumAnalysisItem(
        albumKey: AlbumKey,
        candidate: Row,
        database: Database
    ) throws -> ReplayGainAlbumAnalysisItem? {
        let rows = try Row.fetchAll(database, sql: """
            SELECT tracks.id, tracks.path, tracks.albumTitle, tracks.albumArtist, tracks.artistDisplay, tracks.duration,
                   replayGainAnalysis.analysisState, replayGainAnalysis.sourceMtime, replayGainAnalysis.sourceFileSize,
                   replayGainAnalysis.sourceContentFingerprint,
                   replayGainAnalysis.trackGainDB, replayGainAnalysis.trackPeak, replayGainAnalysis.trackRevision
            FROM tracks
            JOIN replayGainAnalysis ON replayGainAnalysis.trackId = tracks.id
            WHERE \(Self.replayGainAlbumPredicate())
            ORDER BY tracks.id
            """, arguments: [albumKey.title, albumKey.owner])
        guard !rows.contains(where: {
            let state = ReplayGainAnalysisState(rawValue: $0["analysisState"])
            return state == .pending || state == .running
        }) else {
            return nil
        }
        let members = rows.map { row in
            ReplayGainAlbumMember(
                trackID: row["id"],
                fingerprint: Self.fingerprint(from: row),
                trackRevision: row["trackRevision"]
            )
        }
        let availablePaths = rows.compactMap { row -> String? in
            let gain: Double? = row["trackGainDB"]
            let peak: Double? = row["trackPeak"]
            return gain != nil && peak != nil ? row["path"] : nil
        }
        return ReplayGainAlbumAnalysisItem(
            albumKey: albumKey,
            members: members,
            trackCount: rows.count,
            allPaths: rows.map { $0["path"] },
            availablePaths: availablePaths,
            totalDuration: rows.reduce(0) { $0 + ($1["duration"] as TimeInterval) },
            displayPath: candidate["path"]
        )
    }

    /// Returns replay-gain data for a track identifier.
    public func replayGainData(trackID: Int64) throws -> ReplayGainNormalizationData? {
        try writer.read { database in
            try Self.replayGainData(db: database, where: "tracks.id = ?", arguments: [trackID])
        }
    }

    /// Returns replay-gain data for a path.
    public func replayGainData(path: String) throws -> ReplayGainNormalizationData? {
        try writer.read { database in
            try Self.replayGainData(db: database, where: "tracks.path = ?", arguments: [path])
        }
    }

    /// Releases a replay-gain claim and returns it to the pending queue.
    @discardableResult
    public func releaseReplayGainClaim(
        trackID: Int64,
        fingerprint: ReplayGainFileFingerprint,
        claimToken: String
    ) throws -> Bool {
        try writer.write { database in
            guard
                let row = try Self.replayGainRow(trackID: trackID, db: database),
                Self.fingerprint(from: row) == fingerprint,
                Self.claimToken(from: row) == claimToken,
                ReplayGainAnalysisState(rawValue: row["analysisState"]) == .running
            else {
                return false
            }
            try database.execute(
                sql: "UPDATE replayGainAnalysis SET analysisState = ?, claimToken = NULL WHERE trackId = ?",
                arguments: [ReplayGainAnalysisState.pending.rawValue, trackID]
            )
            return true
        }
    }

    /// Recovers an abandoned replay-gain claim.
    @discardableResult
    func recoverReplayGainClaim(trackID: Int64, claimToken: String) throws -> Bool {
        guard let path = try writer.read({ database in
            try String.fetchOne(
                database,
                sql: "SELECT path FROM tracks WHERE id = ?",
                arguments: [trackID]
            )
        }) else {
            return false
        }
        let currentFingerprint = Self.fileFingerprint(path: path)
        try Self.checkCatalogCancellation()
        return try writer.write { database in
            try Self.recoverReplayGainClaim(
                trackID: trackID,
                claimToken: claimToken,
                currentFingerprint: currentFingerprint,
                database: database
            )
        }
    }

    private static func recoverReplayGainClaim(
        trackID: Int64,
        claimToken: String,
        currentFingerprint: ReplayGainFileFingerprint,
        database: Database
    ) throws -> Bool {
        guard
            let row = try Self.replayGainRow(trackID: trackID, db: database),
            Self.claimToken(from: row) == claimToken,
            ReplayGainAnalysisState(rawValue: row["analysisState"]) == .running
        else {
            return false
        }
        let storedFingerprint = Self.fingerprint(from: row)
        if !Self.fingerprintsMatch(currentFingerprint, storedFingerprint) {
            try Self.invalidateReplayGainForFileChange(
                trackID: trackID,
                currentFingerprint: currentFingerprint,
                row: row,
                db: database
            )
            return true
        }

        try database.execute(
            sql: """
            UPDATE replayGainAnalysis
            SET analysisState = ?, claimToken = NULL
            WHERE trackId = ? AND analysisState = ? AND claimToken = ?
            """,
            arguments: [
                ReplayGainAnalysisState.pending.rawValue,
                trackID,
                ReplayGainAnalysisState.running.rawValue,
                claimToken
            ]
        )
        return database.changesCount == 1
    }
    /// Invalidates replay-gain data after a source-file change.
    @discardableResult
    public func invalidateReplayGainForFileChange(
        trackID: Int64,
        expectedFingerprint: ReplayGainFileFingerprint,
        currentFingerprint: ReplayGainFileFingerprint,
        claimToken: String?,
        ignoringCancellation: Bool = false
    ) throws -> Bool {
        try writer.write { database in
            guard
                let row = try Self.replayGainRow(trackID: trackID, db: database),
                Self.fingerprint(from: row) == expectedFingerprint
            else {
                return false
            }
            let state = ReplayGainAnalysisState(rawValue: row["analysisState"])
            if let claimToken {
                guard state == .running, Self.claimToken(from: row) == claimToken else { return false }
            } else {
                guard state == .ready || state == .failed || state == .pending,
                      Self.claimToken(from: row) == nil else { return false }
            }
            try Self.invalidateReplayGainForFileChange(
                trackID: trackID,
                currentFingerprint: currentFingerprint,
                row: row,
                ignoringCancellation: ignoringCancellation,
                db: database
            )
            return true
        }
    }
}
