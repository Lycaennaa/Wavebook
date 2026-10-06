import Foundation
import GRDB
@testable import WavebookCore
import XCTest

final class CatalogPlaylistIdentityTests: XCTestCase {
private struct PlaylistItemState {
    let trackID: Int64?
    let sourceVolumeIdentifier: String?
    let sourceResourceIdentifier: String?
}

    func testReplacementPreservesIdentityAndLaterReconcileReattachesPlaylistItem() throws {
        let root = try makeRoot(named: "playlist-orphan-save")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let originalPath = root.appendingPathComponent("song.flac").path
        let original = Track(
            path: originalPath,
            title: "Original",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "resource-1",
            fileVolumeIdentifier: "volume-1"
        )
        let originalID = try database.save(track: original, rootID: rootID)
        try insertPlaylistItem(in: database, trackID: originalID, snapshotPath: originalPath)

        let replacement = Track(
            path: originalPath,
            title: "Replacement",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "resource-2",
            fileVolumeIdentifier: "volume-1"
        )
        try database.reconcile(rootPath: root.path, tracks: [replacement], lyricFiles: [])

        let orphaned = try playlistItemState(in: database)
        XCTAssertNil(orphaned.trackID)
        XCTAssertEqual(orphaned.sourceVolumeIdentifier, "volume-1")
        XCTAssertEqual(orphaned.sourceResourceIdentifier, "resource-1")

        let restored = Track(
            path: root.appendingPathComponent("restored.flac").path,
            title: "Restored",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "resource-1",
            fileVolumeIdentifier: "volume-1"
        )

        try database.reconcile(rootPath: root.path, tracks: [replacement, restored], lyricFiles: [])

        XCTAssertEqual(
            try trackID(forPath: restored.path, in: database),
            try XCTUnwrap(playlistItemState(in: database).trackID)
        )
    }
    func testPublicSaveReattachesOrphanedPlaylistItem() throws {
        let root = try makeRoot(named: "playlist-orphan-public-save")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let originalPath = root.appendingPathComponent("song.flac").path
        let original = Track(
            path: originalPath,
            title: "Original",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "resource-1",
            fileVolumeIdentifier: "volume-1"
        )
        let originalID = try database.save(track: original, rootID: rootID)
        try insertPlaylistItem(in: database, trackID: originalID, snapshotPath: originalPath)

        let replacement = Track(
            path: originalPath,
            title: "Replacement",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "resource-2",
            fileVolumeIdentifier: "volume-1"
        )
        try database.reconcile(rootPath: root.path, tracks: [replacement], lyricFiles: [])
        XCTAssertNil(try playlistItemState(in: database).trackID)

        let restored = Track(
            path: root.appendingPathComponent("restored.flac").path,
            title: "Restored",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "resource-1",
            fileVolumeIdentifier: "volume-1"
        )
        let restoredID = try database.save(track: restored, rootID: rootID)

        XCTAssertEqual(try playlistItemState(in: database).trackID, restoredID)
    }

    func testPublicSaveRejectsStaleTrackAfterReplacement() throws {
        let root = try makeRoot(named: "playlist-stale-save")
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
        _ = try database.save(track: original, rootID: rootID)
        let persistedOriginal = try XCTUnwrap(
            try database.reconcile(rootPath: root.path, tracks: [original], lyricFiles: []).first
        )
        let originalID = try XCTUnwrap(persistedOriginal.id)
        let replacement = Track(
            path: path,
            title: "Replacement",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "resource-2",
            fileVolumeIdentifier: "volume-1"
        )
        try database.reconcile(rootPath: root.path, tracks: [replacement], lyricFiles: [])

        var stale = persistedOriginal
        stale.id = originalID
        XCTAssertThrowsError(try database.save(track: stale, rootID: rootID)) { error in
            XCTAssertEqual(error as? LibraryDatabaseError, .staleTrackID(originalID))
        }
        stale.id = nil
        XCTAssertThrowsError(try database.save(track: stale, rootID: rootID)) { error in
            XCTAssertEqual(error as? LibraryDatabaseError, .conflictingTrackIdentity(path))
        }
        let stored = try XCTUnwrap(database.tracks().first)
        XCTAssertEqual(stored.title, "Replacement")
        XCTAssertEqual(stored.fileResourceIdentifier, "resource-2")

        try database.reconcile(rootPath: root.path, tracks: [], lyricFiles: [])
        XCTAssertThrowsError(try database.save(track: persistedOriginal, rootID: rootID)) { error in
            XCTAssertEqual(error as? LibraryDatabaseError, .staleTrackID(originalID))
        }
        XCTAssertTrue(try database.tracks().isEmpty)

    }
    func testAmbiguousLiveIdentityDoesNotReattachOrphanedPlaylistItem() throws {
        let root = try makeRoot(named: "playlist-orphan-ambiguous")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let originalPath = root.appendingPathComponent("song.flac").path
        let original = Track(
            path: originalPath,
            title: "Original",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "resource-1",
            fileVolumeIdentifier: "volume-1"
        )
        let originalID = try database.save(track: original, rootID: rootID)
        try insertPlaylistItem(in: database, trackID: originalID, snapshotPath: originalPath)

        let replacement = Track(
            path: originalPath,
            title: "Replacement",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "resource-2",
            fileVolumeIdentifier: "volume-1"
        )
        try database.reconcile(rootPath: root.path, tracks: [replacement], lyricFiles: [])

        let first = Track(
            path: root.appendingPathComponent("first.flac").path,
            title: "First",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "resource-1",
            fileVolumeIdentifier: "volume-1"
        )
        let second = Track(
            path: root.appendingPathComponent("second.flac").path,
            title: "Second",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: " resource-1 ",
            fileVolumeIdentifier: " volume-1 "
        )
        try database.reconcile(rootPath: root.path, tracks: [first, second], lyricFiles: [])

        let state = try playlistItemState(in: database)
        XCTAssertNil(state.trackID)
        XCTAssertEqual(state.sourceVolumeIdentifier, "volume-1")
        XCTAssertEqual(state.sourceResourceIdentifier, "resource-1")
        XCTAssertEqual(
            try database.writer.read { connection in
                try String.fetchAll(connection, sql: "SELECT fileVolumeIdentifier FROM tracks ORDER BY id")
            },
            ["volume-1", "volume-1"]
        )
    }

