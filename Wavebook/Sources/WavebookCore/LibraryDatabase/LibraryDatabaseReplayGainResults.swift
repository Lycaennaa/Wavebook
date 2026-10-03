import Foundation
import GRDB

extension LibraryDatabase {
    private struct TrackCommitRequest {
        let trackID: Int64
        let fingerprint: ReplayGainFileFingerprint
        let currentFingerprint: ReplayGainFileFingerprint
        let claimToken: String
        let gain: ReplayGainGain
        let peak: Double
        let analyzerVersion: Int
        let tagSchemaVersion: Int
    }

    struct TrackCommitInput {
        let trackID: Int64
        let fingerprint: ReplayGainFileFingerprint
        let claimToken: String
        let values: ReplayGainScopeValues
        let analyzerVersion: Int
        let tagSchemaVersion: Int
        let currentFingerprint: ReplayGainFileFingerprint
    }

    private struct AlbumMemberExpectation {
        let fingerprint: ReplayGainFileFingerprint
        let trackRevision: Int
    }

    private struct ChangedAlbumMember {
        let trackID: Int64
        let expected: ReplayGainFileFingerprint
        let current: ReplayGainFileFingerprint
    }

    /// Commits analyzed replay-gain values for one track.
    @discardableResult
    public func commitReplayGainTrackResult(
        trackID: Int64,
        fingerprint: ReplayGainFileFingerprint,
        claimToken: String,
        values: ReplayGainScopeValues,
        analyzerVersion: Int = ReplayGain.analyzerVersion,
        tagSchemaVersion: Int = ReplayGain.tagSchemaVersion
    ) throws -> Bool {
        guard values.isReady else {
            throw ReplayGainDatabaseError.incompleteValues
        }
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
        let committed = try commitReplayGainTrackResult(
            request: TrackCommitInput(
                trackID: trackID,
                fingerprint: fingerprint,
                claimToken: claimToken,
                values: values,
                analyzerVersion: analyzerVersion,
                tagSchemaVersion: tagSchemaVersion,
                currentFingerprint: currentFingerprint
            )
        )
        guard committed else { return false }
        let finalFingerprint = Self.fileFingerprintIgnoringCancellation(path: path)
        guard Self.fingerprintsMatch(finalFingerprint, fingerprint) else {
            _ = try invalidateReplayGainForFileChange(
                trackID: trackID,
                expectedFingerprint: fingerprint,
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

    @discardableResult
    func commitReplayGainTrackResult(request: TrackCommitInput) throws -> Bool {
        guard let gain = request.values.gain, let peak = request.values.samplePeak else {
            throw ReplayGainDatabaseError.incompleteValues
        }
        let trackRequest = TrackCommitRequest(
            trackID: request.trackID,
            fingerprint: request.fingerprint,
            currentFingerprint: request.currentFingerprint,
            claimToken: request.claimToken,
            gain: gain,
            peak: peak,
            analyzerVersion: request.analyzerVersion,
            tagSchemaVersion: request.tagSchemaVersion
        )
        return try writer.write { database in
            try Self.commitReplayGainTrackResult(request: trackRequest, database: database)
        }
    }

    private static func commitReplayGainTrackResult(
        request: TrackCommitRequest,
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
        if let albumKey = Self.albumKey(from: row) {
            try Self.invalidateAlbumValues(for: [albumKey], requeueReady: false, db: database)
        }
        try Self.writeTrackGain(request: request, database: database)
        return true
    }

    private static func writeTrackGain(
        request: TrackCommitRequest,
        database: Database
    ) throws {
        try database.execute(
            sql: """
            UPDATE replayGainAnalysis SET
                trackGainDB = ?, trackPeak = ?, trackGainSource = ?,
                analysisState = ?, errorReason = NULL, errorAt = NULL, claimToken = NULL,
                trackRevision = trackRevision + 1
            WHERE trackId = ?
            """,
            arguments: [
                request.gain.decibels,
                request.peak,
                request.gain.source.rawValue,
                ReplayGainAnalysisState.ready.rawValue,
                request.trackID
            ]
        )
    }
    private struct AlbumCommitRequest {
        let albumKey: AlbumKey
        let expected: [Int64: AlbumMemberExpectation]
        let currentFingerprints: [Int64: ReplayGainFileFingerprint]
        let gain: ReplayGainGain
        let peak: Double
        let analyzerVersion: Int
        let tagSchemaVersion: Int
    }

    /// Commits analyzed replay-gain values for an album.
    @discardableResult
    public func commitReplayGainAlbumResult(
        albumKey: AlbumKey,
        members: [ReplayGainAlbumMember],
        values: ReplayGainScopeValues,
        analyzerVersion: Int = ReplayGain.analyzerVersion,
        tagSchemaVersion: Int = ReplayGain.tagSchemaVersion
    ) throws -> String? {
        guard !albumKey.title.isEmpty, !albumKey.owner.isEmpty else {
            throw ReplayGainDatabaseError.invalidAlbumGroup
        }
        guard values.isReady, let gain = values.gain, let peak = values.samplePeak else {
            throw ReplayGainDatabaseError.incompleteValues
        }
        guard !members.isEmpty,
              members.count <= ReplayGainAnalyzer.maximumAlbumTrackCount,
              Set(members.map(\.trackID)).count == members.count else {
            throw ReplayGainDatabaseError.invalidAlbumGroup
        }
        let expected = Dictionary(
            uniqueKeysWithValues: members.map {
                ($0.trackID, AlbumMemberExpectation(fingerprint: $0.fingerprint, trackRevision: $0.trackRevision))
            }
        )
        let currentFingerprints = try currentReplayGainFingerprints(for: Set(expected.keys))
        guard currentFingerprints.count == expected.count else { return nil }
        let request = AlbumCommitRequest(
            albumKey: albumKey,
            expected: expected,
            currentFingerprints: currentFingerprints,
            gain: gain,
            peak: peak,
            analyzerVersion: analyzerVersion,
            tagSchemaVersion: tagSchemaVersion
        )
        guard let generation = try writer.write({ database in
            try Self.commitAlbumResult(request: request, database: database)
        }) else {
            return nil
        }
        return try verifiedAlbumGeneration(generation, expected: expected)
    }

    private func verifiedAlbumGeneration(
        _ generation: String,
        expected: [Int64: AlbumMemberExpectation]
    ) throws -> String? {
        let finalFingerprints = try currentReplayGainFingerprints(
            for: Set(expected.keys),
            ignoringCancellation: true
        )
        guard finalFingerprints.count == expected.count else {
            try Task.checkCancellation()
            return nil
        }
        var changedMembers: [ChangedAlbumMember] = []
        var finalValidationFailed = false
        for trackID in expected.keys {
            guard let expectedFingerprint = expected[trackID]?.fingerprint,
                  let current = finalFingerprints[trackID] else {
                finalValidationFailed = true
                continue
            }
            if !Self.fingerprintsMatch(current, expectedFingerprint) {
                changedMembers.append(ChangedAlbumMember(
                    trackID: trackID,
                    expected: expectedFingerprint,
                    current: current
                ))
            }
        }
        for member in changedMembers {
            _ = try invalidateReplayGainForFileChange(
                trackID: member.trackID,
                expectedFingerprint: member.expected,
                currentFingerprint: member.current,
                claimToken: nil,
                ignoringCancellation: true
            )
        }
        try Task.checkCancellation()
        guard !finalValidationFailed, changedMembers.isEmpty else { return nil }
        return generation
    }

    private static func commitAlbumResult(
        request: AlbumCommitRequest,
        database: Database
    ) throws -> String? {
        let memberCount = try Self.replayGainAlbumMemberCount(for: request.albumKey, db: database)
        guard memberCount <= ReplayGainAnalyzer.maximumAlbumTrackCount,
              memberCount == request.expected.count else { return nil }
        let rows = try Self.replayGainAlbumMemberRows(
            for: request.albumKey,
            trackIDs: Set(request.expected.keys),
            db: database
        )
        guard Set(rows.map { $0["id"] as Int64 }) == Set(request.expected.keys) else { return nil }
        guard try validateAlbumRows(rows, request: request, database: database) else { return nil }
        let generation = UUID().uuidString
        try applyAlbumValues(request: request, generation: generation, database: database)
        guard try verifyAlbumRows(request: request, database: database) else { return nil }
        return generation
    }

    private static func validateAlbumRows(
        _ rows: [Row],
        request: AlbumCommitRequest,
        database: Database
    ) throws -> Bool {
        for row in rows {
            let trackID: Int64 = row["id"]
            guard let expected = request.expected[trackID],
                  let currentFingerprint = request.currentFingerprints[trackID],
                  expected.fingerprint == Self.fingerprint(from: row),
                  expected.trackRevision == row["trackRevision"],
                  row["analyzerVersion"] == request.analyzerVersion,
                  row["tagSchemaVersion"] == request.tagSchemaVersion else {
                return false
            }
            guard Self.fingerprintsMatch(currentFingerprint, expected.fingerprint) else {
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

    private static let albumValueUpdateSQL = """
        UPDATE replayGainAnalysis SET
            albumGainDB = ?, albumPeak = ?, albumGainSource = ?, albumGeneration = ?,
            analysisState = CASE
                WHEN trackGainDB IS NOT NULL AND trackPeak IS NOT NULL THEN ?
                ELSE analysisState
            END,
            errorReason = CASE
                WHEN trackGainDB IS NOT NULL AND trackPeak IS NOT NULL THEN NULL
                WHEN errorReason LIKE ? THEN CASE
                    WHEN instr(errorReason, char(10)) > 0 THEN substr(
                        errorReason, instr(errorReason, char(10)) + 1
                    )
                    ELSE NULL
                END
                ELSE errorReason
            END,
            errorAt = CASE
                WHEN trackGainDB IS NOT NULL AND trackPeak IS NOT NULL THEN NULL
                ELSE errorAt
            END
        WHERE trackId = ?
        """
    private static func applyAlbumValues(
        request: AlbumCommitRequest,
        generation: String,
        database: Database
    ) throws {
        for trackID in request.expected.keys {
            try applyAlbumValue(
                request: request,
                generation: generation,
                trackID: trackID,
                database: database
            )
        }
    }

    private static func applyAlbumValue(
        request: AlbumCommitRequest,
        generation: String,
        trackID: Int64,
        database: Database
    ) throws {
        try database.execute(
            sql: albumValueUpdateSQL,
            arguments: [
                request.gain.decibels,
                request.peak,
                request.gain.source.rawValue,
                generation,
                ReplayGainAnalysisState.ready.rawValue,
                "\(Self.replayGainAlbumFailureMarker)%",
                trackID
            ]
        )
    }

    private static func verifyAlbumRows(
        request: AlbumCommitRequest,
        database: Database
    ) throws -> Bool {
        for trackID in request.expected.keys {
            guard
                let row = try Self.replayGainRow(trackID: trackID, db: database),
                let expected = request.expected[trackID],
                Self.fingerprint(from: row) == expected.fingerprint
            else {
                return false
            }
        }
        return true
    }
    private func currentReplayGainFingerprints(
        for trackIDs: Set<Int64>,
        ignoringCancellation: Bool = false
    ) throws -> [Int64: ReplayGainFileFingerprint] {
        guard !trackIDs.isEmpty else { return [:] }
        let sortedTrackIDs = trackIDs.sorted()
        let placeholders = Array(repeating: "?", count: sortedTrackIDs.count).joined(separator: ", ")
        let paths: [(Int64, String)] = try writer.read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT id, path FROM tracks WHERE id IN (\(placeholders))",
                arguments: StatementArguments(sortedTrackIDs)
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
