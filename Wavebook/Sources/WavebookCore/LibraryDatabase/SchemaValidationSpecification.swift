import Foundation

struct SchemaRequiredTable {
    let name: String
    let fragments: [String]
}

struct SchemaRequiredForeignKey {
    let source: String
    let table: String
    let target: String
    let onDelete: String

    init(from source: String, table: String, to target: String, onDelete: String) {
        self.source = source
        self.table = table
        self.target = target
        self.onDelete = onDelete
    }
}

struct SchemaRequiredUniqueKey {
    let columns: [String]
    let collation: String
}

struct SchemaRequiredIndex {
    let name: String
    let table: String
    let columns: [String]
    let unique: Bool
    let collation: String
}

private func schemaForeignKey(
    _ source: String,
    _ table: String,
    _ target: String,
    _ onDelete: String
) -> SchemaRequiredForeignKey {
    SchemaRequiredForeignKey(from: source, table: table, to: target, onDelete: onDelete)
}

private func schemaUniqueKey(
    _ columns: [String],
    _ collation: String = "binary"
) -> SchemaRequiredUniqueKey {
    SchemaRequiredUniqueKey(columns: columns, collation: collation)
}

private func schemaIndex(
    _ name: String,
    _ table: String,
    _ columns: [String],
    _ unique: Bool,
    _ collation: String = "binary"
) -> SchemaRequiredIndex {
    SchemaRequiredIndex(name: name, table: table, columns: columns, unique: unique, collation: collation)
}

enum SchemaValidationSpecification {
    static let tables: [SchemaRequiredTable] = [
        SchemaRequiredTable(
            name: "roots",
            fragments: ["primary key", "unique", "on conflict replace"]
        ),
        SchemaRequiredTable(
            name: "tracks",
            fragments: [
                "primary key", "references roots", "on delete cascade", "unique", "on conflict replace",
                "check", "isfavorite in"
            ]
        ),
        SchemaRequiredTable(
            name: "trackSkipSegments",
            fragments: ["primary key", "references tracks", "on delete cascade", "unique"]
        ),
        SchemaRequiredTable(
            name: "artistNames",
            fragments: ["primary key", "unique", "on conflict ignore"]
        ),
        SchemaRequiredTable(
            name: "trackArtists",
            fragments: [
                "primary key", "references tracks", "references artistNames", "on delete cascade", "on conflict replace"
            ]
        ),
        SchemaRequiredTable(
            name: "genreNames",
            fragments: ["primary key", "unique", "on conflict ignore"]
        ),
        SchemaRequiredTable(
            name: "trackGenres",
            fragments: ["primary key", "references genreNames", "on delete cascade", "on conflict replace"]
        ),
        SchemaRequiredTable(
            name: "eqProfiles",
            fragments: ["primary key", "unique", "on conflict replace"]
        ),
        SchemaRequiredTable(
            name: "settings",
            fragments: ["primary key", "on conflict replace"]
        ),
        SchemaRequiredTable(
            name: "textSettings",
            fragments: ["primary key", "on conflict replace"]
        ),
        SchemaRequiredTable(
            name: "lyricFiles",
            fragments: ["primary key", "references roots", "on delete cascade", "unique", "on conflict replace"]
        ),
        SchemaRequiredTable(
            name: "replayGainAnalysis",
            fragments: ["primary key", "references tracks", "on delete cascade"]
        ),
        SchemaRequiredTable(
            name: "listeningHistoryState",
            fragments: ["primary key", "check"]
        ),
        SchemaRequiredTable(
            name: "listeningMediaSnapshots",
            fragments: ["primary key", "references tracks", "on delete set null"]
        ),
        SchemaRequiredTable(
            name: "listeningSnapshotArtists",
            fragments: ["primary key", "references listeningMediaSnapshots", "on delete cascade", "unique"]
        ),
        SchemaRequiredTable(
            name: "listeningSnapshotGenres",
            fragments: ["primary key", "references listeningMediaSnapshots", "on delete cascade", "unique"]
        ),
        SchemaRequiredTable(
            name: "listeningEvents",
            fragments: ["primary key", "references listeningMediaSnapshots", "on delete restrict"]
        ),
        SchemaRequiredTable(
            name: "listeningEventDays",
            fragments: ["primary key", "references listeningEvents", "on delete cascade"]
        ),
        SchemaRequiredTable(
            name: "playlists",
            fragments: [
                "primary key", "check", "kind in", "sortdescending in", "rulesjson is null", "sortfield in"
            ]
        ),
        SchemaRequiredTable(
            name: "playlistItems",
            fragments: [
                "primary key", "references playlists", "references tracks", "on delete cascade", "on delete set null",
                "unique", "check", "ordinal >= 0"
            ]
        )
    ]

