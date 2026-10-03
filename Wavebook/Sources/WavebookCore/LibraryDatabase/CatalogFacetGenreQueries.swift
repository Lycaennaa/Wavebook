import Foundation
import GRDB

extension LibraryDatabase {

    static func genrePageOffset(
        db database: Database,
        query: String,
        selectedGenre: String,
        requestedOffset: Int,
        limit: Int
    ) throws -> Int {
        try Self.nameFacetPageOffset(
            db: database,
            query: query,
            selectedName: selectedGenre,
            page: (requestedOffset: requestedOffset, limit: limit),
            definition: .genres
        )
    }

    static func fetchGenrePage(
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
            definition: .genres
        )
        let names = pageKeys.names
        guard !names.isEmpty else {
            return CatalogFacetPageResult(snapshot: .genres([]), offset: offset, limit: limit, hasMore: false)
        }

        let values = try Self.fetchGenreSummaries(database: database, query: query, names: names)
        return CatalogFacetPageResult(
            snapshot: .genres(names.compactMap { values[CatalogFacetTextKey($0)] }),
            offset: offset,
            limit: limit,
            hasMore: pageKeys.hasMore
        )
    }
    private static func genrePageSummarySQL(whereClause: String, pageValues: String) -> String {
        """
        WITH filtered AS (
            SELECT id
            FROM tracks
            WHERE \(whereClause)
        ), genreTracks AS (
            SELECT f.id, genreNames.name AS genreName
            FROM filtered f
            JOIN trackGenres ON trackGenres.trackId = f.id
            JOIN genreNames ON genreNames.id = trackGenres.genreId
            UNION ALL
            SELECT f.id, '' AS genreName
            FROM filtered f
            WHERE NOT EXISTS (SELECT 1 FROM trackGenres WHERE trackGenres.trackId = f.id)
        ), pageNames(genreName) AS (
            VALUES \(pageValues)
        ), pageGenreTracks AS (
            SELECT gt.id, gt.genreName
            FROM genreTracks gt
            JOIN pageNames pn ON pn.genreName = gt.genreName
        ), genreArtists AS (
            SELECT pgt.id, pgt.genreName, artistNames.name AS artistName
            FROM pageGenreTracks pgt
            JOIN trackArtists ON trackArtists.trackId = pgt.id
            JOIN artistNames ON artistNames.id = trackArtists.artistId
            UNION ALL
            SELECT pgt.id, pgt.genreName, '' AS artistName
            FROM pageGenreTracks pgt
            WHERE NOT EXISTS (SELECT 1 FROM trackArtists WHERE trackArtists.trackId = pgt.id)
        )
        SELECT pgt.genreName,
               COUNT(DISTINCT pgt.id) AS trackCount,
               COUNT(DISTINCT ga.artistName) AS artistCount
        FROM pageGenreTracks pgt
        JOIN genreArtists ga ON ga.id = pgt.id AND ga.genreName = pgt.genreName
        GROUP BY pgt.genreName
        ORDER BY pgt.genreName COLLATE NOCASE, pgt.genreName
        """
    }

    private static func fetchGenreSummaries(
        database: Database,
        query: String,
        names: [String]
    ) throws -> [CatalogFacetTextKey: LibraryNameSummary] {
        let (whereClause, searchArguments) = Self.searchPredicate(query: query, alias: "tracks", field: .genre)
        let pageValues = names.map { _ in "(?)" }.joined(separator: ", ")
        var summaryArguments = searchArguments
        for name in names {
            summaryArguments += [name]
        }
        let summarySQL = Self.genrePageSummarySQL(whereClause: whereClause, pageValues: pageValues)
        CatalogFacetQueryTesting.record(
            CatalogFacetQueryEvent(kind: .genres, stage: .pageSummaries, sql: summarySQL)
        )
        let rows = try Row.fetchAll(database, sql: summarySQL, arguments: summaryArguments)
        var values: [CatalogFacetTextKey: LibraryNameSummary] = [:]
        values.reserveCapacity(names.count)
        for row in rows {
            try Self.checkCatalogCancellation()
            let name: String = row["genreName"]
            let nameKey = CatalogFacetTextKey(name)
            values[nameKey] = LibraryNameSummary(
                name: name,
                trackCount: row["trackCount"],
                artistCount: row["artistCount"]
            )
        }
        return values
    }
}
