import Foundation
@testable import WavebookCore
import XCTest

extension LibraryScannerTests {
    func testSearchUsesStoredNormalizedTokens() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/reachable")
        try database.save(
            track: Track(
                path: "/reachable/Björk-Jóga.flac",
                title: "Jóga",
                artistDisplay: "Björk",
                albumTitle: "Homogenic",
                genreDisplay: "Art Pop; Electronic",
                duration: 1,
                format: "flac"
            ),
            rootID: rootID
        )

        XCTAssertEqual(try database.tracks(matching: "bjork electronic").map(\.title), ["Jóga"])
        XCTAssertTrue(try database.tracks(matching: "bjork typo").isEmpty)
    }

    func testBrowseSummariesHandleMultiArtistTracks() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/reachable")
         try database.save(
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
         try database.save(
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
            try database.artistPage(limit: LibraryDatabase.maximumTrackPageSize).items.map {
                [$0.name, String($0.trackCount), String($0.albumCount), String($0.appearanceCount)]
            },
            [["Alice", "1", "1", "0"], ["Bob", "2", "2", "0"]]
        )
        XCTAssertEqual(try database.tracks(artist: "Bob").map(\.title), ["One", "Two"])
        XCTAssertEqual(
            try database.albumPage(limit: LibraryDatabase.maximumTrackPageSize).items.map {
                [$0.key.title, $0.key.owner, String($0.trackCount), $0.artworkTrackPath]
            },
            [["Duo", "Alice & Bob", "1", "/reachable/one.flac"], ["Solo", "Bob", "1", "/reachable/two.flac"]]
        )
        let genres = try database.genrePage(limit: LibraryDatabase.maximumTrackPageSize).items.map {
            [$0.name, String($0.artistCount)]
        }
        XCTAssertEqual(genres, [["Jazz", "1"], ["Rock", "2"]])
    }

     func testArtistDetailSplitsOwnedAndAppearingAlbumsAndGenres() throws {
         let database = try LibraryDatabase(inMemory: true)
         let rootID = try database.addRoot(path: "/reachable")
         try saveArtistDetailTracks(in: database, rootID: rootID)

        let detail = try database.artistDetailPage(
            artist: "Alice",
            detailLimit: LibraryDatabase.maximumTrackPageSize
        ).detail

        let aliceAppearanceCount = try database.artistPage(
            limit: LibraryDatabase.maximumTrackPageSize
        ).items.first { $0.name == "Alice" }?.appearanceCount
        XCTAssertEqual(aliceAppearanceCount, 1)
         XCTAssertEqual(detail.ownedAlbums.map { [$0.key.title, String($0.trackCount)] }, [["Alice Album", "2"]])
         XCTAssertEqual(
             detail.appearingAlbums.map { [$0.key.title, $0.key.owner, String($0.trackCount)] },
             [["Bob Album", "Bob", "2"]]
         )
         XCTAssertEqual(detail.genres, ["Folk", "Jazz", "Pop", "Rock"])
     }

    func testArtistDetailTreatsMultiArtistAlbumAsOwned() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/reachable")
         try database.save(
             track: Track(
                 path: "/reachable/duo-1.flac",
                 title: "Duo 1",
                 artistDisplay: "Alice; Bob",
                 albumTitle: "Duo Album",
                 albumArtist: "Alice; Bob",
                 genreDisplay: "Rock",
                 duration: 1,
                 format: "flac"
             ),
             rootID: rootID
         )
         try database.save(
             track: Track(
                 path: "/reachable/duo-2.flac",
                 title: "Duo 2",
                 artistDisplay: "Alice; Bob",
                 albumTitle: "Duo Album",
                 albumArtist: "Alice; Bob",
                 genreDisplay: "Rock",
                 duration: 1,
                 format: "flac"
             ),
             rootID: rootID
         )

        let detail = try database.artistDetailPage(
            artist: "Bob",
            detailLimit: LibraryDatabase.maximumTrackPageSize
        ).detail

        XCTAssertEqual(detail.ownedAlbums.map(\.key.title), ["Duo Album"])
        XCTAssertTrue(detail.appearingAlbums.isEmpty)
    }
     private func saveArtistDetailTracks(in database: LibraryDatabase, rootID: Int64) throws {
         let tracks = [
             Track(
                 path: "/reachable/own-1.flac",
                 title: "Own 1",
                 artistDisplay: "Alice",
                 albumTitle: "Alice Album",
                 albumArtist: "Alice",
                 genreDisplay: "Rock",
                 duration: 1,
                 format: "flac"
             ),
             Track(
                 path: "/reachable/own-2.flac",
                 title: "Own 2",
                 artistDisplay: "Alice",
                 albumTitle: "Alice Album",
                 albumArtist: "Alice",
                 genreDisplay: "Pop",
                 duration: 1,
                 format: "flac"
             ),
             Track(
                 path: "/reachable/guest-1.flac",
                 title: "Guest 1",
                 artistDisplay: "Alice; Bob",
                 albumTitle: "Bob Album",
                 albumArtist: "Bob",
                 genreDisplay: "Rock; Jazz",
                 duration: 1,
                 format: "flac"
             ),
             Track(
                 path: "/reachable/guest-2.flac",
                 title: "Guest 2",
                 artistDisplay: "Bob",
                 albumTitle: "Bob Album",
                 albumArtist: "Bob",
                 genreDisplay: "Jazz",
                 duration: 1,
                 format: "flac"
             ),
             Track(
                 path: "/reachable/single.flac",
                 title: "Single",
                 artistDisplay: "Alice",
                 albumTitle: "Single",
                 albumArtist: "Alice",
                 genreDisplay: "Folk",
                 duration: 1,
                 format: "flac"
             )
         ]
         for track in tracks {
             try database.save(track: track, rootID: rootID)
         }
     }
}
