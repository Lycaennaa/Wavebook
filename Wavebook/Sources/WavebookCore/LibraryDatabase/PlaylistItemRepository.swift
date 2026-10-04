import Foundation
import GRDB

private struct PlaylistEntryKeys {
    var itemCount: Int
    var trackIDs: Set<Int64>
    var identities: Set<CatalogResourceIdentity>
}

enum PlaylistSearchPolicy {
    static func manualPredicate(
        query: String,
        itemAlias: String = "playlistItems",
        trackAlias: String = "tracks"
    ) -> (clause: String, arguments: StatementArguments) {
        let tokens = SearchNormalizer.tokens(query)
        guard !tokens.isEmpty else { return ("1 = 1", StatementArguments()) }
        var arguments = StatementArguments()
        let predicates = tokens.map { token -> String in
            arguments += [token, token]
            return """
                (
                    wavebook_normalized_contains(
                        COALESCE(\(trackAlias).title, \(itemAlias).snapshotTitle), ?
                    ) = 1
                    OR wavebook_normalized_contains(
                        COALESCE(\(trackAlias).artistDisplay, \(itemAlias).snapshotArtistDisplay), ?
                    ) = 1
                )
                """
        }
        return (predicates.joined(separator: " AND "), arguments)
    }
}

private extension LibraryDatabase {
    static let duplicatePlaylistWarningKey = "playlistDuplicateWarningSuppressed"

    static func requireManualPlaylist(id playlistID: Int64, db database: Database) throws {
        guard let kindRaw = try String.fetchOne(
            database,
            sql: "SELECT kind FROM playlists WHERE id = ?",
            arguments: [playlistID]
        ) else {
            throw LibraryDatabaseError.missingPlaylist(playlistID)
        }
        guard kindRaw == PlaylistKind.manual.rawValue else {
            throw LibraryDatabaseError.playlistKindMismatch(playlistID)
        }
    }

    static func playlistItem(from row: Row) -> PlaylistItem {
        let snapshot = PlaylistItemSnapshot(
            path: row["snapshotPath"],
            title: row["snapshotTitle"],
            artistDisplay: row["snapshotArtistDisplay"],
            albumTitle: row["snapshotAlbumTitle"],
            genreDisplay: row["snapshotGenreDisplay"],
            duration: row["snapshotDuration"],
            format: row["snapshotFormat"]
        )
        let trackID: Int64? = row["id"]
        return PlaylistItem(
            id: row["playlistItemID"],
            playlistID: row["playlistID"],
            ordinal: row["ordinal"],
            sourceVolumeIdentifier: row["sourceVolumeIdentifier"],
            sourceResourceIdentifier: row["sourceResourceIdentifier"],
            track: trackID == nil ? nil : Self.track(from: row),
            snapshot: snapshot
        )
    }

    static func playlistItemSelection() -> String {
        """
            playlistItems.id AS playlistItemID,
            playlistItems.playlistID,
            playlistItems.ordinal,
            playlistItems.sourceVolumeIdentifier,
            playlistItems.sourceResourceIdentifier,
            playlistItems.snapshotPath,
            playlistItems.snapshotTitle,
            playlistItems.snapshotArtistDisplay,
            playlistItems.snapshotAlbumTitle,
            playlistItems.snapshotGenreDisplay,
            playlistItems.snapshotDuration,
            playlistItems.snapshotFormat,
            \(Self.trackSelection)
            """
    }

    static func renumberPlaylistItems(playlistID: Int64, db database: Database) throws {
        let ids = try playlistItemIDs(playlistID: playlistID, db: database)
        try rewritePlaylistOrder(ids, db: database)
    }

    static func rewritePlaylistOrder(_ ids: [Int64], db database: Database) throws {
        guard !ids.isEmpty else { return }
        let maximumOrdinal = try Int64.fetchOne(
            database,
            sql: "SELECT MAX(ordinal) FROM playlistItems",
            arguments: []
        ) ?? -1
        let count = Int64(ids.count)
        guard maximumOrdinal <= Int64.max - count else {
            throw LibraryDatabaseError.invalidPlaylistOrdinal(Int.max)
        }
        let temporaryBase = maximumOrdinal + 1
        for (index, id) in ids.enumerated() {
            try Self.checkCatalogCancellation()
            try database.execute(
                sql: "UPDATE playlistItems SET ordinal = ? WHERE id = ?",
                arguments: [temporaryBase + Int64(index), id]
            )
        }
        for (index, id) in ids.enumerated() {
            try Self.checkCatalogCancellation()
            try database.execute(
                sql: "UPDATE playlistItems SET ordinal = ? WHERE id = ?",
                arguments: [index, id]
            )
        }
    }

