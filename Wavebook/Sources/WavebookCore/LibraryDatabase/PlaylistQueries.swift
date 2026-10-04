import Foundation
import GRDB

private struct PlaylistTrackQuery {
    let whereClause: String
    let arguments: StatementArguments
    let join: String
    let orderBy: String
}

private extension PlaylistTrackQuery {
    func matching(searchText: String) -> PlaylistTrackQuery {
        let search = LibraryDatabase.searchPredicate(query: searchText, alias: "tracks")
        guard search.clause != "1 = 1" else { return self }
        return PlaylistTrackQuery(
            whereClause: "(\(whereClause)) AND (\(search.clause))",
            arguments: arguments + search.arguments,
            join: join,
            orderBy: orderBy
        )
    }
}
private struct SystemPlaylistPlan {
    let join: String
    let whereClause: String
    let orderBy: String

    var trackQuery: PlaylistTrackQuery {
        PlaylistTrackQuery(
            whereClause: whereClause,
            arguments: StatementArguments(),
            join: join,
            orderBy: orderBy
        )
    }
}

private extension LibraryDatabase {
    static let smartPlaylistTieBreakSQL = """
        tracks.title COLLATE NOCASE ASC,
        tracks.title ASC,
        tracks.artistDisplay COLLATE NOCASE ASC,
        tracks.artistDisplay ASC,
        tracks.id ASC
        """

    static func playlistSortSQL(
        field: PlaylistSortField,
        descending: Bool
    ) -> String {
        let direction = descending ? "DESC" : "ASC"
        let primary: String
        switch field {
        case .album:
            primary = "tracks.albumTitle COLLATE NOCASE \(direction), tracks.albumTitle \(direction)"
        case .firstSeen:
            primary = "tracks.firstSeenAtUTC \(direction)"
        case .qualifiedPlays:
            primary = "COALESCE(playlistHistory.qualifiedPlayCount, 0) \(direction)"
        case .duration:
            primary = "tracks.duration \(direction)"
        }
        return "\(primary), \(smartPlaylistTieBreakSQL)"
    }

    static func systemPlaylistPlan(_ query: SystemPlaylistQuery) -> SystemPlaylistPlan {
        switch query {
        case .recentlyAdded:
            return SystemPlaylistPlan(
                join: "",
                whereClause: "1 = 1",
                orderBy: "tracks.firstSeenAtUTC DESC, tracks.id ASC"
            )
        case .mostPlayed:
            return SystemPlaylistPlan(
                join: Self.playlistHistoryJoin,
                whereClause: "COALESCE(playlistHistory.qualifiedPlayCount, 0) > 0",
                orderBy: """
                    COALESCE(playlistHistory.qualifiedPlayCount, 0) DESC,
                    COALESCE(playlistHistory.listenedSeconds, 0) DESC,
                    tracks.title COLLATE NOCASE ASC,
                    tracks.title ASC,
                    tracks.artistDisplay COLLATE NOCASE ASC,
                    tracks.artistDisplay ASC,
                    tracks.id ASC
                    """
            )
        case .favorites:
            return SystemPlaylistPlan(
                join: "",
                whereClause: "tracks.isFavorite = 1",
                orderBy: """
                    tracks.title COLLATE NOCASE ASC,
                    tracks.title ASC,
                    tracks.artistDisplay COLLATE NOCASE ASC,
                    tracks.artistDisplay ASC,
                    tracks.id ASC
                    """
            )
        case let .lyrics(lyricsFilter):
            let negation = lyricsFilter == .withLRC ? "" : "NOT "
            return SystemPlaylistPlan(
                join: "",
                whereClause: """
                    \(negation)EXISTS (
                        SELECT 1 FROM lyricFiles
                        WHERE lyricFiles.lyricsKey = tracks.lyricsKey
                    )
                    """,
                orderBy: "tracks.title COLLATE NOCASE ASC, tracks.title ASC, tracks.id ASC"
            )
        }
    }

