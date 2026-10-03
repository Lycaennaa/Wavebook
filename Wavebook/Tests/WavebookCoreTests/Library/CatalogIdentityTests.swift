import Foundation
import GRDB
@testable import WavebookCore
import XCTest

final class CatalogIdentityTests: XCTestCase {
    func testCatalogUpsertPreservesMutableTrackState() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test-tmp", isDirectory: true)
            .appendingPathComponent("playlist-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let firstSeenAtUTC = Date(timeIntervalSinceReferenceDate: 100)
        let original = Track(
            path: root.appendingPathComponent("song.flac").path,
            title: "Original",
            artistDisplay: "Artist",
            albumTitle: "Album",
            firstSeenAtUTC: firstSeenAtUTC,
            fileResourceIdentifier: "resource-1",
            fileVolumeIdentifier: "volume-1",
            isFavorite: true
        )
        _ = try database.save(track: original, rootID: rootID)

        var rescan = original
        rescan.title = "Updated"
        rescan.firstSeenAtUTC = Date(timeIntervalSinceReferenceDate: 200)
        rescan.fileResourceIdentifier = nil
        rescan.fileVolumeIdentifier = nil
        rescan.isFavorite = false
        _ = try database.save(track: rescan, rootID: rootID)

        let stored = try XCTUnwrap(database.tracks().first)
        XCTAssertEqual(stored.title, "Updated")
        XCTAssertEqual(stored.firstSeenAtUTC, firstSeenAtUTC)
        XCTAssertEqual(stored.fileResourceIdentifier, "resource-1")
        XCTAssertEqual(stored.fileVolumeIdentifier, "volume-1")
        XCTAssertTrue(stored.isFavorite)
    }

    func testReconcileFollowsResourceIdentityAcrossRename() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test-tmp", isDirectory: true)
            .appendingPathComponent("playlist-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let oldPath = root.appendingPathComponent("old.flac").path
        let newPath = root.appendingPathComponent("new.flac").path
        let firstSeenAtUTC = Date(timeIntervalSinceReferenceDate: 100)
        let original = Track(
            path: oldPath,
            title: "Original",
            artistDisplay: "Artist",
            albumTitle: "Album",
            firstSeenAtUTC: firstSeenAtUTC,
            fileResourceIdentifier: "resource-1",
            fileVolumeIdentifier: "volume-1",
            isFavorite: true
        )
        let originalID = try database.save(track: original, rootID: rootID)
        try database.writer.write { connection in
            try connection.execute(
                sql: "INSERT INTO playlists (name, kind, createdAtUTC) VALUES (?, ?, ?)",
                arguments: ["Rename Playlist", PlaylistKind.manual.rawValue, 0]
            )
            let playlistID = try XCTUnwrap(Int64.fetchOne(connection, sql: "SELECT id FROM playlists"))
            try connection.execute(
                sql: """
                    INSERT INTO playlistItems (
                        playlistID, ordinal, trackID, snapshotPath, snapshotTitle,
                        snapshotArtistDisplay, snapshotAlbumTitle, snapshotGenreDisplay,
                        snapshotDuration, snapshotFormat
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [playlistID, 0, originalID, oldPath, "Original", "Artist", "Album", "", 1.0, "flac"]
            )
        }

        var renamed = original
        renamed.path = newPath
        renamed.firstSeenAtUTC = Date(timeIntervalSinceReferenceDate: 200)
        renamed.isFavorite = false
        try database.reconcile(rootPath: root.path, tracks: [renamed], lyricFiles: [])

        let stored = try XCTUnwrap(database.tracks().first)
        XCTAssertEqual(stored.id, originalID)
        XCTAssertEqual(stored.path, newPath)
        XCTAssertEqual(stored.firstSeenAtUTC, firstSeenAtUTC)
        XCTAssertTrue(stored.isFavorite)
        XCTAssertEqual(try database.writer.read { connection in
            try Int64.fetchOne(connection, sql: "SELECT trackID FROM playlistItems")
        }, originalID)
    }

    func testReconcileTreatsResourceMismatchAsReplacement() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test-tmp", isDirectory: true)
            .appendingPathComponent("playlist-replacement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let path = root.appendingPathComponent("song.flac").path
        let original = Track(
            path: path,
            title: "Original",
            artistDisplay: "Artist",
            albumTitle: "Album",
            firstSeenAtUTC: Date(timeIntervalSinceReferenceDate: 100),
            fileResourceIdentifier: "resource-1",
            fileVolumeIdentifier: "volume-1",
            isFavorite: true
        )
        let originalID = try database.save(track: original, rootID: rootID)
        try database.writer.write { connection in
            try connection.execute(
                sql: "INSERT INTO playlists (name, kind, createdAtUTC) VALUES (?, ?, ?)",
                arguments: ["Replacement Playlist", PlaylistKind.manual.rawValue, 0]
            )
            let playlistID = try XCTUnwrap(Int64.fetchOne(connection, sql: "SELECT id FROM playlists"))
            try connection.execute(
                sql: """
                    INSERT INTO playlistItems (
                        playlistID, ordinal, trackID, snapshotPath, snapshotTitle,
                        snapshotArtistDisplay, snapshotAlbumTitle, snapshotGenreDisplay,
                        snapshotDuration, snapshotFormat
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [playlistID, 0, originalID, path, "Original", "Artist", "Album", "", 1.0, "flac"]
            )
        }

        let replacement = Track(
            path: path,
            title: "Replacement",
            artistDisplay: "Artist",
            albumTitle: "Album",
            firstSeenAtUTC: Date(timeIntervalSinceReferenceDate: 200),
            fileResourceIdentifier: "resource-2",
            fileVolumeIdentifier: "volume-1"
        )
        try database.reconcile(rootPath: root.path, tracks: [replacement], lyricFiles: [])

        let stored = try XCTUnwrap(database.tracks().first)
        XCTAssertNotEqual(stored.id, originalID)
        XCTAssertEqual(stored.title, "Replacement")
        XCTAssertFalse(stored.isFavorite)
        XCTAssertNil(try database.writer.read { connection in
            try Int64.fetchOne(connection, sql: "SELECT trackID FROM playlistItems")
        })
    }

    func testNonfiniteFirstSeenIsNormalizedBeforePersistence() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test-tmp", isDirectory: true)
            .appendingPathComponent("playlist-finite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        var track = Track(
            path: root.appendingPathComponent("song.flac").path,
            title: "Song",
            artistDisplay: "Artist",
            albumTitle: "Album"
        )
        track.firstSeenAtUTC = Date(timeIntervalSinceReferenceDate: .infinity)
        _ = try database.save(track: track, rootID: rootID)

        let stored = try XCTUnwrap(database.tracks().first)
        XCTAssertTrue(stored.firstSeenAtUTC.timeIntervalSinceReferenceDate.isFinite)
        XCTAssertNil(try database.writer.read { connection in
            try Double.fetchOne(connection, sql: "SELECT mtime FROM tracks")
        })
    }

