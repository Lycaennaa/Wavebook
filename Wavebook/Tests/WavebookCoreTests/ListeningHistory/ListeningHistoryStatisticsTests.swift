import Foundation
@testable import WavebookCore
import XCTest

extension ListeningHistoryTests {
    func testSummariesAndRankingsRejectNegativeOrNonfiniteTotals() {
        let summary = ListeningStatisticsSummary(
            qualifiedPlayCount: -1,
            listenedSeconds: .infinity,
            uniqueSongCount: -2,
            uniqueArtistCount: -3,
            skipCount: -4
        )
        XCTAssertEqual(summary, ListeningStatisticsSummary())

        let ranking = ListeningRankingEntry(
            id: "song-1",
            dimension: .song,
            displayName: " Song ",
            qualifiedPlayCount: -1,
            listenedSeconds: .nan
        )
        XCTAssertEqual(ranking.displayName, "Song")
        XCTAssertEqual(ranking.qualifiedPlayCount, 0)
        XCTAssertEqual(ranking.listenedSeconds, 0)
    }
    func testRankingOrderingBreaksCaseOnlyNamesByRawValue() {
        for dimension in [ListeningStatisticsDimension.artist, .genre] {
            let entries = ["artist", "Artist"].map { name in
                ListeningRankingEntry(
                    id: name,
                    dimension: dimension,
                    displayName: name,
                    qualifiedPlayCount: 1,
                    listenedSeconds: 1
                )
            }

            XCTAssertEqual(
                entries.sorted(by: LibraryDatabase.rankingPrecedes).map(\.displayName),
                ["Artist", "artist"]
            )
        }
    }