    static let tableDefinitions: [String: String] = [
        "listeningHistoryState": """
        CREATE TABLE listeningHistoryState (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            generation INTEGER NOT NULL,
            trackingStartedAtUTC REAL NOT NULL,
            isPrivate INTEGER NOT NULL DEFAULT 0 CHECK (isPrivate IN (0, 1))
        )
        """,
        "tracks": """
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
            lyricsBasename TEXT NOT NULL DEFAULT '',
            firstSeenAtUTC REAL NOT NULL DEFAULT 0,
            fileResourceIdentifier TEXT,
            fileVolumeIdentifier TEXT,
            isFavorite INTEGER NOT NULL DEFAULT 0 CHECK (isFavorite IN (0, 1)),
            titleSearchText TEXT NOT NULL DEFAULT '',
            albumSearchText TEXT NOT NULL DEFAULT ''
        )
        """,
        "playlists": """
        CREATE TABLE playlists (
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
        """,
        "playlistItems": """
        CREATE TABLE playlistItems (
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
        """
    ]

    static let checkCounts = [
        "tracks": 1,
        "listeningHistoryState": 2,
        "trackSkipSegments": 2,
        "playlists": 3,
        "playlistItems": 1
    ]

    static let primaryKeys: [String: [String]] = [
        "roots": ["id"],
        "tracks": ["id"],
        "trackSkipSegments": ["id"],
        "artistNames": ["id"],
        "trackArtists": ["trackId", "artistId"],
        "genreNames": ["id"],
        "trackGenres": ["trackId", "genreId"],
        "eqProfiles": ["id"],
        "settings": ["key"],
        "textSettings": ["key"],
        "lyricFiles": ["id"],
        "replayGainAnalysis": ["trackId"],
        "listeningHistoryState": ["id"],
        "listeningMediaSnapshots": ["id"],
        "listeningSnapshotArtists": ["snapshotId", "ordinal"],
        "listeningSnapshotGenres": ["snapshotId", "ordinal"],
        "listeningEvents": ["id"],
        "listeningEventDays": ["eventId", "localDay", "utcOffsetSeconds"],
        "playlists": ["id"],
        "playlistItems": ["id"]
    ]

    static let uniqueKeys: [String: [SchemaRequiredUniqueKey]] = [
        "roots": [schemaUniqueKey(["path"])],
        "tracks": [schemaUniqueKey(["path"])],
        "trackSkipSegments": [schemaUniqueKey(["trackId", "startTime", "endTime"])],
        "artistNames": [schemaUniqueKey(["name"])],
        "trackArtists": [],
        "genreNames": [schemaUniqueKey(["name"])],
        "trackGenres": [],
        "eqProfiles": [schemaUniqueKey(["deviceUID"])],
        "settings": [],
        "textSettings": [],
        "lyricFiles": [schemaUniqueKey(["rootId", "path"])],
        "replayGainAnalysis": [],
        "listeningHistoryState": [],
        "listeningMediaSnapshots": [schemaUniqueKey(["liveTrackId", "metadataSignature"])],
        "listeningSnapshotArtists": [schemaUniqueKey(["snapshotId", "displayValue"])],
        "listeningSnapshotGenres": [schemaUniqueKey(["snapshotId", "displayValue"])],
        "listeningEvents": [],
        "listeningEventDays": [],
        "playlists": [schemaUniqueKey(["name"], "nocase")],
        "playlistItems": [schemaUniqueKey(["playlistID", "ordinal"])]
    ]

    static let foreignKeys: [String: [SchemaRequiredForeignKey]] = [
        "roots": [],
        "tracks": [schemaForeignKey("rootId", "roots", "id", "cascade")],
        "trackSkipSegments": [schemaForeignKey("trackId", "tracks", "id", "cascade")],
        "artistNames": [],
        "trackArtists": [
            schemaForeignKey("trackId", "tracks", "id", "cascade"),
            schemaForeignKey("artistId", "artistNames", "id", "cascade")
        ],
        "genreNames": [],
        "trackGenres": [
            schemaForeignKey("trackId", "tracks", "id", "cascade"),
            schemaForeignKey("genreId", "genreNames", "id", "cascade")
        ],
        "eqProfiles": [],
        "settings": [],
        "textSettings": [],
        "lyricFiles": [schemaForeignKey("rootId", "roots", "id", "cascade")],
        "replayGainAnalysis": [schemaForeignKey("trackId", "tracks", "id", "cascade")],
        "listeningHistoryState": [],
        "listeningMediaSnapshots": [schemaForeignKey("liveTrackId", "tracks", "id", "set null")],
        "listeningSnapshotArtists": [schemaForeignKey("snapshotId", "listeningMediaSnapshots", "id", "cascade")],
        "listeningSnapshotGenres": [schemaForeignKey("snapshotId", "listeningMediaSnapshots", "id", "cascade")],
        "listeningEvents": [schemaForeignKey("snapshotId", "listeningMediaSnapshots", "id", "restrict")],
        "listeningEventDays": [schemaForeignKey("eventId", "listeningEvents", "id", "cascade")],
        "playlists": [],
        "playlistItems": [
            schemaForeignKey("playlistID", "playlists", "id", "cascade"),
            schemaForeignKey("trackID", "tracks", "id", "set null")
        ]
    ]

