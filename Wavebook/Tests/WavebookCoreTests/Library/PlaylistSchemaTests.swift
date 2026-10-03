import Foundation
import GRDB
@testable import WavebookCore
import XCTest

private struct PlaylistConstraintFixture {
    let playlistID: Int64
    let trackID: Int64
    let itemSQL: String
}

final class PlaylistSchemaTests: XCTestCase {
    func testFreshDatabaseCreatesSchemaV17PlaylistFoundation() throws {
        let database = try LibraryDatabase(inMemory: true)

        try database.writer.read { connection in
            XCTAssertEqual(try Int.fetchOne(connection, sql: "PRAGMA user_version"), 17)
            XCTAssertEqual(
                Array(try PlaylistSchemaTestSupport.tableColumns("tracks", db: connection).suffix(6)),
                [
                    "firstSeenAtUTC", "fileResourceIdentifier", "fileVolumeIdentifier", "isFavorite",
                    "titleSearchText", "albumSearchText"
                ]
            )
            XCTAssertEqual(
                try PlaylistSchemaTestSupport.tableColumns("playlists", db: connection),
                ["id", "name", "kind", "createdAtUTC", "rulesJSON", "sortField", "sortDescending"]
            )
            XCTAssertEqual(
                try PlaylistSchemaTestSupport.tableColumns("playlistItems", db: connection),
                [
                    "id", "playlistID", "ordinal", "trackID", "sourceVolumeIdentifier", "sourceResourceIdentifier",
                    "snapshotPath", "snapshotTitle", "snapshotArtistDisplay", "snapshotAlbumTitle",
                    "snapshotGenreDisplay", "snapshotDuration", "snapshotFormat"
                ]
            )
            let indexes = try String.fetchAll(
                connection,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'index' AND name IN (?, ?, ?, ?)
                    ORDER BY name
                    """,
                arguments: [
                    "tracks_fileResourceIdentity",
                    "playlists_name",
                    "playlistItems_playlist_track",
                    "playlistItems_sourceResourceIdentity"
                ]
            )
            XCTAssertEqual(
                indexes,
                [
                    "playlistItems_playlist_track",
                    "playlistItems_sourceResourceIdentity",
                    "playlists_name",
                    "tracks_fileResourceIdentity"
                ]
            )
        }
    }

    func testPlaylistConstraintsAllowDuplicateTracksAndPreserveUnavailableRows() throws {
        let database = try LibraryDatabase(inMemory: true)

        try database.writer.write { connection in
            let fixture = try makePlaylistConstraintFixture(in: connection)
            try assertPlaylistConstraints(in: connection, fixture: fixture)
        }
    }

    private func makePlaylistConstraintFixture(in connection: Database) throws -> PlaylistConstraintFixture {
        try connection.execute(sql: "INSERT INTO roots (path) VALUES (?)", arguments: ["/music"])
        let rootID = try XCTUnwrap(Int64.fetchOne(connection, sql: "SELECT id FROM roots"))
        try connection.execute(
            sql: "INSERT INTO tracks (rootId, path, title) VALUES (?, ?, ?)",
            arguments: [rootID, "/music/song.flac", "Song"]
        )
        let trackID = try XCTUnwrap(Int64.fetchOne(connection, sql: "SELECT id FROM tracks"))
        try connection.execute(
            sql: "INSERT INTO playlists (name, kind, createdAtUTC) VALUES (?, ?, ?)",
            arguments: ["Mix", PlaylistKind.manual.rawValue, 0]
        )
        let playlistID = try XCTUnwrap(Int64.fetchOne(connection, sql: "SELECT id FROM playlists"))
        try connection.execute(
            sql: """
                INSERT INTO playlists (name, kind, createdAtUTC, rulesJSON, sortField, sortDescending)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: ["Smart", PlaylistKind.smart.rawValue, 0, "{}", PlaylistSortField.album.rawValue, 1]
        )
        let itemSQL = """
            INSERT INTO playlistItems (
                playlistID, ordinal, trackID, snapshotPath, snapshotTitle,
                snapshotArtistDisplay, snapshotAlbumTitle, snapshotGenreDisplay,
                snapshotDuration, snapshotFormat
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        return PlaylistConstraintFixture(playlistID: playlistID, trackID: trackID, itemSQL: itemSQL)
    }

    private func assertPlaylistConstraints(
        in connection: Database,
        fixture: PlaylistConstraintFixture
    ) throws {
        let playlistID = fixture.playlistID
        let trackID = fixture.trackID
        let itemSQL = fixture.itemSQL
        XCTAssertThrowsError(
            try connection.execute(
                sql: """
                    INSERT INTO playlists (name, kind, createdAtUTC, rulesJSON, sortField)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: ["Invalid Sort", PlaylistKind.smart.rawValue, 0, "{}", "unsupported"]
            )
        )
        XCTAssertThrowsError(
            try connection.execute(
                sql: "INSERT INTO playlists (name, kind, createdAtUTC, rulesJSON) VALUES (?, ?, ?, ?)",
                arguments: ["Invalid Manual", PlaylistKind.manual.rawValue, 0, "{}"]
            )
        )
        let itemArguments: [DatabaseValueConvertible?] = [
            playlistID, 0, trackID, "/music/song.flac", "Song", "Artist", "Album", "", 1.0, "flac"
        ]
        try connection.execute(sql: itemSQL, arguments: StatementArguments(itemArguments))
        try connection.execute(
            sql: itemSQL,
            arguments: StatementArguments([
                playlistID, 1, trackID, "/music/song.flac", "Song", "Artist", "Album", "", 1.0, "flac"
            ] as [DatabaseValueConvertible?])
        )
        try connection.execute(
            sql: itemSQL,
            arguments: StatementArguments([
                playlistID, 2, nil, "/music/missing.flac", "Missing", "Artist", "Album", "", 1.0, "flac"
            ] as [DatabaseValueConvertible?])
        )

        XCTAssertThrowsError(
            try connection.execute(
                sql: itemSQL,
                arguments: StatementArguments([
                    playlistID, -1, trackID, "/music/negative.flac", "Negative", "Artist", "Album", "", 1.0, "flac"
                ] as [DatabaseValueConvertible?])
            )
        )
        XCTAssertThrowsError(
            try connection.execute(
                sql: "INSERT INTO playlists (name, kind, createdAtUTC) VALUES (?, ?, ?)",
                arguments: ["mix", PlaylistKind.manual.rawValue, 0]
            )
        )

        try connection.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [trackID])
        XCTAssertNil(try Int64.fetchOne(
            connection,
            sql: "SELECT trackID FROM playlistItems WHERE ordinal = 0"
        ))
        XCTAssertEqual(try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM playlistItems"), 3)
        try connection.execute(sql: "DELETE FROM playlists WHERE id = ?", arguments: [playlistID])
        XCTAssertEqual(try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM playlistItems"), 0)
    }

}
