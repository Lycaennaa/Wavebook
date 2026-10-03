import Foundation
@testable import WavebookCore
import XCTest

extension CatalogTests {
    func testTrackPageBoundsAndOffset() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/reachable")
        for index in 0..<3 {
            _ = try database.save(
                track: Track(
                    path: "/reachable/\(index).flac",
                    title: "Song \(index)",
                    artistDisplay: "Artist",
                    albumTitle: "Album",
                    genreDisplay: "Genre",
                    duration: 1,
                    format: "flac"
                ),
                rootID: rootID
            )
        }

        let firstPage = try database.trackPage(limit: 2)
        let secondPage = try database.trackPage(limit: 2, offset: 2)

        XCTAssertEqual(firstPage.tracks.map(\.title), ["Song 0", "Song 1"])
        XCTAssertEqual(firstPage.offset, 0)
        XCTAssertEqual(firstPage.limit, 2)
        XCTAssertTrue(firstPage.hasMore)
        XCTAssertEqual(secondPage.tracks.map(\.title), ["Song 2"])
        XCTAssertFalse(secondPage.hasMore)
    }

    func testUnpagedCatalogQueryDoesNotTruncate() throws {
        let database = try LibraryDatabase(inMemory: true)
        let tracks = (0...500).map { index in
             Track(
                 path: "/library/\(index).flac",
                 title: "Song \(index)",
                 artistDisplay: "Artist",
                 albumTitle: "Album",
                 genreDisplay: "Genre",
                 duration: 1,
                 format: "flac"
             )
        }
        try database.reconcile(rootPath: "/library", tracks: tracks, lyricFiles: [])

        XCTAssertEqual(try database.tracks().count, 501)
        XCTAssertEqual(try database.allTracks(matching: "Song 500").map(\.title), ["Song 500"])
        let albumKey = AlbumKey(title: "Album", owner: "Artist")
        XCTAssertEqual(try database.allTracks(album: albumKey).count, 501)
        XCTAssertEqual(try database.tracks(album: albumKey, limit: 2).count, 2)
    }

    func testScopedPageAndExplicitUnpagedOperationRemainComplete() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/reachable")
        for index in 0..<3 {
            _ = try database.save(
                track: Track(
                    path: "/reachable/\(index).flac",
                    title: "Song \(index)",
                    artistDisplay: "Artist",
                    albumTitle: "Album",
                    genreDisplay: "Genre",
                    duration: 1,
                    format: "flac"
                ),
                rootID: rootID
            )
        }

        let scope = LibraryTrackScope.album(AlbumKey(title: "Album", owner: "Artist"))
        let first = try database.trackPage(for: scope, limit: 2)
        let second = try database.trackPage(for: scope, limit: 2, offset: first.tracks.count)
        XCTAssertEqual(first.tracks.count, 2)
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(second.tracks.count, 1)
        XCTAssertFalse(second.hasMore)
        XCTAssertEqual(try database.unpagedTracks(for: scope).count, 3)
        var streamedTitles: [String] = []
        var streamedPages = 0
        try database.forEachTrackPage(for: scope, limit: 2) { page in
            streamedPages += 1
            streamedTitles.append(contentsOf: page.map(\.title))
            return streamedPages < 2
        }
        XCTAssertEqual(streamedTitles.count, 3)
        XCTAssertEqual(streamedPages, 2)
    }

}