    static func playlistItemIDs(
        playlistID: Int64,
        db database: Database
    ) throws -> [Int64] {
        let rows = try Row.fetchCursor(
            database,
            sql: """
                SELECT id FROM playlistItems
                WHERE playlistID = ?
                ORDER BY ordinal ASC, id ASC
                """,
            arguments: [playlistID]
        )
        var ids: [Int64] = []
        while let row = try rows.next() {
            try Self.checkCatalogCancellation()
            ids.append(row["id"])
        }
        return ids
    }
    static func reorderPlaylistItem(
        itemID: Int64,
        playlistID: Int64,
        toOrdinal: Int,
        db database: Database
    ) throws {
        guard toOrdinal >= 0 else { throw LibraryDatabaseError.invalidPlaylistOrdinal(toOrdinal) }
        let ids = try playlistItemIDs(playlistID: playlistID, db: database)
        guard let currentIndex = ids.firstIndex(of: itemID), !ids.isEmpty else {
            throw LibraryDatabaseError.missingPlaylistItem(itemID)
        }
        let targetIndex = min(toOrdinal, ids.count - 1)
        var reordered = ids
        reordered.remove(at: currentIndex)
        reordered.insert(itemID, at: targetIndex)
        try rewritePlaylistOrder(reordered, db: database)
    }
    static func selectedTracks(_ trackIDs: [Int64], db database: Database) throws -> [Track] {
        var tracks: [Track] = []
        tracks.reserveCapacity(trackIDs.count)
        for trackID in trackIDs {
            try Self.checkCatalogCancellation()
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT \(Self.trackSelection) FROM tracks WHERE tracks.id = ?",
                arguments: [trackID]
            ) else {
                throw LibraryDatabaseError.missingTrack(String(trackID))
            }
            tracks.append(Self.track(from: row))
        }
        return tracks
    }

    static func playlistEntryKeys(playlistID: Int64, db database: Database) throws -> PlaylistEntryKeys {
        let rows = try Row.fetchCursor(
            database,
            sql: """
                SELECT trackID, sourceVolumeIdentifier, sourceResourceIdentifier
                FROM playlistItems WHERE playlistID = ?
                """,
            arguments: [playlistID]
        )
        var itemCount = 0
        var trackIDs = Set<Int64>()
        var identities = Set<CatalogResourceIdentity>()
        while let row = try rows.next() {
            try Self.checkCatalogCancellation()
            itemCount += 1
            if let trackID: Int64 = row["trackID"] {
                trackIDs.insert(trackID)
            }
            if let identity = CatalogResourceIdentity(
                volumeIdentifier: row["sourceVolumeIdentifier"],
                resourceIdentifier: row["sourceResourceIdentifier"]
            ) {
                identities.insert(identity)
            }
        }
        return PlaylistEntryKeys(itemCount: itemCount, trackIDs: trackIDs, identities: identities)
    }

    static func insertPlaylistItem(
        track: Track,
        playlistID: Int64,
        ordinal: Int,
        db database: Database
    ) throws -> Int64 {
        guard let trackID = track.id else { throw LibraryDatabaseError.invalidPlaylistItem }
        let safeDuration = track.duration.isFinite && track.duration >= 0 ? track.duration : 0
        try database.execute(
            sql: """
                INSERT INTO playlistItems (
                    playlistID, ordinal, trackID,
                    sourceVolumeIdentifier, sourceResourceIdentifier,
                    snapshotPath, snapshotTitle, snapshotArtistDisplay,
                    snapshotAlbumTitle, snapshotGenreDisplay, snapshotDuration, snapshotFormat
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                playlistID,
                ordinal,
                trackID,
                track.fileVolumeIdentifier,
                track.fileResourceIdentifier,
                track.path,
                track.title,
                track.artistDisplay,
                track.albumTitle,
                track.genreDisplay,
                safeDuration,
                track.format
            ]
        )
        let itemID = database.lastInsertedRowID
        guard itemID > 0 else { throw LibraryDatabaseError.invalidPlaylistItem }
        return itemID
    }

}

extension LibraryDatabase {
    /// Reads a page of ordered items from a manual playlist.
    public func playlistItemPage(
        playlistID: Int64,
        query: String = "",
        limit: Int = LibraryDatabase.defaultTrackPageSize,
        offset: Int = 0
    ) throws -> LibraryPlaylistItemPage {
        let bounds = Self.pageBounds(limit: limit, offset: offset)
        guard bounds.limit > 0 else {
            return LibraryPlaylistItemPage(items: [], offset: bounds.offset, limit: bounds.limit, hasMore: false)
        }
        return try readCatalog { database in
            try Self.requireManualPlaylist(id: playlistID, db: database)
            PlaylistSQLFunctions.install(in: database)
            let search = PlaylistSearchPolicy.manualPredicate(query: query)
            let totalCount: Int?
            if bounds.offset == 0 {
                totalCount = try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*)
                        FROM playlistItems
                        LEFT JOIN tracks ON tracks.id = playlistItems.trackID
                        WHERE playlistItems.playlistID = ? AND (\(search.clause))
                        """,
                    arguments: StatementArguments([playlistID]) + search.arguments
                ) ?? 0
            } else {
                totalCount = nil
            }
            var arguments = search.arguments
            arguments += [bounds.limit + 1, bounds.offset]
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT \(Self.playlistItemSelection())
                    FROM playlistItems
                    LEFT JOIN tracks ON tracks.id = playlistItems.trackID
                    WHERE playlistItems.playlistID = ? AND (\(search.clause))
                    ORDER BY playlistItems.ordinal ASC, playlistItems.id ASC
                    LIMIT ? OFFSET ?
                    """,
                arguments: StatementArguments([playlistID]) + arguments
            )
            let hasMore = rows.count > bounds.limit
            let items = rows.prefix(bounds.limit).map(Self.playlistItem)
            return LibraryPlaylistItemPage(
                items: items,
                offset: bounds.offset,
                limit: bounds.limit,
                hasMore: hasMore,
                totalCount: totalCount
            )
        }
    }

    /// Compatibility spelling for manual-playlist paging.
    public func manualPlaylistItems(
        playlistID: Int64,
        query: String = "",
        limit: Int = LibraryDatabase.defaultTrackPageSize,
        offset: Int = 0
    ) throws -> LibraryPlaylistItemPage {
        try playlistItemPage(playlistID: playlistID, query: query, limit: limit, offset: offset)
    }

    /// Adds selected live tracks in the exact selection order.
    public func addTracks(
        _ trackIDs: [Int64],
        toPlaylistID playlistID: Int64
    ) throws -> PlaylistAddTracksResult {
        try writeCatalog { database in
            try Self.requireManualPlaylist(id: playlistID, db: database)
            let selectedTracks = try Self.selectedTracks(trackIDs, db: database)
            let entryKeys = try Self.playlistEntryKeys(playlistID: playlistID, db: database)
            var existingTrackIDs = entryKeys.trackIDs
            var existingIdentities = entryKeys.identities
            try Self.renumberPlaylistItems(playlistID: playlistID, db: database)

            var nextOrdinal = entryKeys.itemCount
            var itemIDs: [Int64] = []
            itemIDs.reserveCapacity(selectedTracks.count)
            var duplicateTrackIDs: [Int64] = []
            var reportedDuplicates = Set<Int64>()
            for track in selectedTracks {
                try Self.checkCatalogCancellation()
                guard let trackID = track.id else { throw LibraryDatabaseError.invalidPlaylistItem }
                let identity = CatalogResourceIdentity(track: track)
                let identityIsDuplicate = identity.map(existingIdentities.contains) ?? false
                if existingTrackIDs.contains(trackID) || identityIsDuplicate,
                   reportedDuplicates.insert(trackID).inserted {
                    duplicateTrackIDs.append(trackID)
                }
                itemIDs.append(
                    try Self.insertPlaylistItem(
                        track: track,
                        playlistID: playlistID,
                        ordinal: nextOrdinal,
                        db: database
                    )
                )
                nextOrdinal += 1
                existingTrackIDs.insert(trackID)
                if let identity { existingIdentities.insert(identity) }
            }

            let warningSuppressed = try Self.duplicateWarningSuppressed(db: database)
            let shouldWarn = !duplicateTrackIDs.isEmpty && !warningSuppressed
            if shouldWarn {
                try Self.setDuplicateWarningSuppressed(true, db: database)
            }
            return PlaylistAddTracksResult(
                itemIDs: itemIDs,
                duplicateTrackIDs: duplicateTrackIDs,
                shouldWarnAboutDuplicates: shouldWarn
            )
        }
    }

    /// Compatibility spelling for ordered track selection insertion.
    public func addSelectedTracks(
        trackIDs: [Int64],
        toPlaylistID playlistID: Int64
    ) throws -> PlaylistAddTracksResult {
        try addTracks(trackIDs, toPlaylistID: playlistID)
    }

    /// Returns whether the app-wide duplicate-entry warning has been suppressed.
    public func duplicatePlaylistWarningSuppressed() throws -> Bool {
        try readCatalog { database in
            try Self.duplicateWarningSuppressed(db: database)
        }
    }

    /// Persists the app-wide duplicate-entry warning preference.
    public func setDuplicatePlaylistWarningSuppressed(_ suppressed: Bool) throws {
        try writeCatalog { database in
            try Self.setDuplicateWarningSuppressed(suppressed, db: database)
        }
    }

    /// Removes one manual-playlist item and compacts the remaining ordinals.
    public func removePlaylistItem(id itemID: Int64) throws {
        try writeCatalog { database in
            guard let playlistID = try Int64.fetchOne(
                database,
                sql: "SELECT playlistID FROM playlistItems WHERE id = ?",
                arguments: [itemID]
            ) else {
                throw LibraryDatabaseError.missingPlaylistItem(itemID)
            }
            try Self.requireManualPlaylist(id: playlistID, db: database)
            try database.execute(sql: "DELETE FROM playlistItems WHERE id = ?", arguments: [itemID])
            try Self.renumberPlaylistItems(playlistID: playlistID, db: database)
        }
    }
    /// Removes several manual-playlist items in one transaction.
    public func removePlaylistItems(ids itemIDs: [Int64]) throws {
        let uniqueIDs = Array(Set(itemIDs))
        guard !uniqueIDs.isEmpty else { return }
        try writeCatalog { database in
            var playlistID: Int64?
            for itemID in uniqueIDs {
                guard let itemPlaylistID = try Int64.fetchOne(
                    database,
                    sql: "SELECT playlistID FROM playlistItems WHERE id = ?",
                    arguments: [itemID]
                ) else {
                    throw LibraryDatabaseError.missingPlaylistItem(itemID)
                }
                if let playlistID, playlistID != itemPlaylistID {
                    throw LibraryDatabaseError.invalidPlaylistItem
                }
                playlistID = itemPlaylistID
            }
            guard let playlistID else { return }
            try Self.requireManualPlaylist(id: playlistID, db: database)
            for itemID in uniqueIDs {
                try Self.checkCatalogCancellation()
                try database.execute(
                    sql: "DELETE FROM playlistItems WHERE id = ? AND playlistID = ?",
                    arguments: [itemID, playlistID]
                )
            }
            try Self.renumberPlaylistItems(playlistID: playlistID, db: database)
        }
    }

    /// Compatibility spelling for removing an item.
    public func removePlaylistItem(itemID: Int64) throws {
        try removePlaylistItem(id: itemID)
    }

    /// Moves one item to a zero-based ordinal within its manual playlist.
    public func reorderPlaylistItem(id itemID: Int64, toOrdinal: Int) throws {
        try writeCatalog { database in
            guard let playlistID = try Int64.fetchOne(
                database,
                sql: "SELECT playlistID FROM playlistItems WHERE id = ?",
                arguments: [itemID]
            ) else {
                throw LibraryDatabaseError.missingPlaylistItem(itemID)
            }
            try Self.requireManualPlaylist(id: playlistID, db: database)
            try Self.reorderPlaylistItem(
                itemID: itemID,
                playlistID: playlistID,
                toOrdinal: toOrdinal,
                db: database
            )
        }
    }

    /// Compatibility spelling for item reordering.
    public func reorderPlaylistItem(
        playlistID: Int64,
        itemID: Int64,
        toOrdinal: Int
    ) throws {
        try writeCatalog { database in
            try Self.requireManualPlaylist(id: playlistID, db: database)
            guard try Int64.fetchOne(
                database,
                sql: "SELECT playlistID FROM playlistItems WHERE id = ? AND playlistID = ?",
                arguments: [itemID, playlistID]
            ) != nil else {
                throw LibraryDatabaseError.missingPlaylistItem(itemID)
            }
            try Self.reorderPlaylistItem(
                itemID: itemID,
                playlistID: playlistID,
                toOrdinal: toOrdinal,
                db: database
            )
        }
    }

    /// Removes all unavailable items and returns the number removed.
    @discardableResult
    public func clearUnavailablePlaylistItems(playlistID: Int64) throws -> Int {
        try writeCatalog { database in
            try Self.requireManualPlaylist(id: playlistID, db: database)
            try database.execute(
                sql: "DELETE FROM playlistItems WHERE playlistID = ? AND trackID IS NULL",
                arguments: [playlistID]
            )
            let removed = database.changesCount
            try Self.renumberPlaylistItems(playlistID: playlistID, db: database)
            return removed
        }
    }

    private static func duplicateWarningSuppressed(db database: Database) throws -> Bool {
        try String.fetchOne(
            database,
            sql: "SELECT value FROM textSettings WHERE key = ?",
            arguments: [duplicatePlaylistWarningKey]
        ) == "1"
    }

    private static func setDuplicateWarningSuppressed(_ suppressed: Bool, db database: Database) throws {
        try database.execute(
            sql: """
                INSERT INTO textSettings (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
            arguments: [duplicatePlaylistWarningKey, suppressed ? "1" : "0"]
        )
    }
}