    func testSnapshotMetadataSplitAndTrackRemovalPreserveHistoricalEvent() throws {
        let database = try LibraryDatabase(inMemory: true)
         let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
             .appending(path: ".tmp/listening-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let rootPath = root.path
        let rootID = try database.addRoot(path: rootPath)
        var track = Track(
            path: root.appending(path: "song.flac").path,
            title: "Song",
            artistDisplay: "Artist A",
            albumTitle: "Album",
            albumArtist: nil,
            genreDisplay: "Rock",
            duration: 60,
            format: "flac"
        )
        track.id = try database.save(track: track, rootID: rootID)
         let first = try database.createOrReuseListeningSnapshot(
             track: track,
             openedDuration: 60,
             openedFormat: "flac",
             expectedGeneration: 0
         )
        XCTAssertEqual(try database.createOrReuseListeningSnapshot(first, expectedGeneration: 0), first)
        let state = try database.listeningHistoryState()
        let eventID = UUID()
         XCTAssertEqual(
             try database.beginListeningEvent(
                 eventID: eventID,
                 expectedGeneration: state.generation,
                 snapshotID: try XCTUnwrap(first.id)
             ),
             .applied
         )
         XCTAssertEqual(try database.finishListeningEvent(
             request: .init(
                 eventID: eventID,
                 expectedGeneration: state.generation,
                 endedAtUTC: Date(timeIntervalSince1970: 10),
                 endReason: .naturalCompletion,
                 details: .init(
                     endedUTCOffsetSeconds: 0,
                     endPosition: 1,
                     daySlices: []
                 )
             )
         ), .applied)

        track.artistDisplay = "Artist B"
         let changed = try database.createOrReuseListeningSnapshot(
             track: track,
             openedDuration: 60,
             openedFormat: "flac",
             expectedGeneration: 0
         )
        XCTAssertNotEqual(first.id, changed.id)
        XCTAssertEqual(try database.pruneMissingTracks(rootPath: rootPath, existingPaths: []), 1)
        XCTAssertEqual(try database.listeningSnapshot(id: try XCTUnwrap(first.id))?.liveTrackID, nil)
        XCTAssertEqual(try database.listeningEvent(id: eventID)?.snapshotID, first.id)
    }

    func testStatisticsAggregateMetadataRescanSnapshotsByStableCatalogTrackID() throws {
        let database = try LibraryDatabase(inMemory: true)
        let root = try makeStatisticsTestRoot()

        let rootID = try database.addRoot(path: root.path)
        var track = Track(
            path: root.appending(path: "song.flac").path,
            title: "Song",
            artistDisplay: "Artist A",
            albumTitle: "Album",
            genreDisplay: "Rock",
            duration: 60,
            format: "flac"
        )
        track.id = try database.save(track: track, rootID: rootID)
        let trackID = try XCTUnwrap(track.id)

        let first = try database.createOrReuseListeningSnapshot(
            track: track,
            openedDuration: 20,
            openedFormat: "flac",
            expectedGeneration: 0
        )
        let firstDay = try XCTUnwrap(
            ListeningLocalDay(date: Date(timeIntervalSince1970: 1_704_110_401), timeZone: .current)
        )
        try recordFinishedEvent(
            in: database,
            snapshotID: try XCTUnwrap(first.id),
            startAtUTC: Date(timeIntervalSince1970: 1_704_110_400),
            day: firstDay,
            listenedSeconds: 10
        )

        track.artistDisplay = "Artist B"
        track.id = try database.save(track: track, rootID: rootID)
        XCTAssertEqual(track.id, trackID)
        let second = try database.createOrReuseListeningSnapshot(
            track: track,
            openedDuration: 20,
            openedFormat: "flac",
            createdAtUTC: Date(timeIntervalSince1970: 2),
            expectedGeneration: 0
        )
        XCTAssertNotEqual(first.id, second.id)
        let secondDay = try XCTUnwrap(
            ListeningLocalDay(date: Date(timeIntervalSince1970: 1_672_574_401), timeZone: .current)
        )
        try recordFinishedEvent(
            in: database,
            snapshotID: try XCTUnwrap(second.id),
            startAtUTC: Date(timeIntervalSince1970: 1_672_574_400),
            day: secondDay,
            listenedSeconds: 20,
            includeSkip: true
        )

        try assertRescannedStatistics(
            database: database,
            trackID: trackID,
            firstDay: firstDay,
            secondDay: secondDay
        )
    }

    func testStatisticsUseSnapshotIDFallbackAfterCatalogTrackDeletion() throws {
        let database = try LibraryDatabase(inMemory: true)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".tmp/listening-deleted-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let rootID = try database.addRoot(path: root.path)
        var track = Track(
            path: root.appending(path: "song.flac").path,
            title: "Original Song",
            artistDisplay: "Artist A",
            albumTitle: "Album",
            genreDisplay: "Rock",
            duration: 60,
            format: "flac"
        )
        track.id = try database.save(track: track, rootID: rootID)
        let first = try database.createOrReuseListeningSnapshot(
            track: track,
            openedDuration: 20,
            openedFormat: "flac",
            expectedGeneration: 0
        )
        let day = try XCTUnwrap(ListeningLocalDay(date: Date(timeIntervalSince1970: 1_704_110_401), timeZone: .current))
        try recordFinishedEvent(
            in: database,
            snapshotID: try XCTUnwrap(first.id),
            startAtUTC: Date(timeIntervalSince1970: 1_704_110_400),
            day: day,
            listenedSeconds: 10
        )

        track.title = "Renamed Song"
        track.artistDisplay = "Artist B"
        track.id = try database.save(track: track, rootID: rootID)
        let second = try database.createOrReuseListeningSnapshot(
            track: track,
            openedDuration: 20,
            openedFormat: "flac",
            createdAtUTC: Date(timeIntervalSince1970: 2),
            expectedGeneration: 0
        )
        try recordFinishedEvent(
            in: database,
            snapshotID: try XCTUnwrap(second.id),
            startAtUTC: Date(timeIntervalSince1970: 1_704_110_460),
            day: day,
            listenedSeconds: 10,
            includeSkip: true
        )

        let firstID = try XCTUnwrap(first.id)
        let secondID = try XCTUnwrap(second.id)
         try assertDeletedSnapshotStatistics(
             database: database,
             rootPath: root.path,
             firstID: firstID,
             secondID: secondID
         )
    }

     private func assertDeletedSnapshotStatistics(
         database: LibraryDatabase,
         rootPath: String,
         firstID: Int64,
         secondID: Int64
     ) throws {
         XCTAssertEqual(try database.pruneMissingTracks(rootPath: rootPath, existingPaths: []), 1)
         XCTAssertNil(try database.listeningSnapshot(id: firstID)?.liveTrackID)
         XCTAssertNil(try database.listeningSnapshot(id: secondID)?.liveTrackID)

         let summary = try database.listeningStatisticsSummary(year: 2024)
         XCTAssertEqual(summary.qualifiedPlayCount, 2)
         XCTAssertEqual(summary.listenedSeconds, 20)
         XCTAssertEqual(summary.uniqueSongCount, 2)
         XCTAssertEqual(summary.skipCount, 1)

         let songs = try database.listeningRankings(dimension: .song, year: 2024)
         XCTAssertEqual(songs.count, 2)
         XCTAssertEqual(
             Set(songs.map(\.id)),
             Set(["snapshot:\(firstID)", "snapshot:\(secondID)"])
         )
         let titlesByID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0.displayName) })
         XCTAssertEqual(titlesByID["snapshot:\(firstID)"], "Original Song")
         XCTAssertEqual(titlesByID["snapshot:\(secondID)"], "Renamed Song")

         let skipped = try database.listeningSkippedSongs(year: 2024)
         XCTAssertEqual(skipped.map(\.title), ["Renamed Song"])
         XCTAssertEqual(skipped.first?.artistDisplay, "Artist B")
         XCTAssertEqual(skipped.first?.skipCount, 1)
     }
     private func assertRescannedStatistics(
         database: LibraryDatabase,
         trackID: Int64,
         firstDay: ListeningLocalDay,
         secondDay: ListeningLocalDay
     ) throws {
         let yearSummary = try database.listeningStatisticsSummary(year: 2024)
         XCTAssertEqual(yearSummary.qualifiedPlayCount, 1)
         XCTAssertEqual(yearSummary.listenedSeconds, 10)
         XCTAssertEqual(yearSummary.uniqueSongCount, 1)
         XCTAssertEqual(yearSummary.skipCount, 0)

         let lifetimeSummary = try database.listeningStatisticsSummary()
         XCTAssertEqual(lifetimeSummary.qualifiedPlayCount, 2)
         XCTAssertEqual(lifetimeSummary.listenedSeconds, 30)
         XCTAssertEqual(lifetimeSummary.uniqueSongCount, 1)
         XCTAssertEqual(lifetimeSummary.skipCount, 1)

         let songs = try database.listeningRankings(dimension: .song)
         XCTAssertEqual(songs.count, 1)
         XCTAssertEqual(songs.first?.id, "track:\(trackID)")
         XCTAssertEqual(songs.first?.displayName, "Song")
         XCTAssertEqual(songs.first?.qualifiedPlayCount, 2)
         XCTAssertEqual(songs.first?.listenedSeconds, 30)
         XCTAssertEqual(
             try database.listeningRankings(dimension: .song, year: 2024).first?.qualifiedPlayCount,
             1
         )

         let skipped = try database.listeningSkippedSongs()
         XCTAssertEqual(skipped.count, 1)
         XCTAssertEqual(skipped.first?.title, "Song")
         XCTAssertEqual(skipped.first?.artistDisplay, "Artist B")
         XCTAssertEqual(skipped.first?.skipCount, 1)
         XCTAssertEqual(try database.qualifiedPlayTimeline(day: firstDay).entries.first?.title, "Song")
         XCTAssertEqual(
             try database.qualifiedPlayTimeline(day: secondDay).entries.first?.artistDisplay,
             "Artist B"
         )
     }
    private func makeStatisticsTestRoot() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".tmp/listening-rescan-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

}