    func testReconcilePreservesSamePathWhenIdentityIsUnavailable() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test-tmp", isDirectory: true)
            .appendingPathComponent("playlist-unknown-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let path = root.appendingPathComponent("song.flac").path
        let original = Track(
            path: path,
            title: "Original",
            artistDisplay: "Artist",
            albumTitle: "Album",
            firstSeenAtUTC: Date(timeIntervalSinceReferenceDate: 100),
            fileResourceIdentifier: "resource-1",
            fileVolumeIdentifier: "volume-1",
            isFavorite: true
        )
        let originalID = try database.save(track: original, rootID: rootID)
        let rescanned = Track(path: path, title: "Updated", artistDisplay: "Artist", albumTitle: "Album")
        try database.reconcile(rootPath: root.path, tracks: [rescanned], lyricFiles: [])

        let stored = try XCTUnwrap(database.tracks().first)
        XCTAssertEqual(stored.id, originalID)
        XCTAssertEqual(stored.title, "Updated")
        XCTAssertEqual(stored.firstSeenAtUTC, original.firstSeenAtUTC)
        XCTAssertEqual(stored.fileResourceIdentifier, original.fileResourceIdentifier)
        XCTAssertEqual(stored.fileVolumeIdentifier, original.fileVolumeIdentifier)
        XCTAssertTrue(stored.isFavorite)
    }

    func testReconcileDoesNotMoveIdentityAcrossRoots() throws {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test-tmp", isDirectory: true)
            .appendingPathComponent("playlist-cross-root-\(UUID().uuidString)", isDirectory: true)
        let firstRoot = base.appendingPathComponent("first", isDirectory: true)
        let secondRoot = base.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }

        let database = try LibraryDatabase(inMemory: true)
        _ = try database.addRoot(path: firstRoot.path)
        let secondRootID = try database.addRoot(path: secondRoot.path)
        let secondTrack = Track(
            path: secondRoot.appendingPathComponent("song.flac").path,
            title: "Other Root",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "resource-1",
            fileVolumeIdentifier: "volume-1",
            isFavorite: true
        )
        let secondTrackID = try database.save(track: secondTrack, rootID: secondRootID)
        let firstTrack = Track(
            path: firstRoot.appendingPathComponent("song.flac").path,
            title: "First Root",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "resource-1",
            fileVolumeIdentifier: "volume-1"
        )
        try database.reconcile(rootPath: firstRoot.path, tracks: [firstTrack], lyricFiles: [])

