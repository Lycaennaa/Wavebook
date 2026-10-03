import Foundation
@testable import WavebookCore
import XCTest

extension CatalogTests {
    func testFacetSearchAndCountsUseMatchingTracks() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/reachable")
        _ = try database.save(
            track: Track(
                path: "/reachable/one.flac",
                title: "One",
                artistDisplay: "Alice; Bob",
                albumTitle: "Duo",
                albumArtist: "Alice & Bob",
                genreDisplay: "Rock",
                duration: 1,
                format: "flac"
            ),
            rootID: rootID
        )
        _ = try database.save(
            track: Track(
                path: "/reachable/two.flac",
                title: "Two",
                artistDisplay: "Bob",
                albumTitle: "Solo",
                genreDisplay: "Jazz",
                duration: 1,
                format: "flac"
            ),
            rootID: rootID
        )

        XCTAssertEqual(
            try database.artistPage(
                matching: "alice",
                limit: LibraryDatabase.maximumTrackPageSize
            ).items,
            [
                LibraryNameSummary(name: "Alice", trackCount: 1, albumCount: 1)
            ]
        )
        XCTAssertEqual(
            try database.artistPage(
                matching: "bob",
                limit: LibraryDatabase.maximumTrackPageSize
            ).items,
            [
                LibraryNameSummary(name: "Bob", trackCount: 2, albumCount: 2)
            ]
        )
        XCTAssertTrue(
            try database.albumPage(
                matching: "jazz",
                limit: LibraryDatabase.maximumTrackPageSize
            ).items.isEmpty
        )
        XCTAssertTrue(
            try database.genrePage(
                matching: "alice",
                limit: LibraryDatabase.maximumTrackPageSize
            ).items.isEmpty
        )
        XCTAssertEqual(try database.tracks(artist: "Bob", matching: "jazz").map(\.title), ["Two"])
    }

    func testArtistOwnershipUsesFullAlbumTotals() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/reachable")
        for (index, artist) in ["Alice", "Alice", "Bob"].enumerated() {
            _ = try database.save(
                track: Track(
                    path: "/reachable/shared-\(index).flac",
                    title: "Track \(index)",
                    artistDisplay: artist,
                    albumTitle: "Shared Album",
                    albumArtist: "Bob",
                    genreDisplay: "Genre",
                    duration: 1,
                    format: "flac"
                ),
                rootID: rootID
            )
        }

        XCTAssertEqual(
            try database.artistPage(matching: "alice", limit: 10).items,
            [LibraryNameSummary(name: "Alice", trackCount: 2, albumCount: 1, appearanceCount: 1)]
        )
        let detail = try database.artistDetailPage(
            artist: "Alice",
            matching: "alice",
            detailLimit: 10,
            trackPage: .init(limit: 10)
        )
        XCTAssertTrue(detail.detail.ownedAlbums.isEmpty)
        XCTAssertEqual(detail.detail.appearingAlbums.map(\.key), [AlbumKey(title: "Shared Album", owner: "Bob")])
    }

    func testFacetPagesConsumeHasMoreWithoutMaterializingAllEntries() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/reachable")
        for index in 0..<3 {
            _ = try database.save(
                track: Track(
                    path: "/reachable/\(index).flac",
                    title: "Song \(index)",
                    artistDisplay: "Artist \(index)",
                    albumTitle: "Album \(index)",
                    genreDisplay: "Genre \(index)",
                    duration: 1,
                    format: "flac"
                ),
                rootID: rootID
            )
        }

        let firstArtists = try database.artistPage(limit: 1)
        let secondArtists = try database.artistPage(limit: 1, offset: firstArtists.items.count)
        XCTAssertEqual(firstArtists.items.map(\.name), ["Artist 0"])
        XCTAssertTrue(firstArtists.hasMore)
        XCTAssertEqual(secondArtists.items.map(\.name), ["Artist 1"])
        XCTAssertTrue(secondArtists.hasMore)

        let firstAlbums = try database.albumPage(limit: 1)
        XCTAssertEqual(firstAlbums.items.map(\.key.title), ["Album 0"])
        XCTAssertTrue(firstAlbums.hasMore)
        let firstGenres = try database.genrePage(limit: 1)
        XCTAssertEqual(firstGenres.items.map(\.name), ["Genre 0"])
        XCTAssertTrue(firstGenres.hasMore)
        let selectedArtistPage = try database.artistPage(limit: 1, selectedArtist: "Artist 2")
        XCTAssertEqual(selectedArtistPage.items.map(\.name), ["Artist 2"])
        XCTAssertEqual(selectedArtistPage.offset, 2)

        let selectedAlbumPage = try database.albumPage(
            limit: 1,
            selectedAlbum: AlbumKey(title: "Album 2", owner: "Artist 2")
        )
        XCTAssertEqual(selectedAlbumPage.items.map(\.key.title), ["Album 2"])
        XCTAssertEqual(selectedAlbumPage.offset, 2)

        let selectedGenrePage = try database.genrePage(limit: 1, selectedGenre: "Genre 2")
        XCTAssertEqual(selectedGenrePage.items.map(\.name), ["Genre 2"])
        XCTAssertEqual(selectedGenrePage.offset, 2)
    }

    func testAlbumIdentityNormalizesAtCatalogBoundary() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/reachable")
        for (index, title) in [" Album ", "Album"].enumerated() {
            _ = try database.save(
                track: Track(
                    path: "/reachable/\(index).flac",
                    title: "Song \(index)",
                    artistDisplay: "Artist",
                    albumTitle: title,
                    albumArtist: " Artist ",
                    genreDisplay: "Genre",
                    duration: 1,
                    format: "flac"
                ),
                rootID: rootID
            )
        }

        let key = AlbumKey(title: " Album ", owner: " Artist ")
        XCTAssertEqual(
            try database.albumPage(limit: 10).items,
            [
                LibraryAlbumSummary(
                    key: AlbumKey(title: "Album", owner: "Artist"),
                    trackCount: 2,
                    artworkTrackPath: "/reachable/0.flac"
                )
            ]
        )
        XCTAssertEqual(try database.allTracks().map(\.albumTitle), ["Album", "Album"])
        XCTAssertEqual(try database.tracks(album: key).count, 2)
    }

    func testArtistDetailPaginationUsesStableCaseTieBreakers() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/reachable")
        let albums = [
            (title: "Album", owner: "artist"),
            (title: "album", owner: "Artist"),
            (title: "Beta", owner: "artist"),
            (title: "Beta", owner: "Artist")
        ]

        for (albumIndex, album) in albums.enumerated() {
            let trackCount = albumIndex == 0 ? 3 : 2
            for trackIndex in 0..<trackCount {
                let title: String
                if albumIndex == 0 {
                    title = trackIndex == 0 ? "cover" : "Cover"
                } else {
                    title = "Song \(trackIndex)"
                }
                _ = try database.save(
                    track: Track(
                        path: "/reachable/\(albumIndex)-\(trackIndex).flac",
                        title: title,
                        artistDisplay: "Artist",
                        albumTitle: album.title,
                        albumArtist: album.owner,
                        genreDisplay: "Rock, rock",
                        duration: 1,
                        format: "flac"
                    ),
                    rootID: rootID
                )
            }
        }

        let expectedAlbums = ["Album|artist", "album|Artist", "Beta|Artist", "Beta|artist"]
        var actualAlbums: [String] = []
        for offset in 0..<expectedAlbums.count {
            let page = try database.artistDetailPage(
                artist: "Artist",
                detailLimit: 1,
                detailOffset: offset,
                trackPage: .init(limit: 0)
            )
            actualAlbums.append(contentsOf: page.detail.ownedAlbums.map { "\($0.key.title)|\($0.key.owner)" })
            XCTAssertTrue(page.detail.appearingAlbums.isEmpty)
            if offset == 0 {
                XCTAssertEqual(page.detail.ownedAlbums.first?.artworkTrackPath, "/reachable/0-1.flac")
            }

            let expectedGenres: [String]
            switch offset {
            case 0:
                expectedGenres = ["Rock"]
            case 1:
                expectedGenres = ["rock"]
            default:
                expectedGenres = []
            }
            XCTAssertEqual(page.detail.genres, expectedGenres)
            XCTAssertEqual(page.hasMoreDetail, offset < expectedAlbums.count - 1)
        }
        XCTAssertEqual(actualAlbums, expectedAlbums)
    }
    func testArtistDetailPageWithZeroDetailLimitStopsMetadataContinuation() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/reachable")
        for (albumIndex, albumTitle) in ["First Album", "Second Album"].enumerated() {
            for trackIndex in 0..<2 {
                _ = try database.save(
                    track: Track(
                        path: "/reachable/\(albumIndex)-\(trackIndex).flac",
                        title: "Song \(albumIndex)-\(trackIndex)",
                        artistDisplay: "Artist",
                        albumTitle: albumTitle,
                        genreDisplay: "Genre \(albumIndex)",
                        duration: 1,
                        format: "flac"
                    ),
                    rootID: rootID
                )
            }
        }

        let first = try database.artistDetailPage(
            artist: "Artist",
            detailLimit: 0,
            detailOffset: 7,
            trackPage: .init(limit: 1)
        )
        XCTAssertEqual(first.detailOffset, 7)
        XCTAssertEqual(first.detailLimit, 0)
        XCTAssertTrue(first.detail.ownedAlbums.isEmpty)
        XCTAssertTrue(first.detail.appearingAlbums.isEmpty)
        XCTAssertTrue(first.detail.genres.isEmpty)
        XCTAssertFalse(first.hasMoreDetail)
        XCTAssertEqual(first.tracks.tracks.count, 1)
        XCTAssertTrue(first.tracks.hasMore)

        let continuation = try database.artistDetailPage(
            artist: "Artist",
            detailLimit: first.detailLimit,
            detailOffset: first.detailOffset + first.detailLimit,
            trackPage: .init(limit: first.tracks.limit, offset: first.tracks.tracks.count)
        )
        XCTAssertEqual(continuation.detailOffset, 7)
        XCTAssertFalse(continuation.hasMoreDetail)
        XCTAssertTrue(continuation.detail.ownedAlbums.isEmpty)
        XCTAssertTrue(continuation.detail.appearingAlbums.isEmpty)
        XCTAssertTrue(continuation.detail.genres.isEmpty)
    }

    func testArtistDetailPageSeparatesMetadataAndTrackContinuations() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/reachable")
        for index in 0..<3 {
            _ = try database.save(
                track: Track(
                    path: "/reachable/\(index).flac",
                    title: "Song \(index)",
                    artistDisplay: "Artist",
                    albumTitle: "Album",
                    genreDisplay: "Genre \(index)",
                    duration: 1,
                    format: "flac"
                ),
                rootID: rootID
            )
        }

        let first = try database.artistDetailPage(artist: "Artist", detailLimit: 1, trackPage: .init(limit: 2))
        let second = try database.artistDetailPage(
            artist: "Artist",
            detailLimit: first.detailLimit,
            detailOffset: first.detailOffset + first.detailLimit,
            trackPage: .init(limit: first.tracks.limit, offset: first.tracks.tracks.count)
        )
        XCTAssertEqual(first.tracks.tracks.count, 2)
        XCTAssertTrue(first.tracks.hasMore)
        XCTAssertEqual(second.tracks.tracks.count, 1)
        XCTAssertFalse(second.tracks.hasMore)
        XCTAssertTrue(first.hasMoreDetail)
        XCTAssertEqual(first.detail.genres, ["Genre 0"])
        XCTAssertEqual(second.detail.genres, ["Genre 1"])
    }

    func testFacetSnapshotInvalidatesAfterCatalogMutation() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/reachable")
        _ = try database.save(
            track: Track(
                path: "/reachable/song.flac",
                title: "Song",
                artistDisplay: "Before",
                albumTitle: "Album",
                genreDisplay: "Genre",
                duration: 1,
                format: "flac"
            ),
            rootID: rootID
        )

        XCTAssertEqual(try database.artistPage(limit: 10).items.map(\.name), ["Before"])

        _ = try database.save(
            track: Track(
                path: "/reachable/song.flac",
                title: "Song",
                artistDisplay: "After",
                albumTitle: "Album",
                genreDisplay: "Genre",
                duration: 1,
                format: "flac"
            ),
            rootID: rootID
        )

        XCTAssertEqual(try database.artistPage(limit: 10).items.map(\.name), ["After"])
    }

    func testFacetSnapshotAccumulatesAcrossTrackChunks() throws {
        let database = try LibraryDatabase(inMemory: true)
        let tracks = (0..<257).map { index in
            Track(
                path: "/reachable/\(index).flac",
                title: "Song \(index)",
                artistDisplay: "Artist",
                albumTitle: "Album",
                genreDisplay: "Genre",
                duration: 1,
                format: "flac"
            )
        }
        try database.reconcile(rootPath: "/reachable", tracks: tracks, lyricFiles: [])

        XCTAssertEqual(
            try database.artistPage(limit: 1).items,
            [LibraryNameSummary(name: "Artist", trackCount: 257, albumCount: 1)]
        )
        XCTAssertEqual(
            try database.albumPage(limit: 1).items,
             [
                 LibraryAlbumSummary(
                     key: AlbumKey(title: "Album", owner: "Artist"),
                     trackCount: 257,
                     artworkTrackPath: "/reachable/0.flac"
                 )
             ]
        )
        XCTAssertEqual(
            try database.genrePage(limit: 1).items,
            [LibraryNameSummary(name: "Genre", trackCount: 257, artistCount: 1)]
        )
    }

    func testCatalogFacetCancellationTokenStopsBeforeMaterialization() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/reachable")
        _ = try database.save(
            track: Track(
                path: "/reachable/song.flac",
                title: "Song",
                artistDisplay: "Artist",
                albumTitle: "Album",
                genreDisplay: "Genre",
                duration: 1,
                format: "flac"
            ),
            rootID: rootID
        )
        let token = LibraryDatabaseCancellationToken()
        token.cancel()

        XCTAssertThrowsError(
            try LibraryDatabase.withCatalogCancellationToken(token) {
                try database.artistPage(limit: 10)
            }
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testLargeFacetPageUsesBoundedSQLPageQueries() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/reachable")
        let tracks = (0..<1_024).map { index in
            let suffix = String(format: "%04d", index)
            return Track(
                path: "/reachable/\(suffix).flac",
                title: "Song \(suffix)",
                artistDisplay: "Artist \(suffix)",
                albumTitle: "Album \(suffix)",
                genreDisplay: "Genre \(suffix)",
                duration: 1,
                format: "flac"
            )
        }
        for track in tracks {
            _ = try database.save(track: track, rootID: rootID)
        }

        let capture = CatalogFacetQueryCapture()
        let page = try CatalogFacetQueryTesting.$observer.withValue({ event in
            capture.append(event)
         }, operation: {
            try database.artistPage(limit: 1, offset: 500)
         })

        XCTAssertEqual(page.items.map(\.name), ["Artist 0500"])
        XCTAssertTrue(page.hasMore)
        let keySQL = try XCTUnwrap(capture.events(for: .artists, stage: .pageKeys).first?.sql)
        let summarySQL = try XCTUnwrap(capture.events(for: .artists, stage: .pageSummaries).first?.sql)
        XCTAssertTrue(keySQL.contains("LIMIT ? OFFSET ?"))
        XCTAssertTrue(summarySQL.contains("pageNames(artistName)"))
        XCTAssertTrue(summarySQL.contains("VALUES (?)"))
        XCTAssertFalse(summarySQL.contains("LIMIT ? OFFSET ?"))
    }

    func testFacetOrderingBreaksCaseOnlyArtistAndGenreTiesByRawValue() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/reachable")
        for (index, values) in [
            (artist: "artist", genre: "genre"),
            (artist: "Artist", genre: "Genre")
        ].enumerated() {
            _ = try database.save(
                track: Track(
                    path: "/reachable/\(index).flac",
                    title: "Song \(index)",
                    artistDisplay: values.artist,
                    albumTitle: "Album \(index)",
                    genreDisplay: values.genre,
                    duration: 1,
                    format: "flac"
                ),
                rootID: rootID
            )
        }

        XCTAssertEqual(try database.artistPage(limit: 10).items.map(\.name), ["Artist", "artist"])
        XCTAssertEqual(try database.genrePage(limit: 10).items.map(\.name), ["Genre", "genre"])
        XCTAssertEqual(
            ["artist", "Artist"].sorted(by: CatalogFacetOrdering.localizedNamePrecedes),
            ["Artist", "artist"]
        )
    }

    func testFacetNamesPreserveRawUnicodeIdentity() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/reachable")
        let decomposed = "Cafe\u{301}"
        let precomposed = "Caf\u{E9}"

        _ = try database.save(
            track: Track(
                path: "/reachable/decomposed.flac",
                title: "Decomposed",
                artistDisplay: decomposed,
                albumTitle: "Decomposed Album",
                genreDisplay: decomposed,
                duration: 1,
                format: "flac"
            ),
            rootID: rootID
        )
        _ = try database.save(
            track: Track(
                path: "/reachable/precomposed.flac",
                title: "Precomposed",
                artistDisplay: precomposed,
                albumTitle: "Precomposed Album",
                genreDisplay: precomposed,
                duration: 1,
                format: "flac"
            ),
            rootID: rootID
        )

        let expectedBytes = [Data(decomposed.utf8), Data(precomposed.utf8)]
        let artists = try database.artistPage(limit: 10).items
        XCTAssertEqual(artists.map { Data($0.name.utf8) }, expectedBytes)
        XCTAssertEqual(artists.map(\.trackCount), [1, 1])
        XCTAssertEqual(artists.map(\.albumCount), [1, 1])

        let genres = try database.genrePage(limit: 10).items
        XCTAssertEqual(genres.map { Data($0.name.utf8) }, expectedBytes)
        XCTAssertEqual(genres.map(\.trackCount), [1, 1])
        XCTAssertEqual(genres.map(\.artistCount), [1, 1])
    }
}