    static func fetchPlaylistTrackPage(
        _ query: PlaylistTrackQuery,
        limit: Int,
        offset: Int,
        database: Database
    ) throws -> LibraryPlaylistTrackPage {
        let totalCount: Int?
        if offset == 0 {
            totalCount = try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*)
                    FROM tracks
                    \(query.join)
                    WHERE \(query.whereClause)
                    """,
                arguments: query.arguments
            ) ?? 0
        } else {
            totalCount = nil
        }
        var queryArguments = query.arguments
        queryArguments += [limit + 1, offset]
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT \(Self.trackSelection)
                FROM tracks
                \(query.join)
                WHERE \(query.whereClause)
                ORDER BY \(query.orderBy)
                LIMIT ? OFFSET ?
                """,
            arguments: queryArguments
        )
        let hasMore = rows.count > limit
        var tracks: [Track] = []
        tracks.reserveCapacity(min(limit, rows.count))
        for row in rows.prefix(limit) {
            try checkCatalogCancellation()
            tracks.append(Self.track(from: row))
        }
        return LibraryPlaylistTrackPage(
            items: tracks,
            offset: offset,
            limit: limit,
            hasMore: hasMore,
            totalCount: totalCount
        )
    }

    static func fetchPlaylistTracks(
        _ query: PlaylistTrackQuery,
        database: Database
    ) throws -> [Track] {
        let rows = try Row.fetchCursor(
            database,
            sql: """
                SELECT \(Self.trackSelection)
                FROM tracks
                \(query.join)
                WHERE \(query.whereClause)
                ORDER BY \(query.orderBy)
                """,
            arguments: query.arguments
        )
        var tracks: [Track] = []
        while let row = try rows.next() {
            try checkCatalogCancellation()
            tracks.append(Self.track(from: row))
        }
        return tracks
    }
    static func fetchPlaylistQueue(
        _ query: PlaylistTrackQuery,
        source: ListeningPlaybackSource,
        database: Database
    ) throws -> PlaybackQueue {
        let rows = try Row.fetchCursor(
            database,
            sql: """
                SELECT \(Self.trackSelection)
                FROM tracks
                \(query.join)
                WHERE \(query.whereClause)
                ORDER BY \(query.orderBy)
                """,
            arguments: query.arguments
        )
        var queue = PlaybackQueue()
        while let row = try rows.next() {
            try checkCatalogCancellation()
            queue.append(Self.track(from: row), source: source)
            if queue.entries.count == PlaybackQueue.maximumEntryCount { break }
        }
        return queue
    }

    static func smartDefinition(
        playlistID: Int64,
        db database: Database
    ) throws -> PlaylistDefinition {
        guard let row = try Self.fetchPlaylistRow(id: playlistID, db: database) else {
            throw LibraryDatabaseError.missingPlaylist(playlistID)
        }
        let playlist = try playlist(from: row)
        guard case .smart = playlist.definition else {
            throw LibraryDatabaseError.playlistKindMismatch(playlistID)
        }
        return playlist.definition
    }

    static func playlistTrackPageForSmartDefinition(
        rulesJSON: String,
        sortField: PlaylistSortField,
        sortDescending: Bool,
        bounds: (limit: Int, offset: Int),
        searchText: String = "",
        database: Database
    ) throws -> LibraryPlaylistTrackPage {
        let compiled = try compileSmartPlaylistRules(rulesJSON)
        guard bounds.limit > 0 else {
            return LibraryPlaylistTrackPage(items: [], offset: bounds.offset, limit: bounds.limit, hasMore: false)
        }
        PlaylistSQLFunctions.install(in: database)
        let query = PlaylistTrackQuery(
            whereClause: compiled.clause,
            arguments: compiled.arguments,
            join: Self.playlistHistoryJoin,
            orderBy: Self.playlistSortSQL(field: sortField, descending: sortDescending)
        )
        return try fetchPlaylistTrackPage(
            query.matching(searchText: searchText),
            limit: bounds.limit,
            offset: bounds.offset,
            database: database
        )
    }

    static func playlistTracksForSmartDefinition(
        rulesJSON: String,
        sortField: PlaylistSortField,
        sortDescending: Bool,
        searchText: String = "",
        database: Database
    ) throws -> [Track] {
        let compiled = try compileSmartPlaylistRules(rulesJSON)
        PlaylistSQLFunctions.install(in: database)
        let query = PlaylistTrackQuery(
            whereClause: compiled.clause,
            arguments: compiled.arguments,
            join: Self.playlistHistoryJoin,
            orderBy: Self.playlistSortSQL(field: sortField, descending: sortDescending)
        )
        return try fetchPlaylistTracks(
            query.matching(searchText: searchText),
            database: database
        )
    }
}

