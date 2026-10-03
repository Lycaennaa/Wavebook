import Foundation
import GRDB

extension LibraryDatabase {
    static func invalidateTrackReplayGain(
        trackID: Int64,
        fingerprint: ReplayGainFileFingerprint,
        database: Database
    ) throws -> Bool {
        try ensureReplayGainRow(trackID: trackID, fingerprint: fingerprint, database: database)
        let invalidated = try resetReplayGain(trackID: trackID, fingerprint: fingerprint, database: database)
        try refreshReplayGainFingerprint(trackID: trackID, fingerprint: fingerprint, database: database)
        return invalidated
    }

    private static func ensureReplayGainRow(
        trackID: Int64,
        fingerprint: ReplayGainFileFingerprint,
        database: Database
    ) throws {
        try database.execute(
            sql: """
            INSERT INTO replayGainAnalysis (
                trackId, analysisState, sourceMtime, sourceFileSize, sourceContentFingerprint,
                analyzerVersion, tagSchemaVersion
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(trackId) DO NOTHING
            """,
            arguments: [
                trackID,
                ReplayGainAnalysisState.pending.rawValue,
                databaseTimestamp(fingerprint.modificationDate),
                fingerprint.fileSize,
                fingerprint.contentFingerprint,
                ReplayGain.analyzerVersion,
                ReplayGain.tagSchemaVersion
            ]
        )
    }

    private static func resetReplayGain(
        trackID: Int64,
        fingerprint: ReplayGainFileFingerprint,
        database: Database
    ) throws -> Bool {
        try database.execute(
            sql: """
            UPDATE replayGainAnalysis SET
                trackGainDB = NULL, trackPeak = NULL, trackGainSource = NULL,
                albumGainDB = NULL, albumPeak = NULL, albumGainSource = NULL, albumGeneration = NULL,
                analysisState = ?, errorReason = NULL, errorAt = NULL, claimToken = NULL,
                trackRevision = trackRevision + 1,
                sourceMtime = ?, sourceFileSize = ?, sourceContentFingerprint = ?,
                analyzerVersion = ?, tagSchemaVersion = ?
            WHERE trackId = ? AND (
                analyzerVersion <> ? OR tagSchemaVersion <> ?
                OR sourceContentFingerprint IS NULL
                OR ? IS NULL
                OR sourceContentFingerprint <> ?
            )
            """,
            arguments: [
                ReplayGainAnalysisState.pending.rawValue,
                databaseTimestamp(fingerprint.modificationDate),
                fingerprint.fileSize,
                fingerprint.contentFingerprint,
                ReplayGain.analyzerVersion,
                ReplayGain.tagSchemaVersion,
                trackID,
                ReplayGain.analyzerVersion,
                ReplayGain.tagSchemaVersion,
                fingerprint.contentFingerprint,
                fingerprint.contentFingerprint
            ]
        )
        return database.changesCount == 1
    }

    private static func refreshReplayGainFingerprint(
        trackID: Int64,
        fingerprint: ReplayGainFileFingerprint,
        database: Database
    ) throws {
        try database.execute(
            sql: """
            UPDATE replayGainAnalysis SET
                sourceMtime = ?, sourceFileSize = ?, sourceContentFingerprint = ?
            WHERE trackId = ?
            """,
            arguments: [
                databaseTimestamp(fingerprint.modificationDate),
                fingerprint.fileSize,
                fingerprint.contentFingerprint,
                trackID
            ]
        )
}
    func invalidateChangedReplayGainFiles(
        expected: [String: ReplayGainFileFingerprint],
        ignoringCancellation: Bool = false
    ) throws {
        let changed = try changedReplayGainFiles(expected: expected, ignoringCancellation: ignoringCancellation)
        guard !changed.isEmpty else { return }
        try writer.write { database in
            try Self.invalidateChangedReplayGainFiles(changes: changed, database: database)
        }
    }

    private func changedReplayGainFiles(
        expected: [String: ReplayGainFileFingerprint],
        ignoringCancellation: Bool
    ) throws -> [(path: String, fingerprint: ReplayGainFileFingerprint)] {
        if !ignoringCancellation {
            try Self.checkCatalogCancellation()
        }
        let candidatePaths = expected.keys.sorted()
        guard !candidatePaths.isEmpty else { return [] }
        let pathsToCheck: Set<String> = try writer.read { database in
            let placeholders = Array(repeating: "?", count: candidatePaths.count).joined(separator: ", ")
            return Set(try String.fetchAll(
                database,
                sql: """
                    SELECT tracks.path
                    FROM tracks
                    JOIN replayGainAnalysis ON replayGainAnalysis.trackId = tracks.id
                    WHERE tracks.path IN (\(placeholders))
                      AND (
                          replayGainAnalysis.trackGainDB IS NOT NULL
                          OR replayGainAnalysis.albumGainDB IS NOT NULL
                          OR replayGainAnalysis.analysisState = ?
                      )
                    """,
                arguments: StatementArguments(candidatePaths + [ReplayGainAnalysisState.failed.rawValue])
            ))
        }
        var changed: [(path: String, fingerprint: ReplayGainFileFingerprint)] = []
        changed.reserveCapacity(pathsToCheck.count)
        for path in pathsToCheck {
            if !ignoringCancellation {
                try Self.checkCatalogCancellation()
            }
            guard let expectedFingerprint = expected[path] else { continue }
            let currentFingerprint = ignoringCancellation
                ? Self.fileFingerprintIgnoringCancellation(path: path)
                : Self.fileFingerprint(path: path)
            if !ignoringCancellation {
                try Self.checkCatalogCancellation()
            }
            guard !Self.fingerprintsMatch(currentFingerprint, expectedFingerprint) else { continue }
            changed.append((path, currentFingerprint))
        }
        return changed
    }

    private static func invalidateChangedReplayGainFiles(
        changes: [(path: String, fingerprint: ReplayGainFileFingerprint)],
        database: Database
    ) throws {
        var changedAlbumKeys = Set<AlbumKey>()
        for change in changes {
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT id, albumTitle, albumArtist, artistDisplay FROM tracks WHERE path = ?",
                arguments: [change.path]
            ) else {
                continue
            }
            let trackID: Int64 = row["id"]
            if let albumKey = Self.albumKey(from: row) {
                changedAlbumKeys.insert(albumKey)
            }
            _ = try Self.invalidateTrackReplayGain(
                trackID: trackID,
                fingerprint: change.fingerprint,
                database: database
            )
        }
        try Self.invalidateAlbumValues(
            for: changedAlbumKeys,
            ignoringCancellation: true,
            db: database
        )
    }
}
