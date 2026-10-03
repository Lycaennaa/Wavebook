import Foundation
import GRDB

private struct ArtistDetailQuery {
    let whereClause: String
    let searchArguments: StatementArguments
    let normalizedArtist: String
    let artistIsUnknown: Bool
    let artistConditionForFiltered: String
    let artistConditionForTracks: String

    init(artist: String, query: String) {
        let (whereClause, searchArguments) = LibraryDatabase.searchPredicate(query: query, alias: "tracks")
        let normalizedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let artistIsUnknown = normalizedArtist.isEmpty
        let artistConditionForFiltered = artistIsUnknown
            ? "NOT EXISTS (SELECT 1 FROM trackArtists WHERE trackArtists.trackId = f.id)"
            : "EXISTS (SELECT 1 FROM trackArtists JOIN artistNames ON artistNames.id = trackArtists.artistId " +
                "WHERE trackArtists.trackId = f.id AND artistNames.name = ?)"
        self.whereClause = whereClause
        self.searchArguments = searchArguments
        self.normalizedArtist = normalizedArtist
        self.artistIsUnknown = artistIsUnknown
        self.artistConditionForFiltered = artistConditionForFiltered
        self.artistConditionForTracks = artistConditionForFiltered.replacingOccurrences(
            of: "f.id",
            with: "tracks.id"
        )
    }
}

/// Paging values for artist detail tracks.
public struct LibraryTrackPageRequest: Sendable {
    /// Maximum number of tracks requested.
    public let limit: Int
    /// Zero-based offset of the first track.
    public let offset: Int

    /// Creates track-page paging values.
    public init(limit: Int = LibraryDatabase.defaultTrackPageSize, offset: Int = 0) {
        self.limit = limit
        self.offset = offset
    }
}

extension LibraryDatabase {
    /// Returns a page of artist details and tracks.
    public func artistDetailPage(
        artist: String,
        matching query: String = "",
        detailLimit: Int = LibraryDatabase.defaultTrackPageSize,
        detailOffset: Int = 0,
        trackPage: LibraryTrackPageRequest = .init()
    ) throws -> LibraryArtistDetailPage {
        try Task.checkCancellation()
        let bounds = Self.pageBounds(limit: detailLimit, offset: detailOffset)
        let metadata = try artistDetailMetadataPage(
            artist: artist,
            matching: query,
            limit: bounds.limit,
            offset: bounds.offset
        )
        let tracks = try self.trackPage(
            for: .artist(artist),
            matching: query,
            limit: trackPage.limit,
            offset: trackPage.offset
        )
        return LibraryArtistDetailPage(
            detail: metadata.detail,
            tracks: tracks,
            detailOffset: bounds.offset,
            detailLimit: bounds.limit,
            hasMoreDetail: metadata.hasMore
        )
    }

    /// Returns all artist detail albums and genres.
    @available(*, unavailable, message: "Use artistDetailPage for bounded catalog consumption.")
    public func artistDetail(artist: String, matching query: String = "") throws -> LibraryArtistDetail {
        var offset = 0
        var owned: [LibraryArtistAlbumSummary] = []
        var appearing: [LibraryArtistAlbumSummary] = []
        var genres: [String] = []
        while true {
            try Task.checkCancellation()
            let page = try artistDetailMetadataPage(
                artist: artist,
                matching: query,
                limit: LibraryDatabase.maximumTrackPageSize,
                offset: offset
            )
            owned.append(contentsOf: page.detail.ownedAlbums)
            appearing.append(contentsOf: page.detail.appearingAlbums)
            genres.append(contentsOf: page.detail.genres)
            guard page.hasMore else { break }
            offset += LibraryDatabase.maximumTrackPageSize
        }
        return LibraryArtistDetail(ownedAlbums: owned, appearingAlbums: appearing, genres: genres)
    }

    private func artistDetailMetadataPage(
        artist: String,
        matching query: String,
        limit: Int,
        offset: Int
    ) throws -> (detail: LibraryArtistDetail, hasMore: Bool) {
        let bounds = Self.pageBounds(limit: limit, offset: offset)
        guard bounds.limit > 0 else {
            return (
                LibraryArtistDetail(ownedAlbums: [], appearingAlbums: [], genres: []),
                false
            )
        }
        let queryContext = ArtistDetailQuery(artist: artist, query: query)
        return try readCatalog { database in
            try Self.fetchArtistDetailMetadata(
                database: database,
                query: queryContext,
                limit: bounds.limit,
                offset: bounds.offset
            )
        }
    }