    static let indexes: [SchemaRequiredIndex] = [
        schemaIndex("tracks_searchText", "tracks", ["searchText"], false),
        schemaIndex("trackSkipSegments_track", "trackSkipSegments", ["trackId", "startTime"], false),
        schemaIndex("tracks_album", "tracks", ["albumTitle", "albumArtist"], false),
        schemaIndex("tracks_lyricsKey", "tracks", ["lyricsKey"], false),
        schemaIndex("tracks_lyricsBasename", "tracks", ["lyricsBasename"], false),
        schemaIndex("lyricFiles_lyricsKey", "lyricFiles", ["lyricsKey"], false),
        schemaIndex("replayGainAnalysis_state", "replayGainAnalysis", ["analysisState", "trackId"], false),
        schemaIndex("replayGainAnalysis_albumGeneration", "replayGainAnalysis", ["albumGeneration"], false),
        schemaIndex(
            "listeningMediaSnapshots_liveTrack_signature",
            "listeningMediaSnapshots",
            ["liveTrackId", "metadataSignature"],
            true
        ),
        schemaIndex("listeningSnapshotArtists_display", "listeningSnapshotArtists", ["displayValue"], false),
        schemaIndex("listeningSnapshotGenres_display", "listeningSnapshotGenres", ["displayValue"], false),
        schemaIndex("listeningEvents_generation", "listeningEvents", ["historyGeneration"], false),
        schemaIndex("listeningEvents_qualifiedDay", "listeningEvents", ["qualifiedLocalDay"], false),
        schemaIndex("listeningEvents_skipDay", "listeningEvents", ["skipLocalDay"], false),
        schemaIndex("listeningEvents_snapshot", "listeningEvents", ["snapshotId"], false),
        schemaIndex("listeningEventDays_day", "listeningEventDays", ["localDay"], false),
        schemaIndex("listeningEventDays_event", "listeningEventDays", ["eventId"], false),
        schemaIndex("tracks_fileResourceIdentity", "tracks", ["fileVolumeIdentifier", "fileResourceIdentifier"], false),
        schemaIndex("playlists_name", "playlists", ["name"], true, "nocase"),
        schemaIndex("playlistItems_playlist_track", "playlistItems", ["playlistID", "trackID"], false),
        schemaIndex(
            "playlistItems_sourceResourceIdentity",
            "playlistItems",
            ["sourceVolumeIdentifier", "sourceResourceIdentifier"],
            false
        )
    ]

    static let trackSearchDefinition = """
    CREATE VIRTUAL TABLE trackSearch USING fts5(
        searchText,
        content = 'tracks',
        content_rowid = 'id',
        tokenize = 'trigram'
    )
    """

    static let triggers: [(name: String, definition: String)] = [
        ("tracks_search_ai", """
        CREATE TRIGGER tracks_search_ai AFTER INSERT ON tracks
        BEGIN
            INSERT INTO trackSearch(rowid, searchText) VALUES (new.id, new.searchText);
        END
        """),
        ("tracks_search_ad", """
        CREATE TRIGGER tracks_search_ad AFTER DELETE ON tracks
        BEGIN
            INSERT INTO trackSearch(trackSearch, rowid, searchText)
            VALUES ('delete', old.id, old.searchText);
        END
        """),
        ("tracks_search_au", """
        CREATE TRIGGER tracks_search_au AFTER UPDATE OF searchText ON tracks
        BEGIN
            INSERT INTO trackSearch(trackSearch, rowid, searchText)
            VALUES ('delete', old.id, old.searchText);
            INSERT INTO trackSearch(rowid, searchText) VALUES (new.id, new.searchText);
        END
        """)
    ]
}
