import Foundation
import GRDB

extension LibraryDatabase {
    nonisolated(unsafe) static let requiredColumnMetadata: () -> [String: [String]] = { () in
        func columnMetadata(
            _ name: String,
            type: String,
            notNull: Bool = false,
            defaultValue: String? = nil
        ) -> String {
            [
                name.lowercased(),
                type.uppercased(),
                notNull ? "1" : "0",
                defaultValue?.lowercased().replacingOccurrences(of: " ", with: "") ?? "NULL"
            ].joined(separator: "|")
        }
        return [
            "roots": [
                columnMetadata("id", type: "INTEGER"),
                columnMetadata("path", type: "TEXT", notNull: true),
                columnMetadata("lastScanAt", type: "DATETIME")
            ],
            "tracks": [
                columnMetadata("id", type: "INTEGER"),
                columnMetadata("rootId", type: "INTEGER", notNull: true),
                columnMetadata("path", type: "TEXT", notNull: true),
                columnMetadata("title", type: "TEXT", notNull: true),
                columnMetadata("artistDisplay", type: "TEXT", notNull: true, defaultValue: "''"),
                columnMetadata("albumTitle", type: "TEXT", notNull: true, defaultValue: "''"),
                columnMetadata("albumArtist", type: "TEXT"),
                columnMetadata("genreDisplay", type: "TEXT", notNull: true, defaultValue: "''"),
                columnMetadata("duration", type: "DOUBLE", notNull: true, defaultValue: "0"),
                columnMetadata("format", type: "TEXT", notNull: true, defaultValue: "''"),
                columnMetadata("searchText", type: "TEXT", notNull: true, defaultValue: "''"),
                columnMetadata("mtime", type: "DATETIME"),
                columnMetadata("lyricsKey", type: "TEXT", notNull: true, defaultValue: "''"),
                columnMetadata("fileSize", type: "INTEGER"),
                columnMetadata("lyricsBasename", type: "TEXT", notNull: true, defaultValue: "''"),
                columnMetadata("firstSeenAtUTC", type: "REAL", notNull: true, defaultValue: "0"),
                columnMetadata("fileResourceIdentifier", type: "TEXT"),
                columnMetadata("fileVolumeIdentifier", type: "TEXT"),
                columnMetadata("isFavorite", type: "INTEGER", notNull: true, defaultValue: "0"),
                columnMetadata("titleSearchText", type: "TEXT", notNull: true, defaultValue: "''"),
                columnMetadata("albumSearchText", type: "TEXT", notNull: true, defaultValue: "''")
            ],
            "trackSkipSegments": [
                columnMetadata("id", type: "TEXT"),
                columnMetadata("trackId", type: "INTEGER", notNull: true),
                columnMetadata("startTime", type: "REAL", notNull: true),
                columnMetadata("endTime", type: "REAL", notNull: true)
            ],
            "artistNames": [
                columnMetadata("id", type: "INTEGER"),
                columnMetadata("name", type: "TEXT", notNull: true),
                columnMetadata("searchText", type: "TEXT", notNull: true)
            ],
            "trackArtists": [
                columnMetadata("trackId", type: "INTEGER", notNull: true),
                columnMetadata("artistId", type: "INTEGER", notNull: true)
            ],
            "genreNames": [
                columnMetadata("id", type: "INTEGER"),
                columnMetadata("name", type: "TEXT", notNull: true),
                columnMetadata("searchText", type: "TEXT", notNull: true)
            ],
            "trackGenres": [
                columnMetadata("trackId", type: "INTEGER", notNull: true),
                columnMetadata("genreId", type: "INTEGER", notNull: true)
            ],
            "eqProfiles": [
                columnMetadata("id", type: "INTEGER"),
                columnMetadata("deviceUID", type: "TEXT", notNull: true),
                columnMetadata("preamp", type: "DOUBLE", notNull: true, defaultValue: "0"),
                columnMetadata("isBypassed", type: "BOOLEAN", notNull: true, defaultValue: "1"),
                columnMetadata("bandsJSON", type: "TEXT", notNull: true)
            ],
            "settings": [
                columnMetadata("key", type: "TEXT", notNull: true),
                columnMetadata("value", type: "DOUBLE", notNull: true)
            ],
            "textSettings": [
                columnMetadata("key", type: "TEXT", notNull: true),
                columnMetadata("value", type: "TEXT", notNull: true)
            ],
            "lyricFiles": [
                columnMetadata("id", type: "INTEGER"),
                columnMetadata("rootId", type: "INTEGER", notNull: true),
                columnMetadata("path", type: "TEXT", notNull: true),
                columnMetadata("lyricsKey", type: "TEXT", notNull: true)
            ],
            "replayGainAnalysis": [
                columnMetadata("trackId", type: "INTEGER", notNull: true),
                columnMetadata("trackGainDB", type: "DOUBLE"),
                columnMetadata("trackPeak", type: "DOUBLE"),
                columnMetadata("trackGainSource", type: "TEXT"),
                columnMetadata("albumGainDB", type: "DOUBLE"),
                columnMetadata("albumPeak", type: "DOUBLE"),
                columnMetadata("albumGainSource", type: "TEXT"),
                columnMetadata("albumGeneration", type: "TEXT"),
                columnMetadata("analysisState", type: "TEXT", notNull: true, defaultValue: "'pending'"),
                columnMetadata("claimToken", type: "TEXT"),
                columnMetadata("trackRevision", type: "INTEGER", notNull: true, defaultValue: "0"),
                columnMetadata("errorReason", type: "TEXT"),
                columnMetadata("errorAt", type: "DATETIME"),
                columnMetadata("sourceMtime", type: "DATETIME"),
                columnMetadata("sourceFileSize", type: "INTEGER"),
                columnMetadata(
                    "analyzerVersion",
                    type: "INTEGER",
                    notNull: true,
                    defaultValue: "\(ReplayGain.analyzerVersion)"
                ),
                columnMetadata(
                    "tagSchemaVersion",
                    type: "INTEGER",
                    notNull: true,
                    defaultValue: "\(ReplayGain.tagSchemaVersion)"
                ),
                columnMetadata("sourceContentFingerprint", type: "TEXT")
            ],
            "listeningHistoryState": [
                columnMetadata("id", type: "INTEGER"),
                columnMetadata("generation", type: "INTEGER", notNull: true),
                columnMetadata("trackingStartedAtUTC", type: "REAL", notNull: true),
                columnMetadata("isPrivate", type: "INTEGER", notNull: true, defaultValue: "0")
            ],
            "listeningMediaSnapshots": [
                columnMetadata("id", type: "INTEGER"),
                columnMetadata("liveTrackId", type: "INTEGER"),
                columnMetadata("metadataSignature", type: "TEXT", notNull: true),
                columnMetadata("title", type: "TEXT", notNull: true),
                columnMetadata("artistDisplay", type: "TEXT", notNull: true),
                columnMetadata("albumTitle", type: "TEXT", notNull: true),
                columnMetadata("albumOwner", type: "TEXT", notNull: true),
                columnMetadata("genreDisplay", type: "TEXT", notNull: true),
                columnMetadata("openedDuration", type: "REAL", notNull: true),
                columnMetadata("format", type: "TEXT", notNull: true),
                columnMetadata("createdAtUTC", type: "REAL", notNull: true)
            ],
            "listeningSnapshotArtists": [
                columnMetadata("snapshotId", type: "INTEGER", notNull: true),
                columnMetadata("ordinal", type: "INTEGER", notNull: true),
                columnMetadata("displayValue", type: "TEXT", notNull: true)
            ],
            "listeningSnapshotGenres": [
                columnMetadata("snapshotId", type: "INTEGER", notNull: true),
                columnMetadata("ordinal", type: "INTEGER", notNull: true),
                columnMetadata("displayValue", type: "TEXT", notNull: true)
            ],
            "listeningEvents": [
                columnMetadata("id", type: "TEXT"),
                columnMetadata("historyGeneration", type: "INTEGER", notNull: true),
                columnMetadata("snapshotId", type: "INTEGER", notNull: true),
                columnMetadata("sourceKind", type: "TEXT", notNull: true),
                columnMetadata("sourcePersistentID", type: "INTEGER"),
                columnMetadata("sourceName", type: "TEXT"),
                columnMetadata("startedAtUTC", type: "REAL", notNull: true),
                columnMetadata("startedUTCOffsetSeconds", type: "INTEGER", notNull: true),
                columnMetadata("endedAtUTC", type: "REAL"),
                columnMetadata("endedUTCOffsetSeconds", type: "INTEGER"),
                columnMetadata("startPosition", type: "REAL", notNull: true),
                columnMetadata("endPosition", type: "REAL"),
                columnMetadata("lastDurableCheckpointAtUTC", type: "REAL"),
                columnMetadata("lastDurableCheckpointUTCOffsetSeconds", type: "INTEGER"),
                columnMetadata("lastDurableCheckpointSequence", type: "INTEGER", notNull: true, defaultValue: "-1"),
                columnMetadata("endReason", type: "TEXT"),
                columnMetadata("qualifiedAtUTC", type: "REAL"),
                columnMetadata("qualifiedLocalDay", type: "TEXT"),
                columnMetadata("qualifiedUTCOffsetSeconds", type: "INTEGER"),
                columnMetadata("skipAtUTC", type: "REAL"),
                columnMetadata("skipLocalDay", type: "TEXT"),
                columnMetadata("skipUTCOffsetSeconds", type: "INTEGER")
            ],
            "listeningEventDays": [
                columnMetadata("eventId", type: "TEXT", notNull: true),
                columnMetadata("localDay", type: "TEXT", notNull: true),
                columnMetadata("utcOffsetSeconds", type: "INTEGER", notNull: true),
                columnMetadata("actualListenedSeconds", type: "REAL", notNull: true)
            ],
            "playlists": [
                columnMetadata("id", type: "INTEGER"),
                columnMetadata("name", type: "TEXT", notNull: true),
                columnMetadata("kind", type: "TEXT", notNull: true),
                columnMetadata("createdAtUTC", type: "REAL", notNull: true),
                columnMetadata("rulesJSON", type: "TEXT"),
                columnMetadata("sortField", type: "TEXT"),
                columnMetadata("sortDescending", type: "INTEGER", notNull: true, defaultValue: "0")
            ],
            "playlistItems": [
                columnMetadata("id", type: "INTEGER"),
                columnMetadata("playlistID", type: "INTEGER", notNull: true),
                columnMetadata("ordinal", type: "INTEGER", notNull: true),
                columnMetadata("trackID", type: "INTEGER"),
                columnMetadata("sourceVolumeIdentifier", type: "TEXT"),
                columnMetadata("sourceResourceIdentifier", type: "TEXT"),
                columnMetadata("snapshotPath", type: "TEXT", notNull: true),
                columnMetadata("snapshotTitle", type: "TEXT", notNull: true),
                columnMetadata("snapshotArtistDisplay", type: "TEXT", notNull: true),
                columnMetadata("snapshotAlbumTitle", type: "TEXT", notNull: true),
                columnMetadata("snapshotGenreDisplay", type: "TEXT", notNull: true),
                columnMetadata("snapshotDuration", type: "REAL", notNull: true),
                columnMetadata("snapshotFormat", type: "TEXT", notNull: true)
            ]
        ]
    }
}
