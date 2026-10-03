import Foundation
@testable import WavebookCore
import XCTest

extension CatalogTests {
    func testReconcileCancellationDuringTrackSaveRollsBackTransaction() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/reachable")
        _ = try database.save(
             track: Track(
                 path: "/reachable/old.flac",
                 title: "Old",
                 artistDisplay: "",
                 albumTitle: "",
                 genreDisplay: "",
                 duration: 1,
                 format: "flac"
             ),
            rootID: rootID
        )
        let replacementTracks = (0..<8).map { index in
             Track(
                 path: "/reachable/new-\(index).flac",
                 title: "New \(index)",
                 artistDisplay: "",
                 albumTitle: "",
                 genreDisplay: "",
                 duration: 1,
                 format: "flac"
             )
        }
        let probe = CatalogReconcileCancellationProbe(phase: .saving, cancellationCheckpoint: 2)

        XCTAssertThrowsError(
            try CatalogReconcileTesting.$checkpointHandler.withValue({ phase in
                probe.checkpoint(phase)
             }, operation: {
                try LibraryDatabase.withCatalogCancellationToken(probe.token) {
                    try database.reconcile(rootPath: "/reachable", tracks: replacementTracks, lyricFiles: [])
                }
             })
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try database.tracks().map(\.path), ["/reachable/old.flac"])
    }

    func testReconcileCancellationDuringTrackCanonicalizationRollsBackTransaction() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/reachable")
        _ = try database.save(
             track: Track(
                 path: "/reachable/old.flac",
                 title: "Old",
                 artistDisplay: "",
                 albumTitle: "",
                 genreDisplay: "",
                 duration: 1,
                 format: "flac"
             ),
            rootID: rootID
        )
        let replacementTracks = (0..<8).map { index in
             Track(
                 path: "/reachable/new-\(index).flac",
                 title: "New \(index)",
                 artistDisplay: "",
                 albumTitle: "",
                 genreDisplay: "",
                 duration: 1,
                 format: "flac"
             )
        }
        let probe = CatalogReconcileCancellationProbe(phase: .canonicalizing, cancellationCheckpoint: 2)

        XCTAssertThrowsError(
            try CatalogReconcileTesting.$checkpointHandler.withValue({ phase in
                probe.checkpoint(phase)
             }, operation: {
                try LibraryDatabase.withCatalogCancellationToken(probe.token) {
                    try database.reconcile(rootPath: "/reachable", tracks: replacementTracks, lyricFiles: [])
                }
             })
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try database.tracks().map(\.path), ["/reachable/old.flac"])
    }

    func testReconcileCancellationBeforeAlbumInvalidationRollsBackTransaction() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/reachable")
        _ = try database.save(
             track: Track(
                 path: "/reachable/old.flac",
                 title: "Old",
                 artistDisplay: "Artist",
                 albumTitle: "Album",
                 genreDisplay: "",
                 duration: 1,
                 format: "flac"
             ),
            rootID: rootID
        )
        let probe = CatalogReconcileCancellationProbe(phase: .invalidating, cancellationCheckpoint: 1)

        XCTAssertThrowsError(
            try CatalogReconcileTesting.$checkpointHandler.withValue({ phase in
                probe.checkpoint(phase)
             }, operation: {
                try LibraryDatabase.withCatalogCancellationToken(probe.token) {
                    try database.reconcile(rootPath: "/reachable", tracks: [], lyricFiles: [])
                }
             })
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try database.tracks().map(\.path), ["/reachable/old.flac"])
    }

    func testReconcileCancellationDuringTrackDeleteRollsBackTransaction() throws {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: "/reachable")
        let existingTracks = (0..<8).map { index in
             Track(
                 path: "/reachable/song-\(index).flac",
                 title: "Song \(index)",
                 artistDisplay: "",
                 albumTitle: "",
                 genreDisplay: "",
                 duration: 1,
                 format: "flac"
             )
        }
        for track in existingTracks {
            _ = try database.save(track: track, rootID: rootID)
        }
        let probe = CatalogReconcileCancellationProbe(phase: .deleting, cancellationCheckpoint: 2)

        XCTAssertThrowsError(
            try CatalogReconcileTesting.$checkpointHandler.withValue({ phase in
                probe.checkpoint(phase)
             }, operation: {
                try LibraryDatabase.withCatalogCancellationToken(probe.token) {
                    try database.reconcile(rootPath: "/reachable", tracks: [], lyricFiles: [])
                }
             })
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(Set(try database.tracks().map(\.path)), Set(existingTracks.map(\.path)))
    }

}
