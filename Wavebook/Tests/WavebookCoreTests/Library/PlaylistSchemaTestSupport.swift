import Foundation
import GRDB
@testable import WavebookCore
import XCTest

enum PlaylistSchemaTestSupport {
    static func makeLegacyDatabasePath(schemaVersion: Int) throws -> String {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(
            "playlist-schema-\(schemaVersion)-\(UUID().uuidString).sqlite"
        )
        do {
            let database = try LibraryDatabase(path: fileURL.path)
            try database.writer.writeWithoutTransaction { connection in
                try connection.execute(sql: "PRAGMA foreign_keys = OFF")
                for trigger in SchemaValidationSpecification.triggers {
                    try connection.execute(sql: "DROP TRIGGER IF EXISTS \(trigger.name)")
                }
                try connection.execute(sql: "DROP TABLE trackSearch")
                try connection.execute(sql: "DROP TABLE playlistItems")
                try connection.execute(sql: "DROP TABLE playlists")
                try connection.execute(sql: "DROP TABLE tracks")
                try connection.execute(sql: """
                    CREATE TABLE tracks (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        rootId INTEGER NOT NULL REFERENCES roots(id) ON DELETE CASCADE,
                        path TEXT NOT NULL UNIQUE ON CONFLICT REPLACE,
                        title TEXT NOT NULL,
                        artistDisplay TEXT NOT NULL DEFAULT '',
                        albumTitle TEXT NOT NULL DEFAULT '',
                        albumArtist TEXT,
                        genreDisplay TEXT NOT NULL DEFAULT '',
                        duration DOUBLE NOT NULL DEFAULT 0,
                        format TEXT NOT NULL DEFAULT '',
                        searchText TEXT NOT NULL DEFAULT '',
                        mtime DATETIME,
                        lyricsKey TEXT NOT NULL DEFAULT '',
                        fileSize INTEGER,
                        lyricsBasename TEXT NOT NULL DEFAULT ''
                    )
                    """)
                let indexes = [
                    ("tracks_searchText", "searchText"),
                    ("tracks_album", "albumTitle, albumArtist"),
                    ("tracks_lyricsKey", "lyricsKey"),
                    ("tracks_lyricsBasename", "lyricsBasename")
                ]
                for (name, columns) in indexes {
                    try connection.execute(sql: "CREATE INDEX \(name) ON tracks(\(columns))")
                }
                try connection.execute(sql: SchemaValidationSpecification.trackSearchDefinition)
                for trigger in SchemaValidationSpecification.triggers {
                    try connection.execute(sql: trigger.definition)
                }
                if schemaVersion == 12 {
                    try connection.execute(sql: "DROP INDEX trackSkipSegments_track")
                    try connection.execute(sql: "DROP TABLE trackSkipSegments")
                }
                try connection.execute(sql: "PRAGMA user_version = \(schemaVersion)")
                try connection.execute(sql: "PRAGMA foreign_keys = ON")
            }
        }
        return fileURL.path
    }

    static func seedLegacySearchData(path: String) throws {
        let database = try DatabaseQueue(path: path)
        try database.write { connection in
            try connection.execute(sql: "INSERT INTO roots (path) VALUES (?)", arguments: ["/legacy-search"])
            let rootID = try XCTUnwrap(Int64.fetchOne(connection, sql: "SELECT id FROM roots"))
            try connection.execute(
                sql: """
                    INSERT INTO tracks (
                        rootId, path, title, artistDisplay, albumTitle, albumArtist,
                        genreDisplay, duration, format, searchText
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    rootID, "/legacy-search/song.flac", "It's Signal-Fire", "Björk",
                    "Best-Of", "Björk", "Chill-Out", 1.0, "flac", "stale"
                ]
            )
            let trackID = try XCTUnwrap(Int64.fetchOne(connection, sql: "SELECT id FROM tracks"))
            try connection.execute(
                sql: "INSERT INTO artistNames (name, searchText) VALUES (?, ?)",
                arguments: ["Björk", "stale"]
            )
            let artistID = try XCTUnwrap(
                Int64.fetchOne(connection, sql: "SELECT id FROM artistNames WHERE name = ?", arguments: ["Björk"])
            )
            try connection.execute(
                sql: "INSERT INTO trackArtists (trackId, artistId) VALUES (?, ?)",
                arguments: [trackID, artistID]
            )
            try connection.execute(
                sql: "INSERT INTO genreNames (name, searchText) VALUES (?, ?)",
                arguments: ["Chill-Out", "stale"]
            )
            let genreID = try XCTUnwrap(
                Int64.fetchOne(connection, sql: "SELECT id FROM genreNames WHERE name = ?", arguments: ["Chill-Out"])
            )
            try connection.execute(
                sql: "INSERT INTO trackGenres (trackId, genreId) VALUES (?, ?)",
                arguments: [trackID, genreID]
            )
        }
    }

    static func makeLegacyDatabase() throws -> DatabaseQueue {
        let database = try DatabaseQueue()
        try database.write { connection in
            try connection.execute(
                sql: "CREATE TABLE roots (id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT NOT NULL UNIQUE)"
            )
            try connection.execute(sql: """
                CREATE TABLE tracks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    rootId INTEGER NOT NULL REFERENCES roots(id) ON DELETE CASCADE,
                    path TEXT NOT NULL UNIQUE ON CONFLICT REPLACE,
                    title TEXT NOT NULL,
                    artistDisplay TEXT NOT NULL DEFAULT '',
                    albumTitle TEXT NOT NULL DEFAULT '',
                    albumArtist TEXT,
                    genreDisplay TEXT NOT NULL DEFAULT '',
                    duration DOUBLE NOT NULL DEFAULT 0,
                    format TEXT NOT NULL DEFAULT '',
                    searchText TEXT NOT NULL DEFAULT '',
                    mtime DATETIME,
                    lyricsKey TEXT NOT NULL DEFAULT '',
                    fileSize INTEGER,
                    lyricsBasename TEXT NOT NULL DEFAULT ''
                )
                """)
            try connection.execute(sql: "INSERT INTO roots (path) VALUES (?)", arguments: ["/music"])
        }
        return database
    }

    static func tableColumns(_ table: String, db database: Database) throws -> [String] {
        try Row.fetchAll(database, sql: "PRAGMA table_info(\(table))").map { row in
            let name: String = row["name"]
            return name
        }
    }
}