extension LibraryDatabase {
    /// Reads one page of a validated smart playlist's live catalog results.
    public func smartPlaylistPage(
        playlistID: Int64,
        limit: Int = LibraryDatabase.defaultTrackPageSize,
        offset: Int = 0,
        query: String = ""
    ) throws -> LibraryPlaylistTrackPage {
        let bounds = Self.pageBounds(limit: limit, offset: offset)
        return try readCatalog { database in
            let definition = try Self.smartDefinition(playlistID: playlistID, db: database)
            guard case let .smart(rulesJSON, sortField, sortDescending) = definition else {
                throw LibraryDatabaseError.playlistKindMismatch(playlistID)
            }
            return try Self.playlistTrackPageForSmartDefinition(
                rulesJSON: rulesJSON,
                sortField: sortField,
                sortDescending: sortDescending,
                bounds: bounds,
                searchText: query,
                database: database
            )
        }
    }

    /// Reads one page from a smart definition without requiring a persisted playlist.
    public func smartPlaylistPage(
        rulesJSON: String,
        sortField: PlaylistSortField,
        sortDescending: Bool = false,
        limit: Int = LibraryDatabase.defaultTrackPageSize,
        offset: Int = 0,
        query: String = ""
    ) throws -> LibraryPlaylistTrackPage {
        let bounds = Self.pageBounds(limit: limit, offset: offset)
        return try readCatalog { database in
            return try Self.playlistTrackPageForSmartDefinition(
                rulesJSON: rulesJSON,
                sortField: sortField,
                sortDescending: sortDescending,
                bounds: bounds,
                searchText: query,
                database: database
            )
        }
    }

    /// Reads one page from a system playlist.
    public func systemPlaylistPage(
        for selection: SystemPlaylistQuery,
        limit: Int = LibraryDatabase.defaultTrackPageSize,
        offset: Int = 0,
        query: String = ""
    ) throws -> LibraryPlaylistTrackPage {
        let bounds = Self.pageBounds(limit: limit, offset: offset)
        return try readCatalog { database in
            guard bounds.limit > 0 else {
                return LibraryPlaylistTrackPage(
                    items: [], offset: bounds.offset, limit: bounds.limit, hasMore: false
                )
            }
            let spec = Self.systemPlaylistPlan(selection)
            return try Self.fetchPlaylistTrackPage(
                spec.trackQuery.matching(searchText: query),
                limit: bounds.limit,
                offset: bounds.offset,
                database: database
            )
        }
    }

    /// Reads one page from a system playlist using its default Lyrics filter.
    public func systemPlaylistPage(
        _ kind: SystemPlaylistKind,
        limit: Int = LibraryDatabase.defaultTrackPageSize,
        offset: Int = 0,
        query: String = ""
    ) throws -> LibraryPlaylistTrackPage {
        try systemPlaylistPage(
            for: SystemPlaylistQuery(legacyKind: kind),
            limit: limit,
            offset: offset,
            query: query
        )
    }

    /// Reads a page of recently added live tracks.
    public func recentlyAddedPage(
        limit: Int = LibraryDatabase.defaultTrackPageSize,
        offset: Int = 0
    ) throws -> LibraryPlaylistTrackPage {
        try systemPlaylistPage(for: .recentlyAdded, limit: limit, offset: offset)
    }

    /// Reads a page of most-played live tracks.
    public func mostPlayedPage(
        limit: Int = LibraryDatabase.defaultTrackPageSize,
        offset: Int = 0
    ) throws -> LibraryPlaylistTrackPage {
        try systemPlaylistPage(for: .mostPlayed, limit: limit, offset: offset)
    }

    /// Reads a page of favorite live tracks.
    public func favoriteTracksPage(
        limit: Int = LibraryDatabase.defaultTrackPageSize,
        offset: Int = 0
    ) throws -> LibraryPlaylistTrackPage {
        try systemPlaylistPage(for: .favorites, limit: limit, offset: offset)
    }

    /// Compatibility spelling for favorite paging.
    public func favoritesPage(
        limit: Int = LibraryDatabase.defaultTrackPageSize,
        offset: Int = 0
    ) throws -> LibraryPlaylistTrackPage {
        try favoriteTracksPage(limit: limit, offset: offset)
    }

