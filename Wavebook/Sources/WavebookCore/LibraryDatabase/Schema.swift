import Foundation
import GRDB

extension LibraryDatabase {
    static let currentSchemaVersion = 17

    nonisolated(unsafe) private static let createSchemaImplementation: (Database) throws -> Void = { database in
        let storedSchemaVersion = try Int.fetchOne(database, sql: "PRAGMA user_version") ?? 0
        guard storedSchemaVersion == 0
            || storedSchemaVersion == LibraryDatabase.currentSchemaVersion
            || storedSchemaVersion == LibraryDatabase.currentSchemaVersion - 1
            || storedSchemaVersion == LibraryDatabase.currentSchemaVersion - 2
            || storedSchemaVersion == LibraryDatabase.currentSchemaVersion - 3
            || storedSchemaVersion == LibraryDatabase.currentSchemaVersion - 4
            || storedSchemaVersion == LibraryDatabase.currentSchemaVersion - 5 else {
            throw LibraryDatabaseError.unsupportedSchemaVersion(storedSchemaVersion)
        }
        let hasExistingSchema = try LibraryDatabase.hasUserTables(db: database)
        if hasExistingSchema {
            if storedSchemaVersion == LibraryDatabase.currentSchemaVersion - 5
                || storedSchemaVersion == LibraryDatabase.currentSchemaVersion - 4 {
                try LibraryDatabase.migrateFromSchema12(db: database)
                try LibraryDatabase.migrateFromSchema13(db: database)
                try LibraryDatabase.migrateFromSchema14(db: database)
            } else if storedSchemaVersion == LibraryDatabase.currentSchemaVersion - 3 {
                try LibraryDatabase.migrateFromSchema13(db: database)
                try LibraryDatabase.migrateFromSchema14(db: database)
            } else if storedSchemaVersion == LibraryDatabase.currentSchemaVersion - 2 {
                try LibraryDatabase.migrateFromSchema14(db: database)
            }
            if storedSchemaVersion > 0, storedSchemaVersion < LibraryDatabase.currentSchemaVersion {
                try LibraryDatabase.migrateFromSchema16(db: database)
            }
            try LibraryDatabase.validateSchema(db: database)
            try database.execute(sql: "PRAGMA user_version = \(LibraryDatabase.currentSchemaVersion)")
            return
        }
        guard storedSchemaVersion == 0 else {
            throw LibraryDatabaseError.invalidSchema("Schema version \(storedSchemaVersion) has no schema")
        }
        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS roots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL UNIQUE ON CONFLICT REPLACE,
            lastScanAt DATETIME
        )
        """)

        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS tracks (
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
            lyricsBasename TEXT NOT NULL DEFAULT '',
            firstSeenAtUTC REAL NOT NULL DEFAULT 0,
            fileResourceIdentifier TEXT,
            fileVolumeIdentifier TEXT,
            isFavorite INTEGER NOT NULL DEFAULT 0 CHECK (isFavorite IN (0, 1)),
            titleSearchText TEXT NOT NULL DEFAULT '',
            albumSearchText TEXT NOT NULL DEFAULT ''
        )
        """)

        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS trackSkipSegments (
            id TEXT PRIMARY KEY,
            trackId INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
            startTime REAL NOT NULL CHECK (startTime >= 0),
            endTime REAL NOT NULL CHECK (endTime > startTime),
            UNIQUE (trackId, startTime, endTime)
        )
        """)
        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS artistNames (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE ON CONFLICT IGNORE,
            searchText TEXT NOT NULL
        )
        """)
        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS trackArtists (
            trackId INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
            artistId INTEGER NOT NULL REFERENCES artistNames(id) ON DELETE CASCADE,
            PRIMARY KEY (trackId, artistId) ON CONFLICT REPLACE
        )
        """)
        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS genreNames (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE ON CONFLICT IGNORE,
            searchText TEXT NOT NULL
        )
        """)
        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS trackGenres (
            trackId INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
            genreId INTEGER NOT NULL REFERENCES genreNames(id) ON DELETE CASCADE,
            PRIMARY KEY (trackId, genreId) ON CONFLICT REPLACE
        )
        """)
        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS eqProfiles (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            deviceUID TEXT NOT NULL UNIQUE ON CONFLICT REPLACE,
            preamp DOUBLE NOT NULL DEFAULT 0,
            isBypassed BOOLEAN NOT NULL DEFAULT 1,
            bandsJSON TEXT NOT NULL
        )
        """)
        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT NOT NULL,
            value DOUBLE NOT NULL,
            PRIMARY KEY (key) ON CONFLICT REPLACE
        )
        """)
        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS textSettings (
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            PRIMARY KEY (key) ON CONFLICT REPLACE
        )
        """)
        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS lyricFiles (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            rootId INTEGER NOT NULL REFERENCES roots(id) ON DELETE CASCADE,
            path TEXT NOT NULL,
            lyricsKey TEXT NOT NULL,
            UNIQUE (rootId, path) ON CONFLICT REPLACE
        )
        """)
        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS replayGainAnalysis (
            trackId INTEGER NOT NULL PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
            trackGainDB DOUBLE,
            trackPeak DOUBLE,
            trackGainSource TEXT,
            albumGainDB DOUBLE,
            albumPeak DOUBLE,
            albumGainSource TEXT,
            albumGeneration TEXT,
            analysisState TEXT NOT NULL DEFAULT '\(ReplayGainAnalysisState.pending.rawValue)',
            claimToken TEXT,
            trackRevision INTEGER NOT NULL DEFAULT 0,
            errorReason TEXT,
            errorAt DATETIME,
            sourceMtime DATETIME,
            sourceFileSize INTEGER,
            analyzerVersion INTEGER NOT NULL DEFAULT \(ReplayGain.analyzerVersion),
            tagSchemaVersion INTEGER NOT NULL DEFAULT \(ReplayGain.tagSchemaVersion),
            sourceContentFingerprint TEXT
        )
        """)

        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS listeningHistoryState (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            generation INTEGER NOT NULL,
            trackingStartedAtUTC REAL NOT NULL,
            isPrivate INTEGER NOT NULL DEFAULT 0 CHECK (isPrivate IN (0, 1))
        )
        """)
        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS listeningMediaSnapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            liveTrackId INTEGER REFERENCES tracks(id) ON DELETE SET NULL,
            metadataSignature TEXT NOT NULL,
            title TEXT NOT NULL,
            artistDisplay TEXT NOT NULL,
            albumTitle TEXT NOT NULL,
            albumOwner TEXT NOT NULL,
            genreDisplay TEXT NOT NULL,
            openedDuration REAL NOT NULL,
            format TEXT NOT NULL,
            createdAtUTC REAL NOT NULL
        )
        """)
        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS listeningSnapshotArtists (
            snapshotId INTEGER NOT NULL REFERENCES listeningMediaSnapshots(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            displayValue TEXT NOT NULL,
            PRIMARY KEY (snapshotId, ordinal),
            UNIQUE (snapshotId, displayValue)
        )
        """)
        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS listeningSnapshotGenres (
            snapshotId INTEGER NOT NULL REFERENCES listeningMediaSnapshots(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            displayValue TEXT NOT NULL,
            PRIMARY KEY (snapshotId, ordinal),
            UNIQUE (snapshotId, displayValue)
        )
        """)
        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS listeningEvents (
            id TEXT PRIMARY KEY,
            historyGeneration INTEGER NOT NULL,
            snapshotId INTEGER NOT NULL REFERENCES listeningMediaSnapshots(id) ON DELETE RESTRICT,
            sourceKind TEXT NOT NULL,
            sourcePersistentID INTEGER,
            sourceName TEXT,
            startedAtUTC REAL NOT NULL,
            startedUTCOffsetSeconds INTEGER NOT NULL,
            endedAtUTC REAL,
            endedUTCOffsetSeconds INTEGER,
            startPosition REAL NOT NULL,
            endPosition REAL,
            lastDurableCheckpointAtUTC REAL,
            lastDurableCheckpointUTCOffsetSeconds INTEGER,
            lastDurableCheckpointSequence INTEGER NOT NULL DEFAULT -1,
            endReason TEXT,
            qualifiedAtUTC REAL,
            qualifiedLocalDay TEXT,
            qualifiedUTCOffsetSeconds INTEGER,
            skipAtUTC REAL,
            skipLocalDay TEXT,
            skipUTCOffsetSeconds INTEGER
        )
        """)
        try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS listeningEventDays (
            eventId TEXT NOT NULL REFERENCES listeningEvents(id) ON DELETE CASCADE,
            localDay TEXT NOT NULL,
            utcOffsetSeconds INTEGER NOT NULL,
            actualListenedSeconds REAL NOT NULL,
            PRIMARY KEY (eventId, localDay, utcOffsetSeconds)
        )
        """)
        try LibraryDatabase.createTrackResourceIdentityIndex(db: database)
        try LibraryDatabase.createPlaylistPersistenceSchema(db: database)

        try database.execute(sql: "CREATE INDEX IF NOT EXISTS tracks_searchText ON tracks(searchText)")
        try database.execute(sql: """
            CREATE INDEX IF NOT EXISTS trackSkipSegments_track ON trackSkipSegments(trackId, startTime)
            """)
        try database.execute(sql: """
            CREATE INDEX IF NOT EXISTS tracks_album ON tracks(albumTitle, albumArtist)
            """)
        try database.execute(sql: """
            CREATE INDEX IF NOT EXISTS tracks_lyricsKey ON tracks(lyricsKey)
            """)
        try database.execute(sql: """
            CREATE INDEX IF NOT EXISTS tracks_lyricsBasename ON tracks(lyricsBasename)
            """)
        try database.execute(sql: """
            CREATE INDEX IF NOT EXISTS lyricFiles_lyricsKey ON lyricFiles(lyricsKey)
            """)
        try database.execute(sql: """
            CREATE INDEX IF NOT EXISTS replayGainAnalysis_state ON replayGainAnalysis(analysisState, trackId)
            """)
        try database.execute(sql: """
            CREATE INDEX IF NOT EXISTS replayGainAnalysis_albumGeneration ON replayGainAnalysis(albumGeneration)
            """)
        try database.execute(sql: """
            CREATE UNIQUE INDEX IF NOT EXISTS listeningMediaSnapshots_liveTrack_signature
                ON listeningMediaSnapshots(liveTrackId, metadataSignature)
            """)
        try database.execute(sql: """
            CREATE INDEX IF NOT EXISTS listeningSnapshotArtists_display ON listeningSnapshotArtists(displayValue)
            """)
        try database.execute(sql: """
            CREATE INDEX IF NOT EXISTS listeningSnapshotGenres_display ON listeningSnapshotGenres(displayValue)
            """)
        try database.execute(sql: """
            CREATE INDEX IF NOT EXISTS listeningEvents_generation ON listeningEvents(historyGeneration)
            """)
        try database.execute(sql: """
            CREATE INDEX IF NOT EXISTS listeningEvents_qualifiedDay ON listeningEvents(qualifiedLocalDay)
            """)
        try database.execute(sql: "CREATE INDEX IF NOT EXISTS listeningEvents_skipDay ON listeningEvents(skipLocalDay)")
        try database.execute(sql: "CREATE INDEX IF NOT EXISTS listeningEvents_snapshot ON listeningEvents(snapshotId)")
        try database.execute(sql: "CREATE INDEX IF NOT EXISTS listeningEventDays_day ON listeningEventDays(localDay)")
        try database.execute(sql: "CREATE INDEX IF NOT EXISTS listeningEventDays_event ON listeningEventDays(eventId)")

        try database.execute(sql: """
        CREATE VIRTUAL TABLE IF NOT EXISTS trackSearch USING fts5(
            searchText,
            content = 'tracks',
            content_rowid = 'id',
            tokenize = 'trigram'
        )
        """)
        try database.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS tracks_search_ai AFTER INSERT ON tracks
        BEGIN
            INSERT INTO trackSearch(rowid, searchText) VALUES (new.id, new.searchText);
        END
        """)
        try database.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS tracks_search_ad AFTER DELETE ON tracks
        BEGIN
            INSERT INTO trackSearch(trackSearch, rowid, searchText)
            VALUES ('delete', old.id, old.searchText);
        END
        """)
        try database.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS tracks_search_au AFTER UPDATE OF searchText ON tracks
        BEGIN
            INSERT INTO trackSearch(trackSearch, rowid, searchText)
            VALUES ('delete', old.id, old.searchText);
            INSERT INTO trackSearch(rowid, searchText) VALUES (new.id, new.searchText);
        END
        """)

        try database.execute(
            sql: "INSERT OR IGNORE INTO textSettings (key, value) VALUES ('replayGainMode', ?)",
            arguments: [ReplayGainMode.defaultValue.rawValue]
        )
        try database.execute(
            sql: """
            INSERT OR IGNORE INTO listeningHistoryState (
                id, generation, trackingStartedAtUTC, isPrivate
            ) VALUES (1, 0, ?, 0)
            """,
            arguments: [LibraryDatabase.databaseTimestamp(Date()) ?? 0]
        )
        try LibraryDatabase.validateSchema(db: database)
        try database.execute(sql: "PRAGMA user_version = \(LibraryDatabase.currentSchemaVersion)")
    }
    static func createSchema(db database: Database) throws {
        try createSchemaImplementation(database)
    }
}
