import Foundation
import GRDB

extension LibraryDatabase {
    enum ReplayGainAlbumQueryStage: Hashable, Sendable {
        case memberCount
        case memberRows
        case oversizedValidation
        case oversizedMarking
    }

    struct ReplayGainAlbumQueryEvent: Sendable {
        let stage: ReplayGainAlbumQueryStage
        let sql: String
    }

    enum ReplayGainAlbumQueryTesting {
        @TaskLocal
        static var observer: (@Sendable (ReplayGainAlbumQueryEvent) -> Void)?

        static func record(_ event: ReplayGainAlbumQueryEvent) {
            observer?(event)
        }
    }

    func prepareReplayGainQueue() throws {
        try writer.write { database in
            try Self.recoverReplayGainClaims(db: database)
            try database.execute(
                sql: """
                UPDATE replayGainAnalysis SET
                    trackGainDB = NULL, trackPeak = NULL, trackGainSource = NULL,
                    albumGainDB = NULL, albumPeak = NULL, albumGainSource = NULL, albumGeneration = NULL,
                    analysisState = ?, errorReason = NULL, errorAt = NULL, claimToken = NULL,
                    trackRevision = trackRevision + 1,
                    analyzerVersion = ?, tagSchemaVersion = ?
                WHERE analyzerVersion <> ? OR tagSchemaVersion <> ?
                """,
                arguments: [
                    ReplayGainAnalysisState.pending.rawValue,
                    ReplayGain.analyzerVersion,
                    ReplayGain.tagSchemaVersion,
                    ReplayGain.analyzerVersion,
                    ReplayGain.tagSchemaVersion
                ]
            )
        }
    }

    func recoverReplayGainClaims() throws {
        try writer.write { database in
            try Self.recoverReplayGainClaims(db: database)
        }
    }

    private static func recoverReplayGainClaims(db database: Database) throws {
        try database.execute(
            sql: "UPDATE replayGainAnalysis SET analysisState = ?, claimToken = NULL WHERE analysisState = ?",
            arguments: [ReplayGainAnalysisState.pending.rawValue, ReplayGainAnalysisState.running.rawValue]
        )
    }
    static func replayGainAlbumPredicate(alias: String = "tracks") -> String {
        "\(alias).albumTitle = ? AND (\(albumOwnerExpression(alias: alias))) = ?"
    }

    static func replayGainAlbumMemberCount(for albumKey: AlbumKey, db database: Database) throws -> Int {
        try Self.checkCatalogCancellation()
        let limit = ReplayGainAnalyzer.maximumAlbumTrackCount + 1
        let sql = """
            SELECT COUNT(*) AS trackCount
            FROM (
                SELECT tracks.id
                FROM tracks
                JOIN replayGainAnalysis ON replayGainAnalysis.trackId = tracks.id
                WHERE \(replayGainAlbumPredicate())
                ORDER BY tracks.id
                LIMIT ?
            )
            """
        ReplayGainAlbumQueryTesting.record(.init(stage: .memberCount, sql: sql))
        guard let row = try Row.fetchOne(
            database,
            sql: sql,
            arguments: [albumKey.title, albumKey.owner, limit]
        ) else {
            return 0
        }
        try Self.checkCatalogCancellation()
        return row["trackCount"]
    }

    static func replayGainAlbumMemberRows(
        for albumKey: AlbumKey,
        trackIDs: Set<Int64>,
        db database: Database
    ) throws -> [Row] {
        guard !trackIDs.isEmpty,
              trackIDs.count <= ReplayGainAnalyzer.maximumAlbumTrackCount else {
            return []
        }
        try Self.checkCatalogCancellation()
        let sortedTrackIDs = trackIDs.sorted()
        let placeholders = Array(repeating: "?", count: sortedTrackIDs.count).joined(separator: ", ")
        let sql = """
            SELECT tracks.id, tracks.path, tracks.albumTitle, tracks.albumArtist, tracks.artistDisplay, tracks.duration,
                   replayGainAnalysis.analysisState, replayGainAnalysis.sourceMtime, replayGainAnalysis.sourceFileSize,
                   replayGainAnalysis.sourceContentFingerprint,
                   replayGainAnalysis.trackGainDB, replayGainAnalysis.trackPeak,
                   replayGainAnalysis.errorReason, replayGainAnalysis.errorAt,
                   replayGainAnalysis.trackRevision,
                   replayGainAnalysis.analyzerVersion, replayGainAnalysis.tagSchemaVersion
            FROM tracks
            JOIN replayGainAnalysis ON replayGainAnalysis.trackId = tracks.id
            WHERE \(replayGainAlbumPredicate()) AND tracks.id IN (\(placeholders))
            ORDER BY tracks.id
            LIMIT ?
            """
        ReplayGainAlbumQueryTesting.record(.init(stage: .memberRows, sql: sql))
        var arguments: StatementArguments = [albumKey.title, albumKey.owner]
        for trackID in sortedTrackIDs {
            arguments += [trackID]
        }
        arguments += [ReplayGainAnalyzer.maximumAlbumTrackCount]
        let rows = try Row.fetchAll(database, sql: sql, arguments: arguments)
        try Self.checkCatalogCancellation()
        return rows
    }

