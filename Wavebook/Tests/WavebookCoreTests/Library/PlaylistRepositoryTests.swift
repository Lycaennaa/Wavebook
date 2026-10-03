import Foundation
@testable import WavebookCore
import XCTest

final class PlaylistRepositoryTests: XCTestCase {
    func testManualPlaylistLifecyclePreservesSelectionAndUnavailableSnapshot() throws {
        let root = try makeRoot(named: "manual")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let firstPath = root.appendingPathComponent("first.flac").path
        let secondPath = root.appendingPathComponent("second.flac").path
        let firstID = try database.save(
            track: makeTrack(path: firstPath, title: "First", artist: "Artist One", resource: "one"),
            rootID: rootID
        )
        let secondID = try database.save(
            track: makeTrack(path: secondPath, title: "Second", artist: "Björk", resource: "two"),
            rootID: rootID
        )
        let playlist = try database.createPlaylist(name: "  Mix  ", definition: .manual)

        let added = try database.addTracks([firstID, secondID, firstID], toPlaylistID: playlist.id)
        XCTAssertEqual(added.itemIDs.count, 3)
        XCTAssertEqual(added.duplicateTrackIDs, [firstID])
        XCTAssertTrue(added.shouldWarnAboutDuplicates)
        XCTAssertTrue(try database.duplicatePlaylistWarningSuppressed())
        XCTAssertEqual(
            try database.resolvePlaylist(id: playlist.id, matching: "bjork").map(\.id),
            [secondID]
        )
        let queue = try database.resolvePlaylistQueue(
            id: playlist.id,
            matching: "bjork",
            source: ListeningPlaybackSource(kind: .playlist, persistentID: playlist.id)
        )
        XCTAssertEqual(queue.queuedItems.map(\.id), [secondID])

        let page = try database.playlistItemPage(
            playlistID: playlist.id,
            query: "bjork",
            limit: 10
        )
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].track?.id, secondID)

        try database.reorderPlaylistItem(id: added.itemIDs[2], toOrdinal: 0)
        let orderedIDs = try database.playlistItemPage(playlistID: playlist.id, limit: 10)
            .items.map { $0.track?.id }
        XCTAssertEqual(orderedIDs, [firstID, firstID, secondID])

        XCTAssertEqual(try database.pruneMissingTracks(rootPath: root.path, existingPaths: [secondPath]), 1)
        let unavailablePage = try database.playlistItemPage(playlistID: playlist.id, limit: 10)
        XCTAssertEqual(unavailablePage.items.filter { $0.track == nil }.count, 2)
        XCTAssertEqual(unavailablePage.items.first { $0.track == nil }?.displayTitle, "First")
        XCTAssertEqual(try database.resolvePlaylist(id: playlist.id).map(\.id), [secondID])
        XCTAssertEqual(
            try database.resolvePlaylist(id: playlist.id, matching: "bjork").map(\.id),
            [secondID]
        )
        XCTAssertTrue(try database.resolvePlaylist(id: playlist.id, matching: "first").isEmpty)
        XCTAssertTrue(try database.resolvePlaylist(id: playlist.id, matching: "album").isEmpty)
        XCTAssertEqual(try database.clearUnavailablePlaylistItems(playlistID: playlist.id), 2)
        XCTAssertEqual(try database.playlistItemPage(playlistID: playlist.id, limit: 10).items.count, 1)
    }

    func testSmartAndSystemPlaylistQueriesUseLiveCatalogState() throws {
        let root = try makeRoot(named: "smart")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let firstID = try database.save(
            track: makeTrack(
                path: root.appendingPathComponent("first.flac").path,
                title: "Björk",
                artist: "Artist",
                resource: "one"
            ),
            rootID: rootID
        )
        let secondID = try database.save(
            track: makeTrack(
                path: root.appendingPathComponent("second.flac").path,
                title: "Other",
                artist: "Artist",
                resource: "two"
            ),
            rootID: rootID
        )
        _ = try database.setFavorite(trackID: secondID, isFavorite: true)

        let rules = try PlaylistRuleValidator.encode([
            PlaylistRule(field: .title, operation: .contains, value: "bjork")
        ])
        let smart = try database.createPlaylist(
            name: "Björk",
            definition: .smart(rulesJSON: rules, sortField: .firstSeen, sortDescending: false)
        )
        let smartPage = try database.smartPlaylistPage(playlistID: smart.id, limit: 1)
        XCTAssertEqual(smartPage.items.compactMap(\.id), [firstID])
        XCTAssertFalse(smartPage.hasMore)

        let favorites = try database.favoriteTracksPage(limit: 10)
        XCTAssertEqual(favorites.items.compactMap(\.id), [secondID])
        let recent = try database.recentlyAddedPage(limit: 1)
        XCTAssertEqual(recent.items.count, 1)
        XCTAssertTrue(recent.hasMore)
        let searchedRecent = try database.systemPlaylistPage(.recentlyAdded, limit: 10, query: "bjork")
        XCTAssertEqual(searchedRecent.items.compactMap(\.id), [firstID])
        let searchedSmart = try database.smartPlaylistPage(playlistID: smart.id, limit: 10, query: "artist")
        XCTAssertEqual(
            try database.resolvePlaylist(id: smart.id, matching: "bjork").map(\.id),
            [firstID]
        )
        XCTAssertEqual(
            try database.resolvePlaylist(.recentlyAdded, matching: "bjork").map(\.id),
            [firstID]
        )
        XCTAssertEqual(searchedSmart.items.compactMap(\.id), [firstID])

        let mostPlayed = try database.mostPlayedPage(limit: 10)
        XCTAssertTrue(mostPlayed.items.isEmpty)
        XCTAssertThrowsError(
            try database.createPlaylist(
                name: " favorites ",
                definition: .manual
            )
        ) { error in
            XCTAssertEqual(error as? LibraryDatabaseError, .reservedPlaylistName("favorites"))
        }
    }

    func testMostPlayedUsesQualifiedHistoryAndPaging() throws {
        let root = try makeRoot(named: "history")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let path = root.appendingPathComponent("played.flac").path
        let id = try database.save(
            track: makeTrack(path: path, title: "Played", artist: "Artist", resource: "played"),
            rootID: rootID
        )
        var track = try XCTUnwrap(database.tracks().first)
        track.id = id
        try recordQualifiedPlay(in: database, track: track)

        let page = try database.mostPlayedPage(limit: 1)
        XCTAssertEqual(page.items.compactMap(\.id), [id])
        XCTAssertFalse(page.hasMore)

        let countRule = try PlaylistRuleValidator.encode([
            PlaylistRule(field: .qualifiedPlayCount, operation: .greaterThan, value: 0)
        ])
        XCTAssertEqual(
            try database.smartPlaylistPage(
                rulesJSON: countRule,
                sortField: .qualifiedPlays,
                limit: 10
            ).items.compactMap(\.id),
            [id]
        )
    }

    func testRuleValidatorRejectsUnsupportedNestedAndUnboundedDefinitions() throws {
        XCTAssertThrowsError(
            try PlaylistRuleValidator.parse(
                "[{\"field\":\"title\",\"operator\":\"contains\",\"value\":" +
                    "\"x\",\"rules\":[]}]"
            )
        )
        let tooMany = Array(
            repeating: PlaylistRule(field: .title, operation: .isNotEmpty),
            count: PlaylistRuleLimits.maximumRuleCount + 1
        )
        XCTAssertThrowsError(try PlaylistRuleValidator.encode(tooMany))
        XCTAssertThrowsError(
            try PlaylistRuleValidator.parse("[{\"field\":\"duration\",\"operator\":\"contains\",\"value\":\"1\"}]")
        )
        XCTAssertThrowsError(
            try PlaylistRuleValidator.parse(
                "[{\"field\":\"lastQualifiedPlayDate\",\"operator\":\"between\",\"value\":{" +
                    "\"start\":\"2024-01-01\",\"end\":\"2024-01-02\",\"unexpected\":\"ignored\"}}]"
            )
        )
        XCTAssertThrowsError(
            try PlaylistRuleValidator.parse(
                "[{\"field\":\"title\",\"operator\":\"contains\",\"operation\":" +
                    "\"contains\",\"value\":\"x\"}]"
            )
        )
    }

}

