import Foundation
import GRDB
@testable import WavebookCore
import XCTest

extension ReplayGainDatabaseTests {
    func testOversizedAlbumUsesBoundedCountMarkerWithoutMaterializingMembers() throws {
        let root = try makeRoot()
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let trackCount = ReplayGainAnalyzer.maximumAlbumTrackCount + 1
         try database.writer.write { database in
             try database.execute(sql: """
                WITH RECURSIVE numbers(id) AS (
                    SELECT 1
                    UNION ALL
                    SELECT id + 1 FROM numbers WHERE id < ?
                )
                INSERT INTO tracks (
                    rootId, path, title, artistDisplay, albumTitle, albumArtist,
                    genreDisplay, duration, format, searchText, mtime, fileSize, lyricsKey
                )
                SELECT ?, 'oversized-' || id || '.flac', 'Track ' || id, 'Artist', 'Album', 'Artist',
                       '', 1, 'flac', 'track artist album', NULL, NULL, ''
                FROM numbers
                """, arguments: [trackCount, rootID])
             try database.execute(sql: """
                INSERT INTO replayGainAnalysis (
                    trackId, trackGainDB, trackPeak, trackGainSource, analysisState,
                    sourceMtime, sourceFileSize, analyzerVersion, tagSchemaVersion
                )
                SELECT id, -4, 0.5, 'measured', ?, mtime, fileSize, ?, ?
                FROM tracks
                WHERE rootId = ?
                """, arguments: [
                    ReplayGainAnalysisState.ready.rawValue,
                    ReplayGain.analyzerVersion,
                    ReplayGain.tagSchemaVersion,
                    rootID
                ])
        }

        let item = try XCTUnwrap(database.nextReplayGainAlbumAnalysisItem())
        XCTAssertEqual(item.trackCount, trackCount)
        XCTAssertTrue(item.members.isEmpty)
        XCTAssertTrue(item.allPaths.isEmpty)
        XCTAssertTrue(item.availablePaths.isEmpty)
        XCTAssertEqual(item.displayPath, "oversized-1.flac")
         XCTAssertTrue(
             try database.recordReplayGainAlbumFailure(
                 item: item,
                 reason: "Album group exceeds 500 tracks: \(trackCount)"
             )
         )
        XCTAssertEqual(try database.replayGainStatusCounts(), ReplayGainAnalysisStatusCounts(failed: trackCount))
         XCTAssertEqual(
             try database.replayGainData(trackID: 1)?.errorReason,
             "[Album] Album group exceeds 500 tracks: \(trackCount)"
         )
    }

    func testAlbumCommitRejectsGrowthPastLimitBeforeMaterializingMembership() throws {
        let root = try makeRoot()
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let albumKey = AlbumKey(title: "Album", owner: "Artist")
        let limit = ReplayGainAnalyzer.maximumAlbumTrackCount
        try insertReadyAlbumTracks(count: limit, rootID: rootID, database: database)
        let item = try XCTUnwrap(database.nextReplayGainAlbumAnalysisItem())
        XCTAssertEqual(item.trackCount, limit)
        XCTAssertEqual(item.members.count, limit)

        _ = try insertReadyAlbumMembers(count: 2, rootID: rootID, database: database)
         let stats = try database.writer.read { database in
             try LibraryDatabase.replayGainAlbumStats(for: albumKey, db: database)
         }
        XCTAssertEqual(stats.trackCount, limit + 1)
        XCTAssertFalse(stats.hasInProgress)
        let capture = ReplayGainAlbumQueryCapture()
        let commitResult = try LibraryDatabase.ReplayGainAlbumQueryTesting.$observer.withValue({ event in
            capture.append(event)
         }, operation: {
             try database.commitReplayGainAlbumResult(
                 albumKey: albumKey,
                 members: item.members,
                 values: readyAlbumValues
             )
         })
        XCTAssertNil(commitResult)
        XCTAssertEqual(capture.events(for: .memberCount).count, 1)
        XCTAssertTrue(capture.events(for: .memberRows).isEmpty)
        XCTAssertNil(try database.replayGainData(trackID: item.members[0].trackID)?.album)
        XCTAssertEqual(
            try database.replayGainStatusCounts(),
            ReplayGainAnalysisStatusCounts(ready: limit + 2)
        )
    }

    func testAlbumCommitUsesBoundedExpectedMemberMembershipQuery() throws {
        let root = try makeRoot()
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let albumKey = AlbumKey(title: "Album", owner: "Artist")
        try insertReadyAlbumTracks(count: 2, rootID: rootID, database: database)
        let item = try XCTUnwrap(database.nextReplayGainAlbumAnalysisItem())
        let capture = ReplayGainAlbumQueryCapture()

        let generation = try LibraryDatabase.ReplayGainAlbumQueryTesting.$observer.withValue({ event in
            capture.append(event)
         }, operation: {
             try database.commitReplayGainAlbumResult(
                 albumKey: albumKey,
                 members: item.members,
                 values: readyAlbumValues
             )
         })

        XCTAssertNotNil(generation)
        let memberRows = capture.events(for: .memberRows)
        XCTAssertEqual(memberRows.count, 1)
        XCTAssertTrue(memberRows[0].sql.contains("tracks.id IN ("))
        XCTAssertTrue(memberRows[0].sql.contains("LIMIT ?"))
    }

