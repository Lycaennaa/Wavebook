import Foundation
import GRDB

private struct CatalogArtistAggregate {
    var trackCount = 0
    var albumCount = 0
    var appearanceCount = 0
}

extension LibraryDatabase {

    static func artistPageOffset(
        db database: Database,
        query: String,
        selectedArtist: String,
        requestedOffset: Int,
        limit: Int
    ) throws -> Int {
        try Self.nameFacetPageOffset(
            db: database,
            query: query,
            selectedName: selectedArtist,
            page: (requestedOffset: requestedOffset, limit: limit),
            definition: .artists
        )
    }
    static func fetchArtistPage(
        db database: Database,
        query: String,
        limit: Int,
        offset: Int
    ) throws -> CatalogFacetPageResult {
        let pageKeys = try Self.fetchNameFacetPageKeys(
            db: database,
            query: query,
            limit: limit,
            offset: offset,
            definition: .artists
        )
        let names = pageKeys.names
        guard !names.isEmpty else {
            return CatalogFacetPageResult(snapshot: .artists([]), offset: offset, limit: limit, hasMore: false)
        }

        let values = try Self.fetchArtistSummaries(database: database, query: query, names: names)
        let items = names.compactMap { name -> LibraryNameSummary? in
            guard let value = values[CatalogFacetTextKey(name)] else { return nil }
            return LibraryNameSummary(
                name: name,
                trackCount: value.trackCount,
                albumCount: value.albumCount,
                appearanceCount: value.appearanceCount
            )
        }
        return CatalogFacetPageResult(
            snapshot: .artists(items),
            offset: offset,
            limit: limit,
            hasMore: pageKeys.hasMore
        )
    }

    private static func artistPageSummarySQL(whereClause: String, pageValues: String) -> String {
        """
        WITH filtered AS (
            SELECT id, albumTitle, albumArtist, artistDisplay
            FROM tracks
            WHERE \(whereClause)
        ), albumData AS (
            SELECT f.id, f.albumTitle,
                   \(Self.albumOwnerExpression(alias: "f")) AS albumOwner
            FROM filtered f
        ), allAlbumData AS (
            SELECT tracks.id, tracks.albumTitle,
                   \(Self.albumOwnerExpression(alias: "tracks")) AS albumOwner
            FROM tracks
        ), artistTracks AS (
            SELECT f.id, artistNames.name AS artistName
            FROM filtered f
            JOIN trackArtists ON trackArtists.trackId = f.id
            JOIN artistNames ON artistNames.id = trackArtists.artistId
            UNION ALL
            SELECT f.id, '' AS artistName
            FROM filtered f
            WHERE NOT EXISTS (SELECT 1 FROM trackArtists WHERE trackArtists.trackId = f.id)
        ), pageNames(artistName) AS (
            VALUES \(pageValues)
        ), pageArtistTracks AS (
            SELECT at.id, at.artistName
            FROM artistTracks at
            JOIN pageNames pn ON pn.artistName = at.artistName
        ), pageAlbums AS (
            SELECT DISTINCT ad.albumTitle, ad.albumOwner
            FROM pageArtistTracks pat
            JOIN albumData ad ON ad.id = pat.id
        ), albumTotals AS (
            SELECT ad.albumTitle, ad.albumOwner, COUNT(*) AS totalTrackCount
            FROM allAlbumData ad
            JOIN pageAlbums pa ON pa.albumTitle = ad.albumTitle AND pa.albumOwner = ad.albumOwner
            GROUP BY ad.albumTitle, ad.albumOwner
        ), artistAlbums AS (
            SELECT pat.artistName, ad.albumTitle, ad.albumOwner,
                   COUNT(*) AS artistTrackCount, totals.totalTrackCount
            FROM pageArtistTracks pat
            JOIN albumData ad ON ad.id = pat.id
            JOIN albumTotals totals ON totals.albumTitle = ad.albumTitle
                AND totals.albumOwner = ad.albumOwner
            GROUP BY pat.artistName, ad.albumTitle, ad.albumOwner, totals.totalTrackCount
        )
        SELECT artistName, albumTitle, albumOwner, artistTrackCount, totalTrackCount
        FROM artistAlbums
        ORDER BY artistName COLLATE NOCASE, artistName,
                 albumTitle COLLATE NOCASE, albumTitle,
                 albumOwner COLLATE NOCASE, albumOwner
        """
    }

    private static func fetchArtistSummaries(
        database: Database,
        query: String,
        names: [String]
    ) throws -> [CatalogFacetTextKey: CatalogArtistAggregate] {
        let (whereClause, searchArguments) = Self.searchPredicate(query: query, alias: "tracks", field: .artist)
        let pageValues = names.map { _ in "(?)" }.joined(separator: ", ")
        var summaryArguments = searchArguments
        for name in names {
            summaryArguments += [name]
        }
        let summarySQL = Self.artistPageSummarySQL(whereClause: whereClause, pageValues: pageValues)
        CatalogFacetQueryTesting.record(
            CatalogFacetQueryEvent(kind: .artists, stage: .pageSummaries, sql: summarySQL)
        )
        let cursor = try Row.fetchCursor(database, sql: summarySQL, arguments: summaryArguments)
        var values: [CatalogFacetTextKey: CatalogArtistAggregate] = [:]
        values.reserveCapacity(names.count)
        while let row = try cursor.next() {
            try Self.checkCatalogCancellation()
            let name: String = row["artistName"]
            let nameKey = CatalogFacetTextKey(name)
            let key = AlbumKey(title: row["albumTitle"], owner: row["albumOwner"])
            let artistTrackCount: Int = row["artistTrackCount"]
            let totalTrackCount: Int = row["totalTrackCount"]
            let ownerNames = Self.splitNames(key.owner)
            let isOwned: Bool
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isOwned = ownerNames.isEmpty
            } else if !ownerNames.isEmpty {
                isOwned = ownerNames.contains {
                    $0.localizedCaseInsensitiveCompare(name) == .orderedSame
                }
            } else {
                isOwned = artistTrackCount == totalTrackCount
            }
            var value = values[nameKey, default: CatalogArtistAggregate()]
            value.trackCount += artistTrackCount
            value.albumCount += 1
            if !isOwned { value.appearanceCount += 1 }
            values[nameKey] = value
        }
        return values
    }
}
