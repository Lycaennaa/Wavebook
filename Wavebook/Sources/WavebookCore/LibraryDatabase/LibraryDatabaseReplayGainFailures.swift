import Foundation
import GRDB

extension LibraryDatabase {
    struct TrackFailureRequest {
        let trackID: Int64
        let fingerprint: ReplayGainFileFingerprint
        let currentFingerprint: ReplayGainFileFingerprint
        let claimToken: String
        let reason: String
        let timestamp: Date
        let analyzerVersion: Int
        let tagSchemaVersion: Int
        let path: String
    }

    /// Records a replay-gain failure for a claimed track.
    @discardableResult
    public func recordReplayGainFailure(
        trackID: Int64,
        fingerprint: ReplayGainFileFingerprint,
        claimToken: String,
        reason: String,
        at timestamp: Date = Date(),
        analyzerVersion: Int = ReplayGain.analyzerVersion,
        tagSchemaVersion: Int = ReplayGain.tagSchemaVersion
    ) throws -> Bool {
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
        try Task.checkCancellation()
        let request = TrackFailureRequest(
            trackID: trackID,
            fingerprint: fingerprint,
            currentFingerprint: currentFingerprint,
            claimToken: claimToken,
            reason: String(reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)),
            timestamp: timestamp,
            analyzerVersion: analyzerVersion,
            tagSchemaVersion: tagSchemaVersion,
            path: path
        )
        return try recordReplayGainFailure(request: request)
    }

    @discardableResult
    func recordReplayGainFailure(request: TrackFailureRequest) throws -> Bool {
        guard try writer.write({ database in
            try Self.recordReplayGainFailure(request: request, database: database)
        }) else {
            return false
        }
        let finalFingerprint = Self.fileFingerprintIgnoringCancellation(path: request.path)
        guard Self.fingerprintsMatch(finalFingerprint, request.fingerprint) else {
            _ = try invalidateReplayGainForFileChange(
                trackID: request.trackID,
                expectedFingerprint: request.fingerprint,
                currentFingerprint: finalFingerprint,
                claimToken: nil,
                ignoringCancellation: true
            )
            try Task.checkCancellation()
            return false
        }
        try Task.checkCancellation()
        return true
    }

    private static func recordReplayGainFailure(
        request: TrackFailureRequest,
        database: Database
    ) throws -> Bool {
        guard
            let row = try Self.replayGainRow(trackID: request.trackID, db: database),
            Self.fingerprint(from: row) == request.fingerprint,
            Self.claimToken(from: row) == request.claimToken,
            row["analyzerVersion"] == request.analyzerVersion,
            row["tagSchemaVersion"] == request.tagSchemaVersion,
            ReplayGainAnalysisState(rawValue: row["analysisState"]) == .running
        else {
            return false
        }
        guard Self.fingerprintsMatch(request.currentFingerprint, request.fingerprint) else {
            try Self.invalidateReplayGainForFileChange(
                trackID: request.trackID,
                currentFingerprint: request.currentFingerprint,
                row: row,
                db: database
            )
            return false
        }
        try database.execute(
            sql: """
            UPDATE replayGainAnalysis SET
                trackGainDB = NULL, trackPeak = NULL, trackGainSource = NULL,
                analysisState = ?, errorReason = ?, errorAt = ?, claimToken = NULL,
                trackRevision = trackRevision + 1
            WHERE trackId = ?
            """,
            arguments: [
                ReplayGainAnalysisState.failed.rawValue,
                request.reason,
                request.timestamp,
                request.trackID
            ]
        )
        return true
    }

    private struct AlbumFailureRequest {
        let item: ReplayGainAlbumAnalysisItem
        let reason: String
        let timestamp: Date
        let expected: [Int64: (ReplayGainFileFingerprint, Int)]
        let currentFingerprints: [Int64: ReplayGainFileFingerprint]
    }

    private struct AlbumFailureRowsResult {
        let rows: [Row]
        let result: Bool?
    }
    private struct AlbumTrackLimitFailureRequest {
        let albumKey: AlbumKey
        let reason: String
        let timestamp: Date
        let stats: (trackCount: Int, hasInProgress: Bool)
        let currentFingerprints: [Int64: ReplayGainFileFingerprint]
    }

    /// Records a replay-gain failure for an album analysis item.
    @discardableResult
    func recordReplayGainAlbumFailure(
        item: ReplayGainAlbumAnalysisItem,
        reason: String,
        at timestamp: Date = Date()
    ) throws -> Bool {
        let expected = Dictionary(uniqueKeysWithValues: item.members.map {
            ($0.trackID, ($0.fingerprint, $0.trackRevision))
        })
        let initialFingerprints = try currentFingerprints(for: item)
        guard !initialFingerprints.isEmpty || item.albumKey == nil else { return false }
        let request = AlbumFailureRequest(
            item: item,
            reason: String(reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)),
            timestamp: timestamp,
            expected: expected,
            currentFingerprints: initialFingerprints
        )
        let recorded = try writer.write { database in
            try Self.recordAlbumFailure(request: request, database: database)
        }
        guard recorded else { return false }
        let finalFingerprints = try currentFingerprints(for: item, ignoringCancellation: true)
        let trackedIDs = Set(expected.keys).union(initialFingerprints.keys)
        for trackID in trackedIDs {
            guard let baseline = expected[trackID]?.0 ?? initialFingerprints[trackID],
                  let current = finalFingerprints[trackID],
                  !Self.fingerprintsMatch(current, baseline) else {
                continue
            }
            _ = try invalidateReplayGainForFileChange(
                trackID: trackID,
                expectedFingerprint: baseline,
                currentFingerprint: current,
                claimToken: nil,
                ignoringCancellation: true
            )
        }
        try Task.checkCancellation()
        return true
    }

    private static func recordAlbumFailure(
        request: AlbumFailureRequest,
        database: Database
    ) throws -> Bool {
        try Self.checkCatalogCancellation()
        let rowResult = try albumFailureRows(request: request, database: database)
        if let result = rowResult.result { return result }
        let rows = rowResult.rows
        guard Set(rows.map { $0["id"] as Int64 }) == Set(request.expected.keys) else { return false }
        guard try validateAlbumFailureRows(rows, request: request, database: database) else { return false }
        return try recordAlbumFailureRows(rows, request: request, database: database)
    }

    private static func albumFailureRows(
        request: AlbumFailureRequest,
        database: Database
    ) throws -> AlbumFailureRowsResult {
        if let albumKey = request.item.albumKey {
            let stats = try Self.replayGainAlbumStats(for: albumKey, db: database)
            if stats.trackCount > ReplayGainAnalyzer.maximumAlbumTrackCount {
                let result = try Self.recordReplayGainAlbumTrackLimitFailure(
                    request: AlbumTrackLimitFailureRequest(
                        albumKey: albumKey,
                        reason: request.reason,
                        timestamp: request.timestamp,
                        stats: stats,
                        currentFingerprints: request.currentFingerprints
                    ),
                    db: database
                )
                return AlbumFailureRowsResult(rows: [], result: result)
            }
            guard stats.trackCount == request.expected.count else {
                return AlbumFailureRowsResult(rows: [], result: false)
            }
            let rows = try Self.replayGainAlbumMemberRows(
                for: albumKey,
                trackIDs: Set(request.expected.keys),
                db: database
            )
            return AlbumFailureRowsResult(rows: rows, result: nil)
        }
        guard request.item.members.count == 1,
              let row = try Self.replayGainRow(trackID: request.item.members[0].trackID, db: database),
              Self.albumKey(from: row) == nil else {
            return AlbumFailureRowsResult(rows: [], result: false)
        }
        return AlbumFailureRowsResult(rows: [row], result: nil)
    }

    private static func validateAlbumFailureRows(
        _ rows: [Row],
        request: AlbumFailureRequest,
        database: Database
    ) throws -> Bool {
        for row in rows {
            try Self.checkCatalogCancellation()
            let trackID: Int64 = row["id"]
            guard let expected = request.expected[trackID],
                  let currentFingerprint = request.currentFingerprints[trackID],
                  expected.0 == Self.fingerprint(from: row),
                  expected.1 == row["trackRevision"] else {
                return false
            }
            guard Self.fingerprintsMatch(currentFingerprint, expected.0) else {
                try Self.invalidateReplayGainForFileChange(
                    trackID: trackID,
                    currentFingerprint: currentFingerprint,
                    row: row,
                    db: database
                )
                return false
            }
        }
        return true
    }

    private static func recordAlbumFailureRows(
        _ rows: [Row],
        request: AlbumFailureRequest,
        database: Database
    ) throws -> Bool {
        var recorded = false
        for row in rows {
            try Self.checkCatalogCancellation()
            let trackID: Int64 = row["id"]
            let hasTrackValues: Bool = row["trackGainDB"] != nil && row["trackPeak"] != nil
            let state = ReplayGainAnalysisState(rawValue: row["analysisState"]) ?? .failed
            let existingReason: String? = row["errorReason"]
            let existingTimestamp: Date? = row["errorAt"]
            try database.execute(
                sql: "UPDATE replayGainAnalysis SET analysisState = ?, errorReason = ?, errorAt = ? WHERE trackId = ?",
                arguments: [
                    hasTrackValues ? ReplayGainAnalysisState.failed.rawValue : state.rawValue,
                    Self.replayGainAlbumFailureReason(request.reason, preserving: existingReason),
                    hasTrackValues ? request.timestamp : existingTimestamp ?? request.timestamp,
                    trackID
                ]
            )
            recorded = recorded || database.changesCount == 1
        }
        return recorded
    }

    private static func recordReplayGainAlbumTrackLimitFailure(
        request: AlbumTrackLimitFailureRequest,
        db database: Database
    ) throws -> Bool {
        guard request.stats.trackCount > ReplayGainAnalyzer.maximumAlbumTrackCount,
              !request.stats.hasInProgress else { return false }

        try Self.checkCatalogCancellation()
        var lastTrackID: Int64 = 0
        while true {
            try Self.checkCatalogCancellation()
            guard let row = try replayGainAlbumTrackLimitRow(
                for: request.albumKey,
                afterTrackID: lastTrackID,
                stage: .oversizedValidation,
                db: database
            ) else { break }
            lastTrackID = row["id"]
            let trackID: Int64 = row["id"]
            guard let currentFingerprint = request.currentFingerprints[trackID],
                  Self.fingerprintsMatch(currentFingerprint, Self.fingerprint(from: row)) else {
                if let currentFingerprint = request.currentFingerprints[trackID] {
                    try Self.invalidateReplayGainForFileChange(
                        trackID: trackID,
                        currentFingerprint: currentFingerprint,
                        row: row,
                        db: database
                    )
                }
                return false
            }
        }

        try Self.checkCatalogCancellation()
        var recorded = false
        lastTrackID = 0
        while true {
            try Self.checkCatalogCancellation()
            guard let row = try replayGainAlbumTrackLimitRow(
                for: request.albumKey,
                afterTrackID: lastTrackID,
                stage: .oversizedMarking,
                db: database
            ) else { break }
            try Self.checkCatalogCancellation()
            lastTrackID = row["id"]
            let trackID: Int64 = row["id"]
            let gain: Double? = row["trackGainDB"]
            let peak: Double? = row["trackPeak"]
            let hasTrackValues = gain != nil && peak != nil
            let state = ReplayGainAnalysisState(rawValue: row["analysisState"]) ?? .failed
            let existingReason: String? = row["errorReason"]
            let existingTimestamp: Date? = row["errorAt"]
            try database.execute(
                sql: "UPDATE replayGainAnalysis SET analysisState = ?, errorReason = ?, errorAt = ? WHERE trackId = ?",
                arguments: [
                    hasTrackValues ? ReplayGainAnalysisState.failed.rawValue : state.rawValue,
                    Self.replayGainAlbumFailureReason(request.reason, preserving: existingReason),
                    hasTrackValues ? request.timestamp : existingTimestamp ?? request.timestamp,
                    trackID
                ]
            )
            recorded = recorded || database.changesCount == 1
        }
        try Self.checkCatalogCancellation()
        return recorded
    }

    private static func replayGainAlbumTrackLimitRow(
        for albumKey: AlbumKey,
        afterTrackID: Int64,
        stage: ReplayGainAlbumQueryStage,
        db database: Database
    ) throws -> Row? {
        let sql = """
            SELECT tracks.id, tracks.path, tracks.albumTitle, tracks.albumArtist, tracks.artistDisplay,
                   replayGainAnalysis.analysisState, replayGainAnalysis.sourceMtime, replayGainAnalysis.sourceFileSize,
                   replayGainAnalysis.sourceContentFingerprint,
                   replayGainAnalysis.trackGainDB, replayGainAnalysis.trackPeak,
                   replayGainAnalysis.errorReason, replayGainAnalysis.errorAt
            FROM tracks
            JOIN replayGainAnalysis ON replayGainAnalysis.trackId = tracks.id
            WHERE \(replayGainAlbumPredicate()) AND tracks.id > ?
            ORDER BY tracks.id
            LIMIT 1
            """
        ReplayGainAlbumQueryTesting.record(.init(stage: stage, sql: sql))
        return try Row.fetchOne(
            database,
            sql: sql,
            arguments: [albumKey.title, albumKey.owner, afterTrackID]
        )
    }

    /// Requeues selected or all replay-gain records.
    public func requeueReplayGain(trackIDs: [Int64]? = nil) throws {
        try writer.write { database in
            if let trackIDs {
                var albumKeys = Set<AlbumKey>()
                for trackID in Set(trackIDs) {
                    guard let row = try Self.replayGainRow(trackID: trackID, db: database) else { continue }
                    if let albumKey = Self.albumKey(from: row) {
                        albumKeys.insert(albumKey)
                    }
                    try Self.clearReplayGainValues(trackID: trackID, db: database)
                }
                try Self.invalidateAlbumValues(for: albumKeys, db: database)
            } else {
                try database.execute(sql: """
                    UPDATE replayGainAnalysis SET
                        trackGainDB = NULL, trackPeak = NULL, trackGainSource = NULL,
                        albumGainDB = NULL, albumPeak = NULL, albumGainSource = NULL, albumGeneration = NULL,
                        analysisState = ?, errorReason = NULL, errorAt = NULL, claimToken = NULL,
                        trackRevision = trackRevision + 1,
                        analyzerVersion = ?, tagSchemaVersion = ?
                    """, arguments: [
                        ReplayGainAnalysisState.pending.rawValue,
                        ReplayGain.analyzerVersion,
                        ReplayGain.tagSchemaVersion
                    ])
            }
        }
    }
    private func currentFingerprints(
        for item: ReplayGainAlbumAnalysisItem,
        ignoringCancellation: Bool = false
    ) throws -> [Int64: ReplayGainFileFingerprint] {
        let paths: [(Int64, String)] = try writer.read { database in
            if let albumKey = item.albumKey {
                return try Row.fetchAll(
                    database,
                    sql: """
                    SELECT tracks.id, tracks.path
                    FROM tracks
                    JOIN replayGainAnalysis ON replayGainAnalysis.trackId = tracks.id
                    WHERE \(Self.replayGainAlbumPredicate())
                    ORDER BY tracks.id
                    """,
                    arguments: [albumKey.title, albumKey.owner]
                ).map { row in
                    (row["id"], row["path"])
                }
            }
            let trackIDs = item.members.map(\.trackID)
            guard !trackIDs.isEmpty else { return [] }
            let placeholders = Array(repeating: "?", count: trackIDs.count).joined(separator: ", ")
            return try Row.fetchAll(
                database,
                sql: "SELECT id, path FROM tracks WHERE id IN (\(placeholders))",
                arguments: StatementArguments(trackIDs)
            ).map { row in
                (row["id"], row["path"])
            }
        }
        var fingerprints: [Int64: ReplayGainFileFingerprint] = [:]
        fingerprints.reserveCapacity(paths.count)
        for (trackID, path) in paths {
            if !ignoringCancellation {
                try Task.checkCancellation()
            }
            fingerprints[trackID] = ignoringCancellation
                ? Self.fileFingerprintIgnoringCancellation(path: path)
                : Self.fileFingerprint(path: path)
            if !ignoringCancellation {
                try Task.checkCancellation()
            }
        }
        return fingerprints
    }
 }