        let storedSecondTrack = try XCTUnwrap(database.tracks().first { $0.id == secondTrackID })
        XCTAssertEqual(storedSecondTrack.path, secondTrack.path)
        XCTAssertTrue(storedSecondTrack.isFavorite)
        XCTAssertEqual((try database.tracks()).count, 2)
    }

    func testReconcileReplacesExactPathWhenIdentityIsAmbiguous() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test-tmp", isDirectory: true)
            .appendingPathComponent("playlist-ambiguous-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let firstPath = root.appendingPathComponent("first.flac").path
        let secondPath = root.appendingPathComponent("second.flac").path
        let original = Track(
            path: firstPath,
            title: "Original",
            artistDisplay: "Artist",
            albumTitle: "Album",
            firstSeenAtUTC: Date(timeIntervalSinceReferenceDate: 100),
            fileResourceIdentifier: "resource-1",
            fileVolumeIdentifier: "volume-1",
            isFavorite: true
        )
        let originalID = try database.save(track: original, rootID: rootID)
        let firstIncoming = Track(
            path: firstPath,
            title: "Updated",
            artistDisplay: "Artist",
            albumTitle: "Album",
            firstSeenAtUTC: Date(timeIntervalSinceReferenceDate: 200),
            fileResourceIdentifier: "resource-1",
            fileVolumeIdentifier: "volume-1"
        )
        let secondIncoming = Track(
            path: secondPath,
            title: "Linked",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "resource-1",
            fileVolumeIdentifier: "volume-1"
        )
        try database.reconcile(
            rootPath: root.path,
            tracks: [firstIncoming, secondIncoming],
            lyricFiles: []
        )

        let storedOriginal = try XCTUnwrap(database.tracks().first { $0.path == firstPath })
        XCTAssertNotEqual(storedOriginal.id, originalID)
        XCTAssertEqual(storedOriginal.title, "Updated")
        XCTAssertEqual(storedOriginal.firstSeenAtUTC, firstIncoming.firstSeenAtUTC)
        XCTAssertFalse(storedOriginal.isFavorite)
        XCTAssertEqual((try database.tracks()).count, 2)
    }

    func testIncrementalAmbiguityCountsProtectedIdentityRows() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test-tmp", isDirectory: true)
            .appendingPathComponent("incremental-identity-ambiguity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let firstPath = root.appendingPathComponent("first.flac").path
        let secondPath = root.appendingPathComponent("second.flac").path
        try Data([1]).write(to: URL(fileURLWithPath: firstPath))
        try Data([2]).write(to: URL(fileURLWithPath: secondPath))

        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let firstSeenAtUTC = Date(timeIntervalSinceReferenceDate: 100)
        let original = Track(
            path: firstPath,
            title: "Original",
            artistDisplay: "Artist",
            albumTitle: "Album",
            firstSeenAtUTC: firstSeenAtUTC,
            fileResourceIdentifier: "shared-resource",
            fileVolumeIdentifier: "shared-volume",
            isFavorite: true
        )
        let originalID = try database.save(track: original, rootID: rootID)
        let protectedTrack = Track(
            path: secondPath,
            title: "Unchanged",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "shared-resource",
            fileVolumeIdentifier: "shared-volume",
            isFavorite: true
        )
        let protectedID = try database.save(track: protectedTrack, rootID: rootID)
        let changedTrack = Track(
            path: firstPath,
            title: "Changed",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "shared-resource",
            fileVolumeIdentifier: "shared-volume"
        )
        let input = CatalogReconcileInput(
            rootPath: root.path,
            tracks: [changedTrack],
            expectedPaths: Set([firstPath, secondPath]),
            lyricFiles: [],
            preservedPaths: [],
            preservedLyricPaths: []
        )
        _ = try database.reconcileIncremental(input)

        let storedFirst = try XCTUnwrap(database.tracks().first { $0.path == firstPath })
        let storedProtected = try XCTUnwrap(database.tracks().first { $0.path == secondPath })
        XCTAssertNotEqual(storedFirst.id, originalID)
        XCTAssertEqual(storedProtected.id, protectedID)
        XCTAssertTrue(storedProtected.isFavorite)
        XCTAssertEqual(storedProtected.title, "Unchanged")
        XCTAssertEqual(try database.tracks().count, 2)
    }

}
