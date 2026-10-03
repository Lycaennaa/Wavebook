import Foundation
@testable import WavebookCore
import XCTest

final class CatalogPageRouteTests: XCTestCase {
    func testAppendRequestsDeriveOnlyTheirMatchingRouteAndSelection() {
        let album = AlbumKey(title: "Album", owner: "Artist")

        XCTAssertEqual(
            CatalogPageAppendRequest.artistDetail(
                query: "artist query",
                selectedArtist: "Artist",
                detailOffset: 10,
                trackOffset: 20
            ).context,
            CatalogPageContext(route: .artists(selectedArtist: "Artist"), query: "artist query")
        )
        XCTAssertEqual(
            CatalogPageAppendRequest.albumDetail(
                query: "album query",
                selectedAlbum: album,
                offset: 30
            ).context,
            CatalogPageContext(route: .albums(selectedAlbum: album), query: "album query")
        )
        XCTAssertEqual(
            CatalogPageAppendRequest.genreDetail(
                query: "genre query",
                selectedGenre: "Genre",
                offset: 40
            ).context,
            CatalogPageContext(route: .genres(selectedGenre: "Genre"), query: "genre query")
        )
        XCTAssertEqual(
            CatalogPageAppendRequest.songs(query: "song query", offset: 50).context,
            CatalogPageContext(route: .songs, query: "song query")
        )
    }

    func testArtistsReplacementDefersDetailUntilAnArtistIsSelected() throws {
        let database = try makePagedDatabase()
        let context = CatalogPageContext(route: .artists(selectedArtist: nil), query: "")

        let result = try CatalogPageRequest.replace(context).load(from: database)

        guard case let .artists(_, selectedArtist, .replace(page)) = result else {
            return XCTFail("Expected an artists replacement")
        }
        XCTAssertNil(selectedArtist)
        XCTAssertNil(page.selectedArtist)
        XCTAssertNil(page.detail)
        XCTAssertFalse(page.entries.items.isEmpty)
    }

    func testSelectedAlbumReplacementPreservesRouteAndSelectedPageOffset() throws {
        let database = try makePagedDatabase()
        let selectedAlbum = AlbumKey(title: "Album 500", owner: "Artist 500")
        let context = CatalogPageContext(route: .albums(selectedAlbum: selectedAlbum), query: "")

        let result = try CatalogPageRequest.replace(context).load(from: database)

        guard case let .albums(query, resultSelection, .replace(page)) = result else {
            return XCTFail("Expected an album replacement")
        }
        XCTAssertEqual(query, context.query)
        XCTAssertEqual(resultSelection, selectedAlbum)
        XCTAssertEqual(result.context, context)
        XCTAssertEqual(page.selectedAlbum, selectedAlbum)
        XCTAssertEqual(page.entries.offset, 500)
        XCTAssertEqual(page.entries.items.map(\.key), [selectedAlbum])
        XCTAssertEqual(page.tracks.offset, 0)
        XCTAssertEqual(page.tracks.tracks.map(\.title), ["Song 500"])
    }

    func testSongContinuationReturnsAppendAtRequestedOffset() throws {
        let database = try makePagedDatabase()
        let request = CatalogPageRequest.append(.songs(query: "", offset: 500))

        let result = try request.load(from: database)

        guard case let .songs(query, .append(page)) = result else {
            return XCTFail("Expected a song append")
        }
        XCTAssertEqual(query, "")
        XCTAssertEqual(result.context, CatalogPageContext(route: .songs, query: ""))
        XCTAssertEqual(page.offset, 500)
        XCTAssertEqual(page.tracks.map(\.title), ["Song 500"])
        XCTAssertFalse(page.hasMore)
    }

    func testTypedResultsDeriveTheirOwnRouteContext() {
        let trackPage = LibraryTrackPage(tracks: [], offset: 0, limit: 0, hasMore: false)
        let namePage = LibraryNamePage(items: [], offset: 0, limit: 0, hasMore: false)
        let album = AlbumKey(title: "Album", owner: "Artist")
        let albumPage = LibraryAlbumPage(items: [], offset: 0, limit: 0, hasMore: false)

        let cases: [(CatalogPageResult, CatalogPageContext)] = [
            (
                .songs(query: "songs", change: .append(trackPage)),
                CatalogPageContext(route: .songs, query: "songs")
            ),
            (
                .artists(query: "artists", selectedArtist: "Artist", change: .appendEntries(namePage)),
                CatalogPageContext(route: .artists(selectedArtist: "Artist"), query: "artists")
            ),
            (
                .albums(query: "albums", selectedAlbum: album, change: .appendEntries(albumPage)),
                CatalogPageContext(route: .albums(selectedAlbum: album), query: "albums")
            ),
            (
                .genres(query: "genres", selectedGenre: "Genre", change: .appendEntries(namePage)),
                CatalogPageContext(route: .genres(selectedGenre: "Genre"), query: "genres")
            )
        ]

        for (result, expectedContext) in cases {
            XCTAssertEqual(result.context, expectedContext)
        }
    }

    func testDetailAppendResultCarriesItsRequiredSelection() throws {
        let database = try makePagedDatabase()
        let selectedAlbum = AlbumKey(title: "Album 500", owner: "Artist 500")

        let result = try CatalogPageRequest.append(.albumDetail(
            query: "",
            selectedAlbum: selectedAlbum,
            offset: 0
        )).load(from: database)

        guard case let .albums(query, resultSelection, .appendDetail(page)) = result else {
            return XCTFail("Expected an album detail append")
        }
        XCTAssertEqual(query, "")
        XCTAssertEqual(resultSelection, selectedAlbum)
        XCTAssertEqual(result.context, CatalogPageContext(route: .albums(selectedAlbum: selectedAlbum), query: ""))
        XCTAssertEqual(page.offset, 0)
        XCTAssertEqual(page.tracks.map(\.title), ["Song 500"])
    }

    func testLoadHonorsCatalogCancellationToken() throws {
        let database = try LibraryDatabase(inMemory: true)
        let token = LibraryDatabaseCancellationToken()
        token.cancel()

        XCTAssertThrowsError(
            try LibraryDatabase.withCatalogCancellationToken(token) {
                try CatalogPageRequest.replace(
                    CatalogPageContext(route: .songs, query: "")
                ).load(from: database)
            }
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func makePagedDatabase() throws -> LibraryDatabase {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/catalog-route-tests")
        for index in 0...500 {
            let suffix = String(format: "%03d", index)
            _ = try database.save(
                track: Track(
                    path: "/catalog-route-tests/\(suffix).flac",
                    title: "Song \(suffix)",
                    artistDisplay: "Artist \(suffix)",
                    albumTitle: "Album \(suffix)",
                    albumArtist: "Artist \(suffix)",
                    genreDisplay: "Genre \(suffix)",
                    duration: 1,
                    format: "flac"
                ),
                rootID: rootID
            )
        }
        return database
    }
}