    func testPruningTrackBackfillsPlaylistItemIdentityBeforeDeletion() throws {
        let root = try makeRoot(named: "playlist-orphan-prune")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let path = root.appendingPathComponent("song.flac").path
        let track = Track(
            path: path,
            title: "Song",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "resource-1",
            fileVolumeIdentifier: "volume-1"
        )
        let trackID = try database.save(track: track, rootID: rootID)
        try insertPlaylistItem(in: database, trackID: trackID, snapshotPath: path)

        XCTAssertEqual(try database.pruneMissingTracks(rootPath: root.path, existingPaths: []), 1)

        let state = try playlistItemState(in: database)
        XCTAssertNil(state.trackID)
        XCTAssertEqual(state.sourceVolumeIdentifier, "volume-1")
        XCTAssertEqual(state.sourceResourceIdentifier, "resource-1")
    }
}

extension CatalogPlaylistIdentityTests {

    func testPartialPlaylistIdentityIsNotCompletedBeforeDeletion() throws {
        let root = try makeRoot(named: "playlist-orphan-partial")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let path = root.appendingPathComponent("song.flac").path
        let original = Track(
            path: path,
            title: "Original",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "resource-2",
            fileVolumeIdentifier: "volume-2"
        )
        let originalID = try database.save(track: original, rootID: rootID)
        try insertPlaylistItem(
            in: database,
            trackID: originalID,
            snapshotPath: path,
            sourceVolumeIdentifier: "volume-1"
        )

        let replacement = Track(
            path: path,
            title: "Replacement",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "resource-3",
            fileVolumeIdentifier: "volume-3"
        )
        try database.reconcile(rootPath: root.path, tracks: [replacement], lyricFiles: [])

        let state = try playlistItemState(in: database)
        XCTAssertNil(state.trackID)
        XCTAssertEqual(state.sourceVolumeIdentifier, "volume-1")
        XCTAssertNil(state.sourceResourceIdentifier)

        let unrelated = Track(
            path: root.appendingPathComponent("unrelated.flac").path,
            title: "Unrelated",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "resource-2",
            fileVolumeIdentifier: "volume-1"
        )
        _ = try database.save(track: unrelated, rootID: rootID)

        let unchanged = try playlistItemState(in: database)
        XCTAssertNil(unchanged.trackID)
        XCTAssertEqual(unchanged.sourceVolumeIdentifier, "volume-1")
        XCTAssertNil(unchanged.sourceResourceIdentifier)
    }

    func testCrossRootDuplicateIdentityDoesNotReattachOrphanedPlaylistItem() throws {
        let root = try makeRoot(named: "playlist-orphan-cross-root-a")
        let otherRoot = try makeRoot(named: "playlist-orphan-cross-root-b")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let otherRootID = try database.addRoot(path: otherRoot.path)
        let originalPath = root.appendingPathComponent("song.flac").path
        let original = Track(
            path: originalPath,
            title: "Original",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "resource-1",
            fileVolumeIdentifier: "volume-1"
        )
        let originalID = try database.save(track: original, rootID: rootID)
        try insertPlaylistItem(in: database, trackID: originalID, snapshotPath: originalPath)

        let replacement = Track(
            path: originalPath,
            title: "Replacement",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "resource-2",
            fileVolumeIdentifier: "volume-1"
        )
        try database.reconcile(rootPath: root.path, tracks: [replacement], lyricFiles: [])

        let first = Track(
            path: root.appendingPathComponent("first.flac").path,
            title: "First",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "resource-1",
            fileVolumeIdentifier: "volume-1"
        )
        let second = Track(
            path: otherRoot.appendingPathComponent("second.flac").path,
            title: "Second",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: " resource-1 ",
            fileVolumeIdentifier: " volume-1 "
        )
        try database.writer.write { connection in
            _ = try LibraryDatabase.save(
                track: first,
                rootID: rootID,
                fingerprint: ReplayGainFileFingerprint.current(path: first.path),
                database: connection
            )
            _ = try LibraryDatabase.save(
                track: second,
                rootID: otherRootID,
                fingerprint: ReplayGainFileFingerprint.current(path: second.path),
                database: connection
            )
            try LibraryDatabase.reattachOrphanedPlaylistItems(db: connection)
        }

        XCTAssertNil(try playlistItemState(in: database).trackID)
    }