    /// Resolves a user playlist to its complete current playable track sequence.
    public func resolvePlaylist(
        id playlistID: Int64,
        matching query: String = ""
    ) throws -> [Track] {
        try readCatalog { database in
            guard let row = try Self.fetchPlaylistRow(id: playlistID, db: database) else {
                throw LibraryDatabaseError.missingPlaylist(playlistID)
            }
            let playlist = try Self.playlist(from: row)
            switch playlist.definition {
            case .manual:
                PlaylistSQLFunctions.install(in: database)
                let search = PlaylistSearchPolicy.manualPredicate(query: query)
                let trackQuery = PlaylistTrackQuery(
                    whereClause: "playlistItems.playlistID = ? AND playlistItems.trackID IS NOT NULL AND "
                        + "(\(search.clause))",
                    arguments: StatementArguments([playlistID]) + search.arguments,
                    join: "JOIN playlistItems ON playlistItems.trackID = tracks.id",
                    orderBy: "playlistItems.ordinal ASC, playlistItems.id ASC"
                )
                return try Self.fetchPlaylistTracks(trackQuery, database: database)
            case let .smart(rulesJSON, sortField, sortDescending):
                return try Self.playlistTracksForSmartDefinition(
                    rulesJSON: rulesJSON,
                    sortField: sortField,
                    sortDescending: sortDescending,
                    searchText: query,
                    database: database
                )
            }
        }
    }

    /// Resolves a user playlist directly into the bounded playback queue.
    public func resolvePlaylistQueue(
        id playlistID: Int64,
        matching query: String = "",
        source: ListeningPlaybackSource
    ) throws -> PlaybackQueue {
        try readCatalog { database in
            guard let row = try Self.fetchPlaylistRow(id: playlistID, db: database) else {
                throw LibraryDatabaseError.missingPlaylist(playlistID)
            }
            let playlist = try Self.playlist(from: row)
            switch playlist.definition {
            case .manual:
                PlaylistSQLFunctions.install(in: database)
                let search = PlaylistSearchPolicy.manualPredicate(query: query)
                let trackQuery = PlaylistTrackQuery(
                    whereClause: "playlistItems.playlistID = ? AND playlistItems.trackID IS NOT NULL AND "
                        + "(\(search.clause))",
                    arguments: StatementArguments([playlistID]) + search.arguments,
                    join: "JOIN playlistItems ON playlistItems.trackID = tracks.id",
                    orderBy: "playlistItems.ordinal ASC, playlistItems.id ASC"
                )
                return try Self.fetchPlaylistQueue(trackQuery, source: source, database: database)
            case let .smart(rulesJSON, sortField, sortDescending):
                let compiled = try compileSmartPlaylistRules(rulesJSON)
                PlaylistSQLFunctions.install(in: database)
                let trackQuery = PlaylistTrackQuery(
                    whereClause: compiled.clause,
                    arguments: compiled.arguments,
                    join: Self.playlistHistoryJoin,
                    orderBy: Self.playlistSortSQL(field: sortField, descending: sortDescending)
                )
                return try Self.fetchPlaylistQueue(
                    trackQuery.matching(searchText: query),
                    source: source,
                    database: database
                )
            }
        }
    }

    /// Resolves a system playlist to its complete current playable track sequence.
    public func resolvePlaylist(
        for selection: SystemPlaylistQuery,
        matching queryText: String = ""
    ) throws -> [Track] {
        try readCatalog { database in
            return try Self.fetchPlaylistTracks(
                Self.systemPlaylistPlan(selection).trackQuery.matching(searchText: queryText),
                database: database
            )
        }
    }
    /// Resolves a system playlist using its default Lyrics filter.
    public func resolvePlaylist(
        _ kind: SystemPlaylistKind,
        matching query: String = ""
    ) throws -> [Track] {
        try resolvePlaylist(for: SystemPlaylistQuery(legacyKind: kind), matching: query)
    }

    /// Resolves a system playlist directly into the bounded playback queue.
    public func resolvePlaylistQueue(
        for selection: SystemPlaylistQuery,
        matching queryText: String = "",
        source: ListeningPlaybackSource
    ) throws -> PlaybackQueue {
        try readCatalog { database in
            try Self.fetchPlaylistQueue(
                Self.systemPlaylistPlan(selection).trackQuery.matching(searchText: queryText),
                source: source,
                database: database
            )
        }
    }
    /// Resolves a system playlist queue using its default Lyrics filter.
    public func resolvePlaylistQueue(
        _ kind: SystemPlaylistKind,
        matching query: String = "",
        source: ListeningPlaybackSource
    ) throws -> PlaybackQueue {
        try resolvePlaylistQueue(
            for: SystemPlaylistQuery(legacyKind: kind),
            matching: query,
            source: source
        )
    }

}

private extension SystemPlaylistQuery {
    init(legacyKind kind: SystemPlaylistKind) {
        switch kind {
        case .recentlyAdded: self = .recentlyAdded
        case .mostPlayed: self = .mostPlayed
        case .favorites: self = .favorites
        case .lyrics: self = .lyrics(.withLRC)
        }
    }
}