extension PlaylistRepositoryTests {
    func testFavoriteBatchUpdateNamePolicyAndSmartTieBreak() throws {
        let root = try makeRoot(named: "update")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let firstID = try database.save(
            track: makeTrack(
                path: root.appendingPathComponent("z.flac").path,
                title: "Zed",
                artist: "Artist",
                resource: "z"
            ),
            rootID: rootID
        )
        let secondID = try database.save(
            track: makeTrack(
                path: root.appendingPathComponent("a.flac").path,
                title: "Able",
                artist: "Artist",
                resource: "a"
            ),
            rootID: rootID
        )
        let smart = try database.createPlaylist(
            name: "Sorted",
            definition: .smart(
                rulesJSON: try PlaylistRuleValidator.encode([]),
                sortField: .firstSeen,
                sortDescending: false
            )
        )
        XCTAssertEqual(
            try database.smartPlaylistPage(playlistID: smart.id, limit: 10).items.compactMap(\.id),
            [secondID, firstID]
        )
        XCTAssertEqual(
            try database.smartPlaylistPage(
                rulesJSON: try PlaylistRuleValidator.encode([]),
                sortField: .qualifiedPlays,
                limit: 10
            ).items.compactMap(\.id),
            [secondID, firstID]
        )

        try assertFavoriteBatchUpdateNamePolicy(
            in: database,
            playlistID: smart.id,
            firstID: firstID,
            secondID: secondID
        )
    }

