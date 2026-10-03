import Foundation
import GRDB
@testable import WavebookCore
import XCTest

final class SchemaMigrationTests: XCTestCase {
    func testDatabaseInitializerMigratesSchema13To17AndRebuildsSearchData() throws {
        let path = try PlaylistSchemaTestSupport.makeLegacyDatabasePath(schemaVersion: 13)
        try PlaylistSchemaTestSupport.seedLegacySearchData(path: path)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let database = try LibraryDatabase(path: path)
        try database.writer.read { connection in
            XCTAssertEqual(try Int.fetchOne(connection, sql: "PRAGMA user_version"), 17)
            try LibraryDatabase.validateSchema(db: connection)
        }
        try assertMigratedScopedSearchData(in: database)
    }

    func testDatabaseInitializerMigratesSchema12Through17AndRebuildsSearchData() throws {
        let path = try PlaylistSchemaTestSupport.makeLegacyDatabasePath(schemaVersion: 12)
        try PlaylistSchemaTestSupport.seedLegacySearchData(path: path)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let database = try LibraryDatabase(path: path)
        try database.writer.read { connection in
            XCTAssertEqual(try Int.fetchOne(connection, sql: "PRAGMA user_version"), 17)
            XCTAssertNotNil(
                try String.fetchOne(connection, sql: "SELECT name FROM sqlite_master WHERE name = 'trackSkipSegments'")
            )
            try LibraryDatabase.validateSchema(db: connection)
        }
        try assertMigratedScopedSearchData(in: database)
    }

