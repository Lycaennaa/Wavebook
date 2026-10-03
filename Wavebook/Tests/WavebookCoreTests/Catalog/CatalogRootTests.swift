import Foundation
@testable import WavebookCore
import XCTest

extension CatalogTests {
    func testReconcileInvalidatesChangedAlbumsOnce() throws {
        let database = try LibraryDatabase(inMemory: true)
        let albums = ["Before", "After"]
        let initialTracks = (0..<500).map { index in
            Track(
                path: "/library/\(index).flac",
                title: "Song \(index)",
                artistDisplay: "Artist",
                albumTitle: albums[0],
                albumArtist: "Artist",
                genreDisplay: "Genre",
                duration: 1,
                format: "flac"
            )
        }
        try database.reconcile(rootPath: "/library", tracks: initialTracks, lyricFiles: [])

        let replacementTracks = initialTracks.map { track in
            var replacement = track
            replacement.albumTitle = albums[1]
            return replacement
        }
        let capture = CatalogAlbumInvalidationCapture()
        try CatalogReconcileTesting.$albumInvalidationHandler.withValue({ albumKeys in
            capture.append(albumKeys)
         }, operation: {
            try database.reconcile(rootPath: "/library", tracks: replacementTracks, lyricFiles: [])
         })

        XCTAssertEqual(capture.invalidations.count, 1)
        XCTAssertEqual(capture.invalidations.first, Set([
            AlbumKey(title: albums[0], owner: "Artist"),
            AlbumKey(title: albums[1], owner: "Artist")
        ]))
    }
    func testEquivalentRootPathsShareOneCanonicalEntry() throws {
        let database = try LibraryDatabase(inMemory: true)

        let firstID = try database.addRoot(path: "/library")
        let equivalentID = try database.addRoot(path: "/library/./")

        XCTAssertEqual(firstID, equivalentID)
        XCTAssertEqual(try database.roots().map(\.path), ["/library"])
    }

    func testPersistedOverlappingRootBlocksReconcileWithoutDeletingTracks() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/library")
        _ = try database.save(
             track: Track(
                 path: "/library/song.flac",
                 title: "Song",
                 artistDisplay: "Artist",
                 albumTitle: "Album",
                 genreDisplay: "Genre",
                 duration: 1,
                 format: "flac"
             ),
            rootID: rootID
        )
         try database.writer.write { database in
             try database.execute(
                 sql: "INSERT INTO roots (path, lastScanAt) VALUES (?, NULL)",
                 arguments: ["/library/nested"]
             )
        }

        XCTAssertThrowsError(try database.addRoot(path: "/library/other")) { error in
            guard case .overlappingRoot = error as? LibraryDatabaseError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try database.reconcile(rootPath: "/library", tracks: [], lyricFiles: [])) { error in
            guard case .overlappingRoot = error as? LibraryDatabaseError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try database.tracks().map(\.path), ["/library/song.flac"])
    }
}