    static func replayGainAlbumStats(
        for albumKey: AlbumKey,
        db database: Database
    ) throws -> (trackCount: Int, hasInProgress: Bool) {
        let trackCount = try replayGainAlbumMemberCount(for: albumKey, db: database)
        guard let row = try Row.fetchOne(database, sql: """
            SELECT EXISTS (
                SELECT 1
                FROM tracks
                JOIN replayGainAnalysis ON replayGainAnalysis.trackId = tracks.id
                WHERE replayGainAnalysis.analysisState IN (?, ?)
                  AND \(replayGainAlbumPredicate())
                LIMIT 1
            ) AS hasInProgress
            """, arguments: [
                ReplayGainAnalysisState.pending.rawValue,
                ReplayGainAnalysisState.running.rawValue,
                albumKey.title,
                albumKey.owner
            ]) else {
            return (trackCount, false)
        }
        try Self.checkCatalogCancellation()
        let hasInProgress: Int? = row["hasInProgress"]
        return (trackCount, hasInProgress == 1)
    }

    static func clearReplayGainValues(trackID: Int64, db database: Database) throws {
        try database.execute(
            sql: """
            UPDATE replayGainAnalysis SET
                trackGainDB = NULL, trackPeak = NULL, trackGainSource = NULL,
                albumGainDB = NULL, albumPeak = NULL, albumGainSource = NULL, albumGeneration = NULL,
                analysisState = ?, errorReason = NULL, errorAt = NULL, claimToken = NULL,
                trackRevision = trackRevision + 1,
                analyzerVersion = ?, tagSchemaVersion = ?
            WHERE trackId = ?
            """,
            arguments: [
                ReplayGainAnalysisState.pending.rawValue,
                ReplayGain.analyzerVersion,
                ReplayGain.tagSchemaVersion,
                trackID
            ]
        )
    }

    static func invalidateAlbumValues(
        for albumKeys: Set<AlbumKey>,
        requeueReady: Bool = true,
        ignoringCancellation: Bool = false,
        db database: Database
    ) throws {
        let validAlbumKeys = Set(albumKeys.filter { !$0.title.isEmpty && !$0.owner.isEmpty })
        guard !validAlbumKeys.isEmpty else { return }
        if !ignoringCancellation {
            try Self.checkCatalogCancellation()
        }
        CatalogReconcileTesting.recordAlbumInvalidation(validAlbumKeys)
        if !ignoringCancellation {
            try Self.checkCatalogCancellation()
        }
        for albumKey in validAlbumKeys {
            try invalidateAlbumValues(
                for: albumKey,
                requeueReady: requeueReady,
                ignoringCancellation: ignoringCancellation,
                db: database
            )
        }
    }

    private static func invalidateAlbumValues(
        for albumKey: AlbumKey,
        requeueReady: Bool,
        ignoringCancellation: Bool,
        db database: Database
    ) throws {
        if !ignoringCancellation {
            try Self.checkCatalogCancellation()
        }
        let query = replayGainAlbumInvalidationQuery(albumKey: albumKey, requeueReady: requeueReady)
        try database.execute(sql: query.sql, arguments: query.arguments)
        if !ignoringCancellation {
            try Self.checkCatalogCancellation()
        }
    }

    private static func replayGainAlbumInvalidationQuery(
        albumKey: AlbumKey,
        requeueReady: Bool
    ) -> (sql: String, arguments: StatementArguments) {
        let arguments = replayGainAlbumInvalidationArguments(albumKey: albumKey, requeueReady: requeueReady)
        let sql = replayGainAlbumInvalidationSQL(requeueReady: requeueReady)
        return (sql: sql, arguments: arguments)
    }