    private static func fetchArtistDetailMetadata(
        database: Database,
        query: ArtistDetailQuery,
        limit: Int,
        offset: Int
    ) throws -> (detail: LibraryArtistDetail, hasMore: Bool) {
        let artistTrackCount = try artistTrackCount(database: database, query: query)
        let genrePage = try artistDetailGenres(
            database: database,
            query: query,
            limit: limit,
            offset: offset
        )
        guard artistTrackCount > 1 else {
            return (
                LibraryArtistDetail(ownedAlbums: [], appearingAlbums: [], genres: genrePage.genres),
                genrePage.hasMore
            )
        }

        let albumRows = try artistDetailAlbumRows(
            database: database,
            query: query,
            limit: limit,
            offset: offset
        )
        var owned: [LibraryArtistAlbumSummary] = []
        var appearing: [LibraryArtistAlbumSummary] = []
        try Task.checkCancellation()
        for row in albumRows.prefix(limit) {
            let key = AlbumKey(title: row["albumTitle"], owner: row["albumOwner"])
            let artistTrackCount: Int = row["artistTrackCount"]
            let trackCount: Int = row["trackCount"]
            let ownerNames = Self.splitNames(key.owner)
            let isOwned: Bool
            if query.artistIsUnknown {
                isOwned = ownerNames.isEmpty
            } else if !ownerNames.isEmpty {
                isOwned = ownerNames.contains {
                    $0.localizedCaseInsensitiveCompare(query.normalizedArtist) == .orderedSame
                }
            } else {
                isOwned = artistTrackCount == trackCount
            }
            let summary = LibraryArtistAlbumSummary(
                key: key,
                trackCount: trackCount,
                artworkTrackPath: row["artworkTrackPath"] ?? ""
            )
            if isOwned {
                owned.append(summary)
            } else {
                appearing.append(summary)
            }
        }
        owned.sort(by: Self.sortArtistAlbumSummaries)
        appearing.sort(by: Self.sortArtistAlbumSummaries)
        return (
            LibraryArtistDetail(ownedAlbums: owned, appearingAlbums: appearing, genres: genrePage.genres),
            genrePage.hasMore || albumRows.count > limit
        )
    }

    private static func artistTrackCount(database: Database, query: ArtistDetailQuery) throws -> Int {
        var arguments = query.searchArguments
        if !query.artistIsUnknown { arguments += [query.normalizedArtist] }
        return try Int.fetchOne(
            database,
            sql: "SELECT COUNT(*) FROM tracks WHERE \(query.whereClause) AND \(query.artistConditionForTracks)",
            arguments: arguments
        ) ?? 0
    }

    private static func artistDetailGenres(
        database: Database,
        query: ArtistDetailQuery,
        limit: Int,
        offset: Int
    ) throws -> (genres: [String], hasMore: Bool) {
        var arguments = query.searchArguments
        if !query.artistIsUnknown { arguments += [query.normalizedArtist] }
        arguments += [limit + 1, offset]
        let rows = try Row.fetchAll(
            database,
            sql: """
            WITH filtered AS (
                SELECT id
                FROM tracks
                WHERE \(query.whereClause)
            )
            SELECT DISTINCT genreNames.name
            FROM filtered f
            JOIN trackGenres ON trackGenres.trackId = f.id
            JOIN genreNames ON genreNames.id = trackGenres.genreId
            WHERE \(query.artistConditionForFiltered)
            ORDER BY genreNames.name COLLATE NOCASE, genreNames.name
            LIMIT ? OFFSET ?
            """,
            arguments: arguments
        )
        let genres = rows.prefix(limit).map { (row: Row) -> String in row["name"] }
        return (genres, rows.count > limit)
    }

    private static func artistDetailAlbumRows(
        database: Database,
        query: ArtistDetailQuery,
        limit: Int,
        offset: Int
    ) throws -> [Row] {
        var arguments = query.searchArguments
        if !query.artistIsUnknown { arguments += [query.normalizedArtist] }
        arguments += [limit + 1, offset]
        return try Row.fetchAll(
            database,
            sql: """
            WITH filtered AS (
                SELECT id, path, title, albumTitle, albumArtist, artistDisplay
                FROM tracks
                WHERE \(query.whereClause)
            ), albumData AS (
                SELECT f.id, f.path, f.title, f.albumTitle,
                       \(Self.albumOwnerExpression(alias: "f")) AS albumOwner
                FROM filtered f
            ), allAlbumData AS (
                SELECT tracks.id, tracks.path, tracks.title, tracks.albumTitle,
                       \(Self.albumOwnerExpression(alias: "tracks")) AS albumOwner
                FROM tracks
            ), albumTotals AS (
                SELECT albumTitle, albumOwner, COUNT(*) AS trackCount
                FROM allAlbumData
                GROUP BY albumTitle, albumOwner
            ), artistAlbums AS (
                SELECT ad.albumTitle, ad.albumOwner, COUNT(*) AS artistTrackCount
                FROM albumData ad
                WHERE \(query.artistConditionForFiltered.replacingOccurrences(of: "f.id", with: "ad.id"))
                GROUP BY ad.albumTitle, ad.albumOwner
            )
            SELECT aa.albumTitle, aa.albumOwner, totals.trackCount,
                   aa.artistTrackCount,
                   (
                       SELECT candidate.path
                       FROM allAlbumData candidate
                       WHERE candidate.albumTitle = aa.albumTitle
                         AND candidate.albumOwner = aa.albumOwner
                       ORDER BY candidate.title COLLATE NOCASE, candidate.title, candidate.id
                       LIMIT 1
                   ) AS artworkTrackPath
            FROM artistAlbums aa
            JOIN albumTotals totals ON totals.albumTitle = aa.albumTitle
                AND totals.albumOwner = aa.albumOwner
            WHERE totals.trackCount > 1
            ORDER BY aa.albumTitle COLLATE NOCASE, aa.albumTitle,
                     aa.albumOwner COLLATE NOCASE, aa.albumOwner
            LIMIT ? OFFSET ?
            """,
            arguments: arguments
        )
    }
    static func album(_ key: AlbumKey, isOwnedBy artist: String, tracks: [Track]) -> Bool {
        let ownerNames = splitNames(key.owner)
        guard !artist.isEmpty else { return ownerNames.isEmpty }
        guard ownerNames.isEmpty else {
            return ownerNames.contains {
                $0.localizedCaseInsensitiveCompare(artist) == .orderedSame
            }
        }
        return !tracks.isEmpty && tracks.allSatisfy { track in
            track.artists.contains { $0.localizedCaseInsensitiveCompare(artist) == .orderedSame }
        }
    }
}
