import Foundation
import GRDB

extension LibraryDatabase {
    @discardableResult
    private static func addColumnIfMissing(
        _ column: String,
        to table: String,
        definition: String,
        database: Database
    ) throws -> Bool {
        let columns = try Row.fetchAll(database, sql: "PRAGMA table_info(\(table))").map { row in
            let name: String = row["name"]
            return name
        }
        guard !columns.contains(column) else { return false }
        try database.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(definition)")
        return true
    }
    static func migrateFromSchema12(db database: Database) throws {
        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS trackSkipSegments (
            id TEXT PRIMARY KEY,
            trackId INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
            startTime REAL NOT NULL CHECK (startTime >= 0),
            endTime REAL NOT NULL CHECK (endTime > startTime),
            UNIQUE (trackId, startTime, endTime)
        )
        """)
        try database.execute(
            sql: "CREATE INDEX IF NOT EXISTS trackSkipSegments_track "
                + "ON trackSkipSegments(trackId, startTime)"
        )
    }

    static func migrateFromSchema13(
        db database: Database,
        migrationDate: Date = Date()
    ) throws {
        let firstSeenWasAdded = try addColumnIfMissing(
            "firstSeenAtUTC",
            to: "tracks",
            definition: "firstSeenAtUTC REAL NOT NULL DEFAULT 0",
            database: database
        )
        try addColumnIfMissing(
            "fileResourceIdentifier",
            to: "tracks",
            definition: "fileResourceIdentifier TEXT",
            database: database
        )
        try addColumnIfMissing(
            "fileVolumeIdentifier",
            to: "tracks",
            definition: "fileVolumeIdentifier TEXT",
            database: database
        )
        try addColumnIfMissing(
            "isFavorite",
            to: "tracks",
            definition: "isFavorite INTEGER NOT NULL DEFAULT 0 CHECK (isFavorite IN (0, 1))",
            database: database
        )

        if firstSeenWasAdded {
            let fallbackDate = migrationDate.timeIntervalSinceReferenceDate.isFinite ? migrationDate : Date()
            let rows = try Row.fetchCursor(
                database,
                sql: "SELECT id, path, mtime FROM tracks"
            )
            while let row = try rows.next() {
                let path: String = row["path"]
                let storedModificationDate = Self.date(from: row, column: "mtime")
                let firstSeenAtUTC = migrationFirstSeenDate(
                    path: path,
                    storedModificationDate: storedModificationDate,
                    fallbackDate: fallbackDate
                )
                let trackID: Int64 = row["id"]
                try database.execute(
                    sql: "UPDATE tracks SET firstSeenAtUTC = ? WHERE id = ?",
                    arguments: [Self.databaseTimestamp(firstSeenAtUTC) ?? 0, trackID]
                )
            }
        }

        try createTrackResourceIdentityIndex(db: database)
        try createPlaylistPersistenceSchema(db: database)
    }
    static func migrateFromSchema14(db database: Database) throws {
        let trackRows = try Row.fetchCursor(
            database,
            sql: "SELECT id, fileVolumeIdentifier, fileResourceIdentifier FROM tracks"
        )
        let updateTrack = try database.makeStatement(sql: """
            UPDATE tracks
            SET fileVolumeIdentifier = ?, fileResourceIdentifier = ?
            WHERE id = ?
            """)
        while let row = try trackRows.next() {
            let trackID: Int64 = row["id"]
            let volumeIdentifier: String? = row["fileVolumeIdentifier"]
            let resourceIdentifier: String? = row["fileResourceIdentifier"]
            let canonicalVolumeIdentifier = CatalogResourceIdentity.canonicalComponent(volumeIdentifier)
            let canonicalResourceIdentifier = CatalogResourceIdentity.canonicalComponent(resourceIdentifier)
            guard volumeIdentifier != canonicalVolumeIdentifier
                    || resourceIdentifier != canonicalResourceIdentifier else {
                continue
            }
            try updateTrack.execute(arguments: [canonicalVolumeIdentifier, canonicalResourceIdentifier, trackID])
        }

        let playlistItemRows = try Row.fetchCursor(
            database,
            sql: "SELECT id, sourceVolumeIdentifier, sourceResourceIdentifier FROM playlistItems"
        )
        let updatePlaylistItem = try database.makeStatement(sql: """
            UPDATE playlistItems
            SET sourceVolumeIdentifier = ?, sourceResourceIdentifier = ?
            WHERE id = ?
            """)
        while let row = try playlistItemRows.next() {
            let itemID: Int64 = row["id"]
            let volumeIdentifier: String? = row["sourceVolumeIdentifier"]
            let resourceIdentifier: String? = row["sourceResourceIdentifier"]
            let canonicalVolumeIdentifier = CatalogResourceIdentity.canonicalComponent(volumeIdentifier)
            let canonicalResourceIdentifier = CatalogResourceIdentity.canonicalComponent(resourceIdentifier)
            guard volumeIdentifier != canonicalVolumeIdentifier
                    || resourceIdentifier != canonicalResourceIdentifier else {
                continue
            }
            try updatePlaylistItem.execute(arguments: [canonicalVolumeIdentifier, canonicalResourceIdentifier, itemID])
        }
    }
    static func migrateFromSchema16(db database: Database) throws {
        try addColumnIfMissing(
            "titleSearchText",
            to: "tracks",
            definition: "titleSearchText TEXT NOT NULL DEFAULT ''",
            database: database
        )
        try addColumnIfMissing(
            "albumSearchText",
            to: "tracks",
            definition: "albumSearchText TEXT NOT NULL DEFAULT ''",
            database: database
        )

        try rebuildTrackSearchText(db: database)

        let artistRows = try Row.fetchCursor(database, sql: "SELECT id, name FROM artistNames")
        let updateArtist = try database.makeStatement(
            sql: "UPDATE artistNames SET searchText = ? WHERE id = ?"
        )
        while let row = try artistRows.next() {
            let artistID: Int64 = row["id"]
            let name: String = row["name"]
            try updateArtist.execute(arguments: [SearchNormalizer.normalizedText(name), artistID])
        }

        let genreRows = try Row.fetchCursor(database, sql: "SELECT id, name FROM genreNames")
        let updateGenre = try database.makeStatement(
            sql: "UPDATE genreNames SET searchText = ? WHERE id = ?"
        )
        while let row = try genreRows.next() {
            let genreID: Int64 = row["id"]
            let name: String = row["name"]
            try updateGenre.execute(arguments: [SearchNormalizer.normalizedText(name), genreID])
        }

        try database.execute(sql: "INSERT INTO trackSearch(trackSearch) VALUES ('rebuild')")
    }
    private static func rebuildTrackSearchText(db database: Database) throws {
        let trackRows = try Row.fetchCursor(
            database,
            sql: """
                SELECT id, path, title, artistDisplay, albumTitle, albumArtist, genreDisplay
                FROM tracks
                """
        )
        let updateTrack = try database.makeStatement(sql: """
            UPDATE tracks
            SET searchText = ?, titleSearchText = ?, albumSearchText = ?
            WHERE id = ?
            """)
        while let row = try trackRows.next() {
            let trackID: Int64 = row["id"]
            let path: String = row["path"]
            let title: String = row["title"]
            let artistDisplay: String = row["artistDisplay"]
            let albumTitle: String = row["albumTitle"]
            let albumArtist: String? = row["albumArtist"]
            let genreDisplay: String = row["genreDisplay"]
            try updateTrack.execute(arguments: [
                SearchNormalizer.trackSearchText(
                    TrackSearchFields(
                        title: title,
                        artistDisplay: artistDisplay,
                        albumTitle: albumTitle,
                        albumArtist: albumArtist,
                        genreDisplay: genreDisplay,
                        path: path
                    )
                ),
                SearchNormalizer.normalizedText(title),
                SearchNormalizer.normalizedText(albumTitle),
                trackID
            ])
        }
    }

    static func createTrackResourceIdentityIndex(db database: Database) throws {
        try database.execute(
            sql: "CREATE INDEX IF NOT EXISTS tracks_fileResourceIdentity "
                + "ON tracks(fileVolumeIdentifier, fileResourceIdentifier)"
        )
    }

    static func createPlaylistPersistenceSchema(db database: Database) throws {
        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS playlists (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            kind TEXT NOT NULL CHECK (kind IN ('manual', 'smart')),
            createdAtUTC REAL NOT NULL,
            rulesJSON TEXT,
            sortField TEXT,
            sortDescending INTEGER NOT NULL DEFAULT 0 CHECK (sortDescending IN (0, 1)),
            CHECK (
                (kind = 'manual' AND rulesJSON IS NULL AND sortField IS NULL AND sortDescending = 0)
                OR
                (kind = 'smart' AND rulesJSON IS NOT NULL AND sortField IN ('album', 'firstSeen',
                    'qualifiedPlays', 'duration'))
            )
        )
        """)
        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS playlistItems (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            playlistID INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
            trackID INTEGER REFERENCES tracks(id) ON DELETE SET NULL,
            sourceVolumeIdentifier TEXT,
            sourceResourceIdentifier TEXT,
            snapshotPath TEXT NOT NULL,
            snapshotTitle TEXT NOT NULL,
            snapshotArtistDisplay TEXT NOT NULL,
            snapshotAlbumTitle TEXT NOT NULL,
            snapshotGenreDisplay TEXT NOT NULL,
            snapshotDuration REAL NOT NULL,
            snapshotFormat TEXT NOT NULL,
            UNIQUE (playlistID, ordinal)
        )
        """)
        try database.execute(
            sql: "CREATE UNIQUE INDEX IF NOT EXISTS playlists_name "
                + "ON playlists(name COLLATE NOCASE)"
        )
        try database.execute(
            sql: "CREATE INDEX IF NOT EXISTS playlistItems_playlist_track "
                + "ON playlistItems(playlistID, trackID)"
        )
        try database.execute(
            sql: "CREATE INDEX IF NOT EXISTS playlistItems_sourceResourceIdentity "
                + "ON playlistItems(sourceVolumeIdentifier, sourceResourceIdentifier)"
        )
    }

    private static func migrationFirstSeenDate(
        path: String,
        storedModificationDate: Date?,
        fallbackDate: Date
    ) -> Date {
        let resourceValues = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.creationDateKey, .contentModificationDateKey]
        )
        if let creationDate = resourceValues?.creationDate,
           creationDate.timeIntervalSinceReferenceDate.isFinite {
            return creationDate
        }
        if let modificationDate = resourceValues?.contentModificationDate,
           modificationDate.timeIntervalSinceReferenceDate.isFinite {
            return modificationDate
        }
        if let storedModificationDate,
           storedModificationDate.timeIntervalSinceReferenceDate.isFinite {
            return storedModificationDate
        }
        return fallbackDate
    }
}