    private static func replayGainAlbumInvalidationArguments(
        albumKey: AlbumKey,
        requeueReady: Bool
    ) -> StatementArguments {
        var arguments: StatementArguments = []
        if requeueReady {
            arguments += [
                "\(Self.replayGainAlbumFailureMarker)%",
                ReplayGainAnalysisState.pending.rawValue,
                ReplayGainAnalysisState.ready.rawValue,
                ReplayGainAnalysisState.pending.rawValue
            ]
        }
        arguments += [
            "\(Self.replayGainAlbumFailureMarker)%",
            "\(Self.replayGainAlbumFailureMarker)%",
            albumKey.title,
            albumKey.owner
        ]
        return arguments
    }

    private static func replayGainAlbumInvalidationSQL(requeueReady: Bool) -> String {
        let nextState = requeueReady
            ? "CASE WHEN errorReason LIKE ? AND trackGainDB IS NOT NULL AND trackPeak IS NOT NULL THEN ? "
                + "WHEN analysisState = ? THEN ? ELSE analysisState END"
            : "analysisState"
        return """
            UPDATE replayGainAnalysis SET
                albumGainDB = NULL, albumPeak = NULL, albumGainSource = NULL, albumGeneration = NULL,
                analysisState = \(nextState),
                errorReason = CASE
                    WHEN errorReason LIKE ? THEN CASE
                        WHEN instr(errorReason, char(10)) > 0 THEN substr(
                            errorReason, instr(errorReason, char(10)) + 1
                        )
                        ELSE NULL
                    END
                    ELSE errorReason
                END,
                errorAt = CASE
                    WHEN errorReason LIKE ? AND instr(errorReason, char(10)) = 0 THEN NULL
                    ELSE errorAt
                END
            WHERE replayGainAnalysis.trackId IN (
                SELECT tracks.id
                FROM tracks
                WHERE \(replayGainAlbumPredicate())
            )
            """
    }

    static func replayGainData(
        db database: Database,
        where clause: String,
        arguments: StatementArguments
    ) throws -> ReplayGainNormalizationData? {
        guard let row = try Row.fetchOne(database, sql: """
            SELECT tracks.id, tracks.path,
                   replayGainAnalysis.trackGainDB, replayGainAnalysis.trackPeak, replayGainAnalysis.trackGainSource,
                   replayGainAnalysis.albumGainDB, replayGainAnalysis.albumPeak, replayGainAnalysis.albumGainSource,
                   replayGainAnalysis.albumGeneration, replayGainAnalysis.analysisState,
                   replayGainAnalysis.errorReason, replayGainAnalysis.errorAt,
                   replayGainAnalysis.sourceMtime, replayGainAnalysis.sourceFileSize,
                   replayGainAnalysis.sourceContentFingerprint,
                   replayGainAnalysis.trackRevision,
                   replayGainAnalysis.analyzerVersion, replayGainAnalysis.tagSchemaVersion
            FROM tracks
            JOIN replayGainAnalysis ON replayGainAnalysis.trackId = tracks.id
            WHERE \(clause)
            LIMIT 1
            """, arguments: arguments) else {
            return nil
        }
        return ReplayGainNormalizationData(
            trackID: row["id"],
            path: row["path"],
            track: scopeValues(from: row, prefix: "track"),
            album: scopeValues(from: row, prefix: "album"),
            albumGeneration: row["albumGeneration"],
            state: ReplayGainAnalysisState(rawValue: row["analysisState"]) ?? .pending,
            errorReason: row["errorReason"],
            errorAt: row["errorAt"],
            fingerprint: fingerprint(from: row),
            trackRevision: row["trackRevision"],
            analyzerVersion: row["analyzerVersion"],
            tagSchemaVersion: row["tagSchemaVersion"]
        )
    }

    static func replayGainRow(trackID: Int64, db database: Database) throws -> Row? {
        try Row.fetchOne(database, sql: """
            SELECT tracks.id, tracks.path, tracks.albumTitle, tracks.albumArtist, tracks.artistDisplay,
                   replayGainAnalysis.analysisState, replayGainAnalysis.sourceMtime, replayGainAnalysis.sourceFileSize,
                   replayGainAnalysis.sourceContentFingerprint,
                   replayGainAnalysis.trackGainDB, replayGainAnalysis.trackPeak,
                   replayGainAnalysis.errorReason, replayGainAnalysis.errorAt,
                   replayGainAnalysis.claimToken, replayGainAnalysis.trackRevision,
                   replayGainAnalysis.analyzerVersion, replayGainAnalysis.tagSchemaVersion
            FROM tracks
            JOIN replayGainAnalysis ON replayGainAnalysis.trackId = tracks.id
            WHERE tracks.id = ?
            """, arguments: [trackID])
    }