    func testAlbumFailureUsesBoundedExpectedMemberMembershipQuery() throws {
        let root = try makeRoot()
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        try insertReadyAlbumTracks(count: 2, rootID: rootID, database: database)
        let item = try XCTUnwrap(database.nextReplayGainAlbumAnalysisItem())
        let capture = ReplayGainAlbumQueryCapture()

        let recorded = try LibraryDatabase.ReplayGainAlbumQueryTesting.$observer.withValue({ event in
            capture.append(event)
         }, operation: {
            try database.recordReplayGainAlbumFailure(item: item, reason: "decode failed")
         })

        XCTAssertTrue(recorded)
        let memberRows = capture.events(for: .memberRows)
        XCTAssertEqual(memberRows.count, 1)
        XCTAssertTrue(memberRows[0].sql.contains("tracks.id IN ("))
        XCTAssertTrue(memberRows[0].sql.contains("LIMIT ?"))
    }

    func testAlbumFailureHandlesGrowthPastLimitWithBoundedMembershipMarking() throws {
        let root = try makeRoot()
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let limit = ReplayGainAnalyzer.maximumAlbumTrackCount
        try insertReadyAlbumTracks(count: limit, rootID: rootID, database: database)
        let item = try XCTUnwrap(database.nextReplayGainAlbumAnalysisItem())

        _ = try insertReadyAlbumMembers(count: 2, rootID: rootID, database: database)
        let capture = ReplayGainAlbumQueryCapture()
        let recorded = try LibraryDatabase.ReplayGainAlbumQueryTesting.$observer.withValue({ event in
            capture.append(event)
         }, operation: {
            try database.recordReplayGainAlbumFailure(item: item, reason: "decode failed")
         })
        XCTAssertTrue(recorded)
        XCTAssertTrue(capture.events(for: .memberRows).isEmpty)
        let validationQueries = capture.events(for: .oversizedValidation)
        let markingQueries = capture.events(for: .oversizedMarking)
        XCTAssertFalse(validationQueries.isEmpty)
        XCTAssertFalse(markingQueries.isEmpty)
        XCTAssertTrue(validationQueries.allSatisfy { $0.sql.contains("LIMIT 1") })
        XCTAssertTrue(markingQueries.allSatisfy { $0.sql.contains("LIMIT 1") })
        XCTAssertEqual(
            try database.replayGainStatusCounts(),
            ReplayGainAnalysisStatusCounts(failed: limit + 2)
        )
        XCTAssertEqual(
            try database.replayGainData(trackID: item.members[0].trackID)?.errorReason,
            "[Album] decode failed"
        )
    }

    func testOversizedAlbumFailureHonorsCancellationBeforeMarking() throws {
        let root = try makeRoot()
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let limit = ReplayGainAnalyzer.maximumAlbumTrackCount
        try insertReadyAlbumTracks(count: limit, rootID: rootID, database: database)
        let item = try XCTUnwrap(database.nextReplayGainAlbumAnalysisItem())
        _ = try insertReadyAlbumMembers(count: 2, rootID: rootID, database: database)

        let token = LibraryDatabaseCancellationToken()
        token.cancel()
        XCTAssertThrowsError(
            try LibraryDatabase.withCatalogCancellationToken(token) {
                try database.recordReplayGainAlbumFailure(item: item, reason: "decode failed")
            }
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(
            try database.replayGainStatusCounts(),
            ReplayGainAnalysisStatusCounts(ready: limit + 2)
        )
    }

    func testOversizedAlbumFailureCancellationDuringMarkingRollsBack() throws {
        let root = try makeRoot()
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let limit = ReplayGainAnalyzer.maximumAlbumTrackCount
        try insertReadyAlbumTracks(count: limit, rootID: rootID, database: database)
        let item = try XCTUnwrap(database.nextReplayGainAlbumAnalysisItem())
        _ = try insertReadyAlbumMembers(count: 2, rootID: rootID, database: database)

        let probe = ReplayGainAlbumCancellationProbe(
            token: LibraryDatabaseCancellationToken(),
            stage: .oversizedMarking,
            cancellationCheckpoint: 2
        )
        XCTAssertThrowsError(
            try LibraryDatabase.ReplayGainAlbumQueryTesting.$observer.withValue({ event in
                probe.observe(event)
             }, operation: {
                try LibraryDatabase.withCatalogCancellationToken(probe.token) {
                    try database.recordReplayGainAlbumFailure(item: item, reason: "decode failed")
                }
             })
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(
            try database.replayGainStatusCounts(),
            ReplayGainAnalysisStatusCounts(ready: limit + 2)
        )
    }

}