    private func assertFavoriteBatchUpdateNamePolicy(
        in database: LibraryDatabase,
        playlistID: Int64,
        firstID: Int64,
        secondID: Int64
    ) throws {
        let favoriteChanges = try database.setFavorite(trackIDs: [firstID, secondID], isFavorite: true)
        XCTAssertEqual(favoriteChanges.map(\.isFavorite), [true, true])
        let toggled = try database.toggleFavorite(trackIDs: [firstID, secondID])
        XCTAssertEqual(toggled.map(\.isFavorite), [false, false])
        XCTAssertTrue(try database.favoriteTracksPage(limit: 10).items.isEmpty)

        let updated = try database.updateSmartPlaylist(
            id: playlistID,
            rulesJSON: try PlaylistRuleValidator.encode([]),
            sortField: .duration,
            sortDescending: true
        )
        XCTAssertEqual(updated.id, playlistID)
        XCTAssertEqual(updated.definition.kind, .smart)
        XCTAssertThrowsError(
            try database.updateSmartPlaylist(
                id: playlistID,
                rulesJSON: "[{\"field\":\"firstSeen\",\"operator\":\"isEmpty\"}]",
                sortField: .firstSeen,
                sortDescending: false
            )
        ) { error in
            guard case .invalidSmartPlaylistRules = error as? LibraryDatabaseError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try database.playlist(id: playlistID)?.definition, updated.definition)

        let renamed = try database.renamePlaylist(id: playlistID, to: "  Renamed  ")
        XCTAssertEqual(renamed.name, "Renamed")
        XCTAssertThrowsError(try database.createPlaylist(name: "renamed", definition: .manual)) { error in
            XCTAssertEqual(error as? LibraryDatabaseError, .duplicatePlaylistName("renamed"))
        }
    }

    func testQualifiedDateRuleUsesCurrentTimezoneRange() throws {
        let root = try makeRoot(named: "date")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let id = try database.save(
            track: makeTrack(
                path: root.appendingPathComponent("date.flac").path,
                title: "Date",
                artist: "Artist",
                resource: "date"
            ),
            rootID: rootID
        )
        var track = try XCTUnwrap(database.tracks().first)
        track.id = id
        try recordQualifiedPlay(in: database, track: track)
        let qualifiedAt = Date(timeIntervalSinceReferenceDate: 700_000_060)
        let day = try XCTUnwrap(ListeningLocalDay(date: qualifiedAt, timeZone: .current))
        let range = try PlaylistRuleValidator.encode([
            PlaylistRule(
                field: .qualifiedPlayDate,
                operation: .between,
                value: "\(day.rawValue),\(day.rawValue)"
            )
        ])
        XCTAssertEqual(
            try database.smartPlaylistPage(
                rulesJSON: range,
                sortField: .qualifiedPlays,
                limit: 10
            ).items.compactMap(\.id),
            [id]
        )
    }

    private func makeRoot(named name: String) throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test-tmp", isDirectory: true)
            .appendingPathComponent("playlist-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeTrack(path: String, title: String, artist: String, resource: String) -> Track {
        Track(
            path: path,
            title: title,
            artistDisplay: artist,
            albumTitle: "Album",
            genreDisplay: "Genre",
            duration: 120,
            format: "flac",
            firstSeenAtUTC: Date(timeIntervalSinceReferenceDate: 100),
            fileResourceIdentifier: resource,
            fileVolumeIdentifier: "volume"
        )
    }

    private func recordQualifiedPlay(in database: LibraryDatabase, track: Track) throws {
        let state = try database.listeningHistoryState()
        let startedAt = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let endedAt = startedAt.addingTimeInterval(60)
        let eventID = UUID()
        let snapshot = try database.createOrReuseListeningSnapshot(
            track: track,
            openedDuration: 120,
            openedFormat: "flac",
            createdAtUTC: startedAt,
            expectedGeneration: state.generation
        )
        _ = try database.beginListeningEvent(
            eventID: eventID,
            expectedGeneration: state.generation,
            snapshotID: try XCTUnwrap(snapshot.id),
            startedAtUTC: startedAt,
            startedUTCOffsetSeconds: 0,
            startPosition: 0
        )
        let utcTimeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let localDay = try XCTUnwrap(ListeningLocalDay(date: endedAt, timeZone: utcTimeZone))
        let occurrence = try XCTUnwrap(
            ListeningEventOccurrence(timestampUTC: endedAt, localDay: localDay, utcOffsetSeconds: 0)
        )
        let slice = ListeningDaySlice(
            eventID: eventID,
            localDay: localDay,
            utcOffsetSeconds: 0,
            actualListenedSeconds: 60
        )
        let details = LibraryDatabase.FinishListeningEventDetails(
            endedUTCOffsetSeconds: 0,
            endPosition: 60,
            daySlices: [slice],
            qualification: occurrence
        )
        _ = try database.finishListeningEvent(
            request: LibraryDatabase.FinishListeningEventRequest(
                eventID: eventID,
                expectedGeneration: state.generation,
                endedAtUTC: endedAt,
                endReason: .naturalCompletion,
                details: details
            )
        )
    }
}
