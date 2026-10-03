import Foundation
import GRDB

private struct CatalogFacetAlbumKey: Hashable, Sendable {
    let title: CatalogFacetTextKey
    let owner: CatalogFacetTextKey

    init(title: String, owner: String) {
        self.title = CatalogFacetTextKey(title)
        self.owner = CatalogFacetTextKey(owner)
    }
}

extension LibraryDatabase {
    static func albumDataCTE(whereClause: String) -> String {
        """
        WITH filtered AS (
            SELECT id, path, title, albumTitle, albumArtist, artistDisplay
            FROM tracks
            WHERE \(whereClause)
        ), albumData AS (
            SELECT f.id, f.path, f.title, f.albumTitle,
                   \(Self.albumOwnerExpression(alias: "f")) AS albumOwner
            FROM filtered f
        )
        """
    }

    static func albumPageOffset(
        db database: Database,
        query: String,
        selectedAlbum: AlbumKey,
        requestedOffset: Int,
        limit: Int
    ) throws -> Int {
        let (whereClause, searchArguments) = Self.searchPredicate(query: query, alias: "tracks", field: .album)
        let albumDataCTE = albumDataCTE(whereClause: whereClause)

        var rankArguments = searchArguments
        rankArguments += [
            selectedAlbum.title, selectedAlbum.title, selectedAlbum.title,
            selectedAlbum.title, selectedAlbum.title, selectedAlbum.owner,
            selectedAlbum.title, selectedAlbum.title, selectedAlbum.owner, selectedAlbum.owner
        ]
        let rank = try Int.fetchOne(
            database,
            sql: albumDataCTE + """
            SELECT COUNT(*)
            FROM (
                SELECT albumTitle, albumOwner
                FROM albumData
                GROUP BY albumTitle, albumOwner
            ) facetKeys
            WHERE albumTitle COLLATE NOCASE < ?
               OR (albumTitle COLLATE NOCASE = ? AND albumTitle < ?)
               OR (albumTitle COLLATE NOCASE = ? AND albumTitle = ?
                   AND albumOwner COLLATE NOCASE < ?)
               OR (albumTitle COLLATE NOCASE = ? AND albumTitle = ?
                   AND albumOwner COLLATE NOCASE = ? AND albumOwner < ?)
            """,
            arguments: rankArguments
        ) ?? 0

        var existsArguments = searchArguments
        existsArguments += [selectedAlbum.title, selectedAlbum.owner]
        let exists = try Int.fetchOne(
            database,
            sql: albumDataCTE + """
            SELECT EXISTS (
                SELECT 1
                FROM (
                    SELECT albumTitle, albumOwner
                    FROM albumData
                    GROUP BY albumTitle, albumOwner
                ) facetKeys
                WHERE facetKeys.albumTitle = ? AND facetKeys.albumOwner = ?
            )
            """,
            arguments: existsArguments
        ) == 1
        return exists ? Self.pageOffset(for: rank, limit: limit) : requestedOffset
    }

    static func fetchAlbumPage(
        db database: Database,
        query: String,
        limit: Int,
        offset: Int
    ) throws -> CatalogFacetPageResult {
        let (whereClause, searchArguments) = Self.searchPredicate(query: query, alias: "tracks", field: .album)
        let albumDataCTE = albumDataCTE(whereClause: whereClause)
        let keySQL = albumDataCTE + """
        SELECT albumTitle, albumOwner
        FROM albumData
        GROUP BY albumTitle, albumOwner
        ORDER BY albumTitle COLLATE NOCASE, albumTitle,
                 albumOwner COLLATE NOCASE, albumOwner
        LIMIT ? OFFSET ?
        """
        var keyArguments = searchArguments
        keyArguments += [limit + 1, offset]
        CatalogFacetQueryTesting.record(
            CatalogFacetQueryEvent(kind: .albums, stage: .pageKeys, sql: keySQL)
        )
        let keyRows = try Row.fetchAll(database, sql: keySQL, arguments: keyArguments)
        var keys: [CatalogFacetAlbumKey] = []
        keys.reserveCapacity(min(keyRows.count, limit))
        for row in keyRows {
            try Self.checkCatalogCancellation()
            if keys.count < limit {
                keys.append(CatalogFacetAlbumKey(title: row["albumTitle"], owner: row["albumOwner"]))
            }
        }
        let hasMore = keyRows.count > limit
        guard !keys.isEmpty else {
            return CatalogFacetPageResult(snapshot: .albums([]), offset: offset, limit: limit, hasMore: false)
        }

        let values = try Self.fetchAlbumSummaries(database: database, query: query, keys: keys)
        return CatalogFacetPageResult(
            snapshot: .albums(keys.compactMap { values[$0] }),
            offset: offset,
            limit: limit,
            hasMore: hasMore
        )
    }
    private static func fetchAlbumSummaries(
        database: Database,
        query: String,
        keys: [CatalogFacetAlbumKey]
    ) throws -> [CatalogFacetAlbumKey: LibraryAlbumSummary] {
        let (whereClause, searchArguments) = Self.searchPredicate(query: query, alias: "tracks", field: .album)
        let albumDataCTE = Self.albumDataCTE(whereClause: whereClause)
        let pageValues = keys.map { _ in "(?, ?)" }.joined(separator: ", ")
        var summaryArguments = searchArguments
        for key in keys {
            summaryArguments += [key.title.value, key.owner.value]
        }
        let summarySQL = albumDataCTE + """
        , pageKeys(albumTitle, albumOwner) AS (
            VALUES \(pageValues)
        )
        SELECT pageKeys.albumTitle, pageKeys.albumOwner, COUNT(*) AS trackCount,
               (
                   SELECT candidate.path
                   FROM albumData candidate
                   WHERE candidate.albumTitle = pageKeys.albumTitle
                     AND candidate.albumOwner = pageKeys.albumOwner
                   ORDER BY candidate.title COLLATE NOCASE, candidate.title, candidate.id
                   LIMIT 1
               ) AS artworkTrackPath
        FROM pageKeys
        JOIN albumData ON albumData.albumTitle = pageKeys.albumTitle
            AND albumData.albumOwner = pageKeys.albumOwner
        GROUP BY pageKeys.albumTitle, pageKeys.albumOwner
        ORDER BY pageKeys.albumTitle COLLATE NOCASE, pageKeys.albumTitle,
                 pageKeys.albumOwner COLLATE NOCASE, pageKeys.albumOwner
        """
        CatalogFacetQueryTesting.record(
            CatalogFacetQueryEvent(kind: .albums, stage: .pageSummaries, sql: summarySQL)
        )
        let rows = try Row.fetchAll(database, sql: summarySQL, arguments: summaryArguments)
        var values: [CatalogFacetAlbumKey: LibraryAlbumSummary] = [:]
        values.reserveCapacity(keys.count)
        for row in rows {
            try Self.checkCatalogCancellation()
            let rawKey = CatalogFacetAlbumKey(title: row["albumTitle"], owner: row["albumOwner"])
            let artworkTrackPath: String? = row["artworkTrackPath"]
            values[rawKey] = LibraryAlbumSummary(
                key: AlbumKey(title: rawKey.title.value, owner: rawKey.owner.value),
                trackCount: row["trackCount"],
                artworkTrackPath: artworkTrackPath ?? ""
            )
        }
        return values
    }
}
