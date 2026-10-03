import Foundation
import GRDB
extension LibraryDatabase {
    private struct PreparedTrackForSave {
        let track: Track
        let searchText: String
        let titleSearchText: String
        let albumSearchText: String
        let previousAlbumKey: AlbumKey?
        let fingerprint: ReplayGainFileFingerprint
    }
    /// Persists a track under a library root.
    public func save(track: Track, rootID: Int64) throws -> Int64 {
        guard let rootPath = try writer.read({ database in
            try Self.rootPath(forID: rootID, db: database)
        }) else {
            throw LibraryDatabaseError.missingRoot(String(rootID))
        }
        let canonicalPath = try Self.canonicalPath(track.path, underRoot: rootPath)
        let fingerprint = Self.fileFingerprint(path: canonicalPath)
        try Self.checkCatalogCancellation()
        let trackID = try writer.write { database in
            guard let currentRootPath = try Self.rootPath(forID: rootID, db: database) else {
                throw LibraryDatabaseError.missingRoot(String(rootID))
            }
            let previousAlbumKey = try Self.removeIdentityMismatch(
                track: track,
                rootPath: currentRootPath,
                database: database
            )
            let trackID = try Self.save(
                track: track,
                rootID: rootID,
                fingerprint: fingerprint,
                database: database
            )
            if let previousAlbumKey {
                try Self.invalidateAlbumValues(for: [previousAlbumKey], db: database)
            }
            try Self.reattachOrphanedPlaylistItems(db: database)
            return trackID
        }
        try invalidateChangedReplayGainFiles(
            expected: [canonicalPath: fingerprint],
            ignoringCancellation: true
        )
        try Self.checkCatalogCancellation()
        return trackID
    }
    private static func removeIdentityMismatch(
        track: Track,
        rootPath: String,
        database: Database
    ) throws -> AlbumKey? {
        let path = try Self.canonicalPath(track.path, underRoot: rootPath)
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT id, albumTitle, albumArtist, artistDisplay,
                       fileVolumeIdentifier, fileResourceIdentifier
                FROM tracks
                WHERE path = ?
                """,
            arguments: [path]
        ) else {
            if let trackID = track.id {
                throw LibraryDatabaseError.staleTrackID(trackID)
            }
            return nil
        }
        if let expectedTrackID = track.id {
            let storedTrackID: Int64 = row["id"]
            guard storedTrackID == expectedTrackID else {
                throw LibraryDatabaseError.staleTrackID(expectedTrackID)
            }
        }
        guard let storedIdentity = CatalogResourceIdentity(row: row),
              let incomingIdentity = CatalogResourceIdentity(track: track),
              storedIdentity != incomingIdentity else { return nil }
        guard track.id != nil else {
            throw LibraryDatabaseError.conflictingTrackIdentity(path)
        }

        let albumKey = Self.albumKey(from: row)
        let trackID: Int64 = row["id"]
        try Self.deleteTrackPreservingPlaylistIdentity(trackID: trackID, db: database)
        return albumKey
    }
    /// Returns paths of tracks stored under a library root.
    public func existingTrackPaths(rootPath: String) throws -> Set<String> {
        try writer.read { database in
            guard let rootID = try Self.rootID(matching: rootPath, db: database) else {
                return []
            }
            return Set(
                try String.fetchAll(
                    database,
                    sql: "SELECT path FROM tracks WHERE rootId = ?",
                    arguments: [rootID]
                )
            )
        }
    }

    /// Removes tracks whose paths are absent from a supplied set.
    public func pruneMissingTracks(rootPath: String, existingPaths: Set<String>) throws -> Int {
        let resolvedRootPath = try Self.resolveRootPath(rootPath)
        guard FileManager.default.fileExists(atPath: resolvedRootPath) else { return 0 }

        return try writer.write { database in
            guard let rootID = try Self.rootID(matching: resolvedRootPath, db: database),
                  let storedRootPath = try Self.rootPath(forID: rootID, db: database) else { return 0 }
            let canonicalExistingPaths = try Set(existingPaths.map {
                try Self.canonicalPath($0, underRoot: storedRootPath)
            })
            let rows = try Row.fetchCursor(
                database,
                sql: "SELECT id, path, albumTitle, albumArtist, artistDisplay FROM tracks WHERE rootId = ?",
                arguments: [rootID]
            )
            var removed = 0
            var removedAlbumKeys = Set<AlbumKey>()

            while let row = try rows.next() {
                try Self.checkCatalogCancellation()
                let path: String = row["path"]
                let canonicalPath = try Self.canonicalPath(path, underRoot: storedRootPath)
                if !canonicalExistingPaths.contains(canonicalPath) {
                    if let albumKey = Self.albumKey(from: row) {
                        removedAlbumKeys.insert(albumKey)
                    }
                    let id: Int64 = row["id"]
                    try Self.deleteTrackPreservingPlaylistIdentity(trackID: id, db: database)
                    removed += 1
                }
            }
            try Self.reattachOrphanedPlaylistItems(db: database)

            try Self.invalidateAlbumValues(for: removedAlbumKeys, db: database)
            try Self.deleteOrphanNames(database: database)
            return removed
        }
    }

    static func save(
        track: Track,
        rootID: Int64,
        fingerprint: ReplayGainFileFingerprint,
        database: Database
    ) throws -> Int64 {
        let result = try saveAndCollectAlbumChanges(
            track: track,
            rootID: rootID,
            fingerprint: fingerprint,
            database: database
        )
        try invalidateAlbumValues(for: result.albumKeys, db: database)
        return result.trackID
    }

    static func saveAndCollectAlbumChanges(
        track: Track,
        rootID: Int64,
        fingerprint: ReplayGainFileFingerprint,
        database: Database
    ) throws -> (trackID: Int64, albumKeys: Set<AlbumKey>) {
        guard let rootPath = try Self.rootPath(forID: rootID, db: database) else {
            throw LibraryDatabaseError.missingRoot(String(rootID))
        }
        let prepared = try preparedTrackForSave(
            track: track,
            rootPath: rootPath,
            fingerprint: fingerprint,
            database: database
        )
        let trackID = try saveTrackRow(prepared: prepared, rootID: rootID, database: database)
        let replayGainWasInvalidated = try invalidateTrackReplayGain(
            trackID: trackID,
            fingerprint: prepared.fingerprint,
            database: database
        )
        try saveTrackNames(track: prepared.track, trackID: trackID, database: database)
        let currentAlbumKey = validAlbumKey(prepared.track.albumKey)
        var changedAlbumKeys = Set<AlbumKey>()
        if prepared.previousAlbumKey != currentAlbumKey {
            changedAlbumKeys.formUnion([prepared.previousAlbumKey, currentAlbumKey].compactMap(\.self))
        }
        if replayGainWasInvalidated, let currentAlbumKey {
            changedAlbumKeys.insert(currentAlbumKey)
        }
        return (trackID: trackID, albumKeys: changedAlbumKeys)
    }

    private static func preparedTrackForSave(
        track: Track,
        rootPath: String,
        fingerprint: ReplayGainFileFingerprint,
        database: Database
    ) throws -> PreparedTrackForSave {
        var track = track
        track.path = try Self.canonicalPath(track.path, underRoot: rootPath)
        track.fileVolumeIdentifier = CatalogResourceIdentity.canonicalComponent(track.fileVolumeIdentifier)
        track.fileResourceIdentifier = CatalogResourceIdentity.canonicalComponent(track.fileResourceIdentifier)
        track.albumTitle = AlbumKey.canonicalComponent(track.albumTitle)
        let titleSearchText = SearchNormalizer.normalizedText(track.title)
        let albumSearchText = SearchNormalizer.normalizedText(track.albumTitle)
        let searchText = SearchNormalizer.trackSearchText(
            TrackSearchFields(
                title: track.title,
                artistDisplay: track.artistDisplay,
                albumTitle: track.albumTitle,
                albumArtist: track.albumArtist,
                genreDisplay: track.genreDisplay,
                path: track.path
            )
        )
        let existingRow = try Row.fetchOne(
            database,
            sql: "SELECT id, albumTitle, albumArtist, artistDisplay FROM tracks WHERE path = ?",
            arguments: [track.path]
        )
        return PreparedTrackForSave(
            track: track,
            searchText: searchText,
            titleSearchText: titleSearchText,
            albumSearchText: albumSearchText,
            previousAlbumKey: existingRow.flatMap(albumKey),
            fingerprint: fingerprint
        )
    }

    // Conflict updates scanner-owned metadata; reconciliation owns persistent identity and favorite state.
    private static let trackInsertSQL = """
        INSERT INTO tracks (
            rootId, path, title, artistDisplay, albumTitle, albumArtist, genreDisplay,
            duration, format, searchText, titleSearchText, albumSearchText, mtime, fileSize,
            lyricsKey, lyricsBasename, firstSeenAtUTC, fileResourceIdentifier,
            fileVolumeIdentifier, isFavorite
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
            rootId = excluded.rootId,
            title = excluded.title,
            artistDisplay = excluded.artistDisplay,
            albumTitle = excluded.albumTitle,
            albumArtist = excluded.albumArtist,
            genreDisplay = excluded.genreDisplay,
            duration = excluded.duration,
            format = excluded.format,
            searchText = excluded.searchText,
            titleSearchText = excluded.titleSearchText,
            albumSearchText = excluded.albumSearchText,
            mtime = excluded.mtime,
            fileSize = excluded.fileSize,
            lyricsKey = excluded.lyricsKey,
            lyricsBasename = excluded.lyricsBasename
        """
    private static func saveTrackRow(
        prepared: PreparedTrackForSave,
        rootID: Int64,
        database: Database
    ) throws -> Int64 {
        let track = prepared.track
        let lyricsBasename = URL(fileURLWithPath: track.path)
            .deletingPathExtension()
            .lastPathComponent
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        try database.execute(
            sql: trackInsertSQL,
            arguments: [
                rootID,
                track.path,
                track.title,
                track.artistDisplay,
                track.albumTitle,
                track.albumArtist,
                track.genreDisplay,
                track.duration,
                track.format,
                prepared.searchText,
                prepared.titleSearchText,
                prepared.albumSearchText,
                databaseTimestamp(prepared.fingerprint.modificationDate),
                prepared.fingerprint.fileSize,
                track.path,
                lyricsBasename,
                databaseTimestamp(Track.normalizedFirstSeenAtUTC(track.firstSeenAtUTC)) ?? 0,
                track.fileResourceIdentifier,
                track.fileVolumeIdentifier,
                track.isFavorite
            ]
        )
        guard let trackID = try Int64.fetchOne(
            database,
            sql: "SELECT id FROM tracks WHERE path = ?",
            arguments: [track.path]
        ) else {
            throw LibraryDatabaseError.missingTrack(track.path)
        }
        return trackID
    }

    private static func saveTrackNames(
        track: Track,
        trackID: Int64,
        database: Database
    ) throws {
        try database.execute(sql: "DELETE FROM trackArtists WHERE trackId = ?", arguments: [trackID])
        try database.execute(sql: "DELETE FROM trackGenres WHERE trackId = ?", arguments: [trackID])
        for artist in track.artists {
            try Self.checkCatalogCancellation()
            let artistID = try upsertName(artist, table: "artistNames", database: database)
            try database.execute(
                sql: "INSERT OR REPLACE INTO trackArtists (trackId, artistId) VALUES (?, ?)",
                arguments: [trackID, artistID]
            )
        }
        for genre in track.genres {
            try Self.checkCatalogCancellation()
            let genreID = try upsertName(genre, table: "genreNames", database: database)
            try database.execute(
                sql: "INSERT OR REPLACE INTO trackGenres (trackId, genreId) VALUES (?, ?)",
                arguments: [trackID, genreID]
            )
        }
    }
    static func albumKey(from row: Row) -> AlbumKey? {
        let title: String = row["albumTitle"]
        let albumArtist: String? = row["albumArtist"]
        let artistDisplay: String = row["artistDisplay"]
        let trimmedAlbumArtist = albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let owner = trimmedAlbumArtist.isEmpty
            ? MetadataParser.splitList(artistDisplay).first ?? ""
            : trimmedAlbumArtist
        return validAlbumKey(AlbumKey(title: title, owner: owner))
    }

    static func replayGainAlbumFailureReason(_ albumReason: String, preserving existingReason: String?) -> String {
        let trackReason: String?
        if let existingReason, existingReason.hasPrefix(replayGainAlbumFailureMarker) {
            trackReason = existingReason.split(separator: "\n", maxSplits: 1).dropFirst().first.map(String.init)
        } else {
            trackReason = existingReason
        }
        let trackSuffix = trackReason.map {
            "\n" + String($0.prefix(500 - replayGainAlbumFailureMarker.count - 1))
        } ?? ""
        let albumReasonLimit = 500 - replayGainAlbumFailureMarker.count - trackSuffix.count
        return replayGainAlbumFailureMarker + String(albumReason.prefix(albumReasonLimit)) + trackSuffix
    }

    static func validAlbumKey(_ albumKey: AlbumKey) -> AlbumKey? {
        albumKey.title.isEmpty || albumKey.owner.isEmpty ? nil : albumKey
    }

    static func deleteOrphanNames(database: Database) throws {
        try database.execute(sql: "DELETE FROM artistNames WHERE id NOT IN (SELECT artistId FROM trackArtists)")
        try database.execute(sql: "DELETE FROM genreNames WHERE id NOT IN (SELECT genreId FROM trackGenres)")
    }

    static func upsertName(_ name: String, table: String, database: Database) throws -> Int64 {
        try database.execute(
            sql: "INSERT OR IGNORE INTO \(table) (name, searchText) VALUES (?, ?)",
            arguments: [name, SearchNormalizer.normalizedText(name)]
        )
        guard let id = try Int64.fetchOne(
            database,
            sql: "SELECT id FROM \(table) WHERE name = ?",
            arguments: [name]
        ) else {
            throw LibraryDatabaseError.missingTrack(name)
        }
        return id
    }

}