    static func pendingReplayGainItem(from row: Row, claimToken: String) -> ReplayGainPendingItem {
        ReplayGainPendingItem(
            trackID: row["id"],
            path: row["path"],
            albumKey: albumKey(from: row) ?? AlbumKey(title: "", owner: ""),
            duration: row["duration"],
            fingerprint: fingerprint(from: row),
            claimToken: claimToken,
            cachedTrackValues: scopeValues(from: row, prefix: "track")
        )
    }

    static func scopeValues(from row: Row, prefix: String) -> ReplayGainScopeValues? {
        let gainDB: Double? = row["\(prefix)GainDB"]
        let peak: Double? = row["\(prefix)Peak"]
        let sourceValue: String? = row["\(prefix)GainSource"]
        let gain = gainDB.flatMap { decibels in
            sourceValue
                .flatMap(ReplayGainGainSource.init(rawValue:))
                .map { ReplayGainGain(decibels: decibels, source: $0) }
        }
        guard gain != nil || peak != nil else { return nil }
        return ReplayGainScopeValues(gain: gain, samplePeak: peak)
    }

    static func fingerprint(from row: Row) -> ReplayGainFileFingerprint {
        ReplayGainFileFingerprint(
            modificationDate: date(from: row, column: "sourceMtime"),
            fileSize: row["sourceFileSize"],
            contentFingerprint: row["sourceContentFingerprint"]
        )
    }

    static func claimToken(from row: Row) -> String? {
        row["claimToken"]
    }

    static func fileFingerprint(path: String) -> ReplayGainFileFingerprint {
        ReplayGainFileFingerprint.current(path: path)
    }
    static func fileFingerprintIgnoringCancellation(path: String) -> ReplayGainFileFingerprint {
        ReplayGainFileFingerprint.currentIgnoringCancellation(path: path)
    }

    static func fingerprintsMatch(_ current: ReplayGainFileFingerprint, _ stored: ReplayGainFileFingerprint) -> Bool {
        ReplayGainFileFingerprint.matches(current, stored)
    }

    static func databaseTimestamp(_ date: Date?) -> Double? {
        date?.timeIntervalSinceReferenceDate
    }

    static func date(from row: Row, column: String) -> Date? {
        let value: DatabaseValue = row[column]
        switch value.storage {
        case let .double(timestamp):
            return Date(timeIntervalSinceReferenceDate: timestamp)
        case let .int64(timestamp):
            return Date(timeIntervalSinceReferenceDate: TimeInterval(timestamp))
        default:
            return Date.fromDatabaseValue(value)
        }
    }

    static func invalidateReplayGainForFileChange(
        trackID: Int64,
        currentFingerprint: ReplayGainFileFingerprint,
        row: Row,
        ignoringCancellation: Bool = false,
        db database: Database
    ) throws {
        if let albumKey = albumKey(from: row) {
            try invalidateAlbumValues(
                for: [albumKey],
                ignoringCancellation: ignoringCancellation,
                db: database
            )
        }
        try database.execute(
            sql: "UPDATE tracks SET mtime = ?, fileSize = ? WHERE id = ?",
            arguments: [databaseTimestamp(currentFingerprint.modificationDate), currentFingerprint.fileSize, trackID]
        )
        try database.execute(
            sql: """
            UPDATE replayGainAnalysis SET
                trackGainDB = NULL, trackPeak = NULL, trackGainSource = NULL,
                albumGainDB = NULL, albumPeak = NULL, albumGainSource = NULL, albumGeneration = NULL,
                analysisState = ?, errorReason = NULL, errorAt = NULL, claimToken = NULL,
                trackRevision = trackRevision + 1,
                sourceMtime = ?, sourceFileSize = ?, sourceContentFingerprint = ?,
                analyzerVersion = ?, tagSchemaVersion = ?
            WHERE trackId = ?
            """,
            arguments: [
                ReplayGainAnalysisState.pending.rawValue,
                databaseTimestamp(currentFingerprint.modificationDate),
                currentFingerprint.fileSize,
                currentFingerprint.contentFingerprint,
                ReplayGain.analyzerVersion,
                ReplayGain.tagSchemaVersion,
                trackID
            ]
        )
    }
}