    func testDatabaseInitializerMigratesSchemas15And16ThroughSearchRebuild() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for schemaVersion in [15, 16] {
            let path = directory.appendingPathComponent("schema-\(schemaVersion)-\(UUID().uuidString).sqlite").path
            addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
            do {
                let seedDatabase = try LibraryDatabase(path: path)
                try seedDatabase.writer.write { connection in
                    try connection.execute(
                        sql: "INSERT INTO roots (path) VALUES (?)",
                        arguments: ["/schema-\(schemaVersion)"]
                    )
                    let rootID = try XCTUnwrap(Int64.fetchOne(connection, sql: "SELECT id FROM roots"))
                    try connection.execute(
                        sql: """
                            INSERT INTO tracks (rootId, path, title, artistDisplay, albumTitle)
                            VALUES (?, ?, ?, ?, ?)
                            """,
                        arguments: [rootID, "/schema-\(schemaVersion)/Song.wav", "Song", "Artist", "Album"]
                    )
                    try connection.execute(sql: "ALTER TABLE tracks DROP COLUMN albumSearchText")
                    try connection.execute(sql: "ALTER TABLE tracks DROP COLUMN titleSearchText")
                    try connection.execute(sql: "PRAGMA user_version = \(schemaVersion)")
                }
            }

            let database = try LibraryDatabase(path: path)
            try database.writer.read { connection in
                XCTAssertEqual(try Int.fetchOne(connection, sql: "PRAGMA user_version"), 17)
                XCTAssertEqual(
                    try String.fetchOne(connection, sql: "SELECT titleSearchText FROM tracks WHERE title = 'Song'"),
                    SearchNormalizer.normalizedText("Song")
                )
                XCTAssertEqual(
                    try String.fetchOne(connection, sql: "SELECT albumSearchText FROM tracks WHERE title = 'Song'"),
                    SearchNormalizer.normalizedText("Album")
                )
                try LibraryDatabase.validateSchema(db: connection)
            }
        }
    }

    func testSchema12MigrationRunsBeforeSchema13Migration() throws {
        let database = try PlaylistSchemaTestSupport.makeLegacyDatabase()
        let storedModificationDate = Date(timeIntervalSinceReferenceDate: 1234)
        let migrationDate = Date(timeIntervalSinceReferenceDate: 5678)

        try database.write { connection in
            try connection.execute(
                sql: "INSERT INTO tracks (rootId, path, title, mtime) VALUES (?, ?, ?, ?)",
                arguments: [1, "/missing-with-mtime.flac", "Stored", storedModificationDate]
            )
            try connection.execute(
                sql: "INSERT INTO tracks (rootId, path, title) VALUES (?, ?, ?)",
                arguments: [1, "/missing-without-mtime.flac", "Fallback"]
            )
            try connection.execute(sql: "PRAGMA user_version = 12")
            try LibraryDatabase.migrateFromSchema12(db: connection)
            try LibraryDatabase.migrateFromSchema13(db: connection, migrationDate: migrationDate)

            XCTAssertEqual(try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM trackSkipSegments"), 0)
            XCTAssertEqual(
                try Double.fetchOne(
                    connection,
                    sql: "SELECT firstSeenAtUTC FROM tracks WHERE title = ?",
                    arguments: ["Stored"]
                ),
                storedModificationDate.timeIntervalSinceReferenceDate
            )
            XCTAssertEqual(
                try Double.fetchOne(
                    connection,
                    sql: "SELECT firstSeenAtUTC FROM tracks WHERE title = ?",
                    arguments: ["Fallback"]
                ),
                migrationDate.timeIntervalSinceReferenceDate
            )
            XCTAssertNotNil(
                try String.fetchOne(connection, sql: "SELECT name FROM sqlite_master WHERE name = 'playlists'")
            )
            XCTAssertNotNil(
                try String.fetchOne(connection, sql: "SELECT name FROM sqlite_master WHERE name = 'playlistItems'")
            )
        }
    }

    func testSchema14MigrationCanonicalizesResourceIdentitiesThroughInitializer() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("schema14-\(UUID().uuidString).sqlite").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        try seedSchema14MigrationDatabase(at: path)

        let database = try LibraryDatabase(path: path)
        try database.writer.read { connection in
            XCTAssertEqual(try Int.fetchOne(connection, sql: "PRAGMA user_version"), 17)
            XCTAssertEqual(
                try String.fetchOne(connection, sql: "SELECT fileVolumeIdentifier FROM tracks"),
                "volume-1"
            )
            XCTAssertEqual(
                try String.fetchOne(connection, sql: "SELECT fileResourceIdentifier FROM tracks"),
                "resource-1"
            )
            XCTAssertEqual(
                try String.fetchOne(connection, sql: "SELECT sourceVolumeIdentifier FROM playlistItems"),
                "volume-1"
            )
            XCTAssertEqual(
                try String.fetchOne(connection, sql: "SELECT sourceResourceIdentifier FROM playlistItems"),
                "resource-1"
            )
            try LibraryDatabase.validateSchema(db: connection)
        }
    }

    private func seedSchema14MigrationDatabase(at path: String) throws {
        let seedDatabase = try LibraryDatabase(path: path)
        try seedDatabase.writer.write { connection in
            try connection.execute(sql: "INSERT INTO roots (path) VALUES (?)", arguments: ["/music"])
            let rootID = try XCTUnwrap(Int64.fetchOne(connection, sql: "SELECT id FROM roots"))
            try connection.execute(
                sql: """
                    INSERT INTO tracks (rootId, path, title, fileResourceIdentifier, fileVolumeIdentifier)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    rootID, "/music/song.flac", "Song",
                    "\tresource-1\n", "\tvolume-1\n"
                ]
            )
            let trackID = try XCTUnwrap(Int64.fetchOne(connection, sql: "SELECT id FROM tracks"))
            try connection.execute(
                sql: "INSERT INTO playlists (name, kind, createdAtUTC) VALUES (?, ?, ?)",
                arguments: ["Mix", PlaylistKind.manual.rawValue, 0]
            )
            let playlistID = try XCTUnwrap(Int64.fetchOne(connection, sql: "SELECT id FROM playlists"))
            try connection.execute(
                sql: """
                    INSERT INTO playlistItems (
                        playlistID, ordinal, trackID, sourceVolumeIdentifier, sourceResourceIdentifier,
                        snapshotPath, snapshotTitle, snapshotArtistDisplay, snapshotAlbumTitle,
                        snapshotGenreDisplay, snapshotDuration, snapshotFormat
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    playlistID, 0, trackID,
                    "\tvolume-1\n", "\tresource-1\n",
                    "/music/song.flac", "Song", "Artist", "Album", "", 1.0, "flac"
                ]
            )
            try connection.execute(sql: "PRAGMA user_version = 14")
        }
    }

    func testSchema13MigrationRollsBackWhenPlaylistSchemaCreationFails() throws {
        let database = try PlaylistSchemaTestSupport.makeLegacyDatabase()
        try database.write { connection in
            try connection.execute(sql: "CREATE TABLE playlistItems (id INTEGER PRIMARY KEY)")
        }

        XCTAssertThrowsError(
            try database.write { connection in
                try LibraryDatabase.migrateFromSchema13(
                    db: connection,
                    migrationDate: Date(timeIntervalSinceReferenceDate: 1)
                )
            }
        )

        try database.read { connection in
            XCTAssertFalse(
                try PlaylistSchemaTestSupport.tableColumns("tracks", db: connection).contains("firstSeenAtUTC")
            )
            XCTAssertNil(
                try String.fetchOne(connection, sql: "SELECT name FROM sqlite_master WHERE name = 'playlists'")
            )
            XCTAssertEqual(try PlaylistSchemaTestSupport.tableColumns("playlistItems", db: connection), ["id"])
        }
    }

    private func assertMigratedScopedSearchData(in database: LibraryDatabase) throws {
        XCTAssertEqual(
            try database.trackPage(
                for: .all,
                matching: "its signalfire",
                searchField: .title,
                limit: 10
            ).tracks.map(\.title),
            ["It's Signal-Fire"]
        )
        XCTAssertEqual(
            try database.artistPage(matching: "bjork", limit: 10).items.map(\.name),
            ["Björk"]
        )
        XCTAssertEqual(
            try database.albumPage(matching: "bestof", limit: 10).items.map(\.key.title),
            ["Best-Of"]
        )
        XCTAssertEqual(
            try database.genrePage(matching: "chillout", limit: 10).items.map(\.name),
            ["Chill-Out"]
        )
    }

    func testSchemaCheckExtractionIgnoresConstraintLayout() {
        let canonical = """
            CREATE TABLE tracks (
                isFavorite INTEGER NOT NULL DEFAULT 0 CHECK (isFavorite IN (0, 1))
            )
            """
        let historical = """
            CREATE TABLE tracks (
                isFavorite INTEGER NOT NULL CHECK(isFavorite IN (0, 1)) DEFAULT 0
            )
            """

        XCTAssertEqual(
            schemaCheckExpressions(in: canonical),
            schemaCheckExpressions(in: historical)
        )
    }

    func testSchemaCheckExtractionDistinguishesConstraintExpressions() {
        XCTAssertNotEqual(
            schemaCheckExpressions(in: "CHECK (isFavorite IN (0, 1))"),
            schemaCheckExpressions(in: "CHECK (isFavorite IN (0, 2))")
        )
    }
}
