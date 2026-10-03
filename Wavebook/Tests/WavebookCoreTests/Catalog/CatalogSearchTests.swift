import Foundation
@testable import WavebookCore
import XCTest

extension CatalogTests {
    func testCatalogSearchIndexPreservesContainsAndTracksUpdates() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/reachable")
        _ = try database.save(
            track: Track(
                path: "/reachable/song.flac",
                title: "The Original Record",
                artistDisplay: "Blue Note",
                albumTitle: "First Album",
                genreDisplay: "Jazz",
                duration: 1,
                format: "flac"
            ),
            rootID: rootID
        )

        XCTAssertEqual(try database.allTracks(matching: "iginal note").map(\.title), ["The Original Record"])
        XCTAssertEqual(try database.allTracks(matching: "th").map(\.title), ["The Original Record"])
        XCTAssertEqual(
            try database.artistPage(
                matching: "blue",
                limit: LibraryDatabase.maximumTrackPageSize
            ).items.map(\.name),
            ["Blue Note"]
        )
        XCTAssertTrue(
            try database.artistPage(
                matching: "iginal",
                limit: LibraryDatabase.maximumTrackPageSize
            ).items.isEmpty
        )

        _ = try database.save(
            track: Track(
                path: "/reachable/song.flac",
                title: "Replacement Record",
                artistDisplay: "New Artist",
                albumTitle: "Second Album",
                genreDisplay: "Rock",
                duration: 1,
                format: "flac"
            ),
            rootID: rootID
        )
        XCTAssertTrue(try database.allTracks(matching: "iginal").isEmpty)
        XCTAssertEqual(try database.allTracks(matching: "placement").map(\.title), ["Replacement Record"])

        try database.reconcile(rootPath: "/reachable", tracks: [], lyricFiles: [])
        XCTAssertTrue(try database.allTracks(matching: "placement").isEmpty)
    }
    func testGlobalSearchKeepsMetadataMatchesInTheirOwnSections() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/global-search")
        _ = try database.save(
            track: Track(
                path: "/global-search/signal.flac",
                title: "Signal Fire",
                artistDisplay: "Northern Lights",
                albumTitle: "Night Sky",
                albumArtist: "Northern Lights",
                genreDisplay: "Ambient",
                duration: 1,
                format: "flac"
            ),
            rootID: rootID
        )
        _ = try database.save(
            track: Track(
                path: "/global-search/other.flac",
                title: "Unrelated",
                artistDisplay: "Other Artist",
                albumTitle: "Other Album",
                albumArtist: "Other Artist",
                genreDisplay: "Rock",
                duration: 1,
                format: "flac"
            ),
            rootID: rootID
        )

        let result = try CatalogPageRequest.replace(
            CatalogPageContext(route: .search, query: "signal")
        ).load(from: database)

        guard case let .search(query, page) = result else {
            return XCTFail("Expected a global search result")
        }
        XCTAssertEqual(query, "signal")
        XCTAssertEqual(result.context, CatalogPageContext(route: .search, query: "signal"))
        XCTAssertEqual(page.songs.tracks.map(\.title), ["Signal Fire"])
        XCTAssertTrue(page.artists.items.isEmpty)
        XCTAssertTrue(page.albums.items.isEmpty)
        XCTAssertTrue(page.genres.items.isEmpty)

        try assertGlobalSearchMetadataMatchesOwnSections(in: database)
    }

    private func assertGlobalSearchMetadataMatchesOwnSections(in database: LibraryDatabase) throws {
        let artistResult = try CatalogPageRequest.replace(
            CatalogPageContext(route: .search, query: "northern")
        ).load(from: database)
        guard case let .search(_, artistPage) = artistResult else {
            return XCTFail("Expected an artist search result")
        }
        XCTAssertTrue(artistPage.songs.tracks.isEmpty)
        XCTAssertEqual(artistPage.artists.items.map(\.name), ["Northern Lights"])
        XCTAssertTrue(artistPage.albums.items.isEmpty)
        XCTAssertTrue(artistPage.genres.items.isEmpty)

        let albumResult = try CatalogPageRequest.replace(
            CatalogPageContext(route: .search, query: "night")
        ).load(from: database)
        guard case let .search(_, albumPage) = albumResult else {
            return XCTFail("Expected an album search result")
        }
        XCTAssertTrue(albumPage.songs.tracks.isEmpty)
        XCTAssertTrue(albumPage.artists.items.isEmpty)
        XCTAssertEqual(albumPage.albums.items.map(\.key.title), ["Night Sky"])
        XCTAssertTrue(albumPage.genres.items.isEmpty)

        let genreResult = try CatalogPageRequest.replace(
            CatalogPageContext(route: .search, query: "ambient")
        ).load(from: database)
        guard case let .search(_, genrePage) = genreResult else {
            return XCTFail("Expected a genre search result")
        }
        XCTAssertTrue(genrePage.songs.tracks.isEmpty)
        XCTAssertTrue(genrePage.artists.items.isEmpty)
        XCTAssertTrue(genrePage.albums.items.isEmpty)
        XCTAssertEqual(genrePage.genres.items.map(\.name), ["Ambient"])
    }

    func testGlobalSearchNormalizesPunctuationWithinEachField() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/normalized-search")
        _ = try database.save(
            track: Track(
                path: "/normalized-search/song.flac",
                title: "It's Chill-Out",
                artistDisplay: "Björk",
                albumTitle: "Best-Of",
                genreDisplay: "Art-Pop",
                duration: 1,
                format: "flac"
            ),
            rootID: rootID
        )

        func searchPage(_ query: String) throws -> CatalogSearchPage {
            let result = try CatalogPageRequest.replace(
                CatalogPageContext(route: .search, query: query)
            ).load(from: database)
            guard case let .search(_, page) = result else {
                throw NSError(domain: "CatalogSearchTests", code: 1)
            }
            return page
        }

        let songPage = try searchPage("its chillout")
        XCTAssertEqual(songPage.songs.tracks.map(\.title), ["It's Chill-Out"])
        XCTAssertTrue(songPage.artists.items.isEmpty)
        XCTAssertTrue(songPage.albums.items.isEmpty)
        XCTAssertTrue(songPage.genres.items.isEmpty)

        let artistPage = try searchPage("bjork")
        XCTAssertTrue(artistPage.songs.tracks.isEmpty)
        XCTAssertEqual(artistPage.artists.items.map(\.name), ["Björk"])

        let albumPage = try searchPage("bestof")
        XCTAssertTrue(albumPage.songs.tracks.isEmpty)
        XCTAssertEqual(albumPage.albums.items.map(\.key.title), ["Best-Of"])

        let genrePage = try searchPage("artpop")
        XCTAssertTrue(genrePage.songs.tracks.isEmpty)
        XCTAssertEqual(genrePage.genres.items.map(\.name), ["Art-Pop"])
    }
}