    func testPruningReattachesExistingUniqueOrphanedPlaylistItem() throws {
        let root = try makeRoot(named: "playlist-orphan-prune-reattach")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let targetPath = root.appendingPathComponent("target.flac").path
        let target = Track(
            path: targetPath,
            title: "Target",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "resource-1",
            fileVolumeIdentifier: "volume-1"
        )
        _ = try database.save(track: target, rootID: rootID)
        try insertPlaylistItem(
            in: database,
            trackID: nil,
            snapshotPath: targetPath,
            sourceVolumeIdentifier: "volume-1",
            sourceResourceIdentifier: "resource-1"
        )
        let missing = Track(
            path: root.appendingPathComponent("missing.flac").path,
            title: "Missing",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "resource-2",
            fileVolumeIdentifier: "volume-1"
        )
        _ = try database.save(track: missing, rootID: rootID)

        XCTAssertEqual(try database.pruneMissingTracks(rootPath: root.path, existingPaths: [targetPath]), 1)
        XCTAssertEqual(try playlistItemState(in: database).trackID, try trackID(forPath: targetPath, in: database))
    }

    private func makeRoot(named name: String) throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test-tmp", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func insertPlaylistItem(
        in database: LibraryDatabase,
        trackID: Int64?,
        snapshotPath: String,
        sourceVolumeIdentifier: String? = nil,
        sourceResourceIdentifier: String? = nil
    ) throws {
        try database.writer.write { connection in
            try connection.execute(
                sql: "INSERT INTO playlists (name, kind, createdAtUTC) VALUES (?, ?, ?)",
                arguments: ["Identity Playlist", PlaylistKind.manual.rawValue, 0]
            )
            let playlistID = try XCTUnwrap(Int64.fetchOne(connection, sql: "SELECT id FROM playlists"))
            try connection.execute(
                sql: """
                    INSERT INTO playlistItems (
                        playlistID, ordinal, trackID, sourceVolumeIdentifier, sourceResourceIdentifier,
                        snapshotPath, snapshotTitle,
                        snapshotArtistDisplay, snapshotAlbumTitle, snapshotGenreDisplay,
                        snapshotDuration, snapshotFormat
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    playlistID, 0, trackID, sourceVolumeIdentifier, sourceResourceIdentifier,
                    snapshotPath, "Song", "Artist", "Album", "", 1.0, "flac"
                ]
            )
        }
    }

    private func trackID(forPath path: String, in database: LibraryDatabase) throws -> Int64 {
        try database.writer.read { connection in
            try XCTUnwrap(Int64.fetchOne(connection, sql: "SELECT id FROM tracks WHERE path = ?", arguments: [path]))
        }
    }

    private func playlistItemState(in database: LibraryDatabase) throws -> PlaylistItemState {
        try database.writer.read { connection in
            let row = try XCTUnwrap(Row.fetchOne(
                connection,
                sql: "SELECT trackID, sourceVolumeIdentifier, sourceResourceIdentifier FROM playlistItems"
            ))
            return PlaylistItemState(
                trackID: row["trackID"],
                sourceVolumeIdentifier: row["sourceVolumeIdentifier"],
                sourceResourceIdentifier: row["sourceResourceIdentifier"]
            )
        }
    }
    func testRemovingRootPreservesFilesAndPlaylistIdentity() throws {
        let root = try makeRoot(named: "root-removal")
        let path = root.appendingPathComponent("song.flac").path
        try Data().write(to: URL(fileURLWithPath: path))
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let track = Track(
            path: path,
            title: "Song",
            artistDisplay: "Artist",
            albumTitle: "Album",
            fileResourceIdentifier: "resource-1",
            fileVolumeIdentifier: "volume-1"
        )
        let trackID = try database.save(track: track, rootID: rootID)
        try insertPlaylistItem(in: database, trackID: trackID, snapshotPath: path)

        XCTAssertTrue(try database.removeRoot(id: rootID))
        XCTAssertTrue(try database.roots().isEmpty)
        XCTAssertTrue(try database.tracks().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let orphanedItem = try playlistItemState(in: database)
        XCTAssertNil(orphanedItem.trackID)
        XCTAssertEqual(orphanedItem.sourceVolumeIdentifier, "volume-1")
        XCTAssertEqual(orphanedItem.sourceResourceIdentifier, "resource-1")

        let restoredRootID = try database.addRoot(path: root.path)
        let restoredTrackID = try database.save(track: track, rootID: restoredRootID)
        XCTAssertEqual(try playlistItemState(in: database).trackID, restoredTrackID)
        XCTAssertFalse(try database.removeRoot(id: rootID))
    }
}
