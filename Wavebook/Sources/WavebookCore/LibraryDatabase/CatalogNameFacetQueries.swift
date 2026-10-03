import Foundation
import GRDB

struct CatalogNameFacetPageKeys: Sendable {
    let names: [String]
    let hasMore: Bool
}
struct CatalogNameFacetDefinition: Sendable {
    let kind: CatalogFacetKind
    let searchField: CatalogSearchField
    let relationshipTable: String
    let nameTable: String
    let nameIDColumn: String

    static let artists = Self(
        kind: .artists,
        searchField: .artist,
        relationshipTable: "trackArtists",
        nameTable: "artistNames",
        nameIDColumn: "artistId"
    )
    static let genres = Self(
        kind: .genres,
        searchField: .genre,
        relationshipTable: "trackGenres",
        nameTable: "genreNames",
        nameIDColumn: "genreId"
    )
}

extension LibraryDatabase {
    static func nameFacetNamesCTE(
        whereClause: String,
        facetWhereClause: String,
        includeUnknown: Bool,
        definition: CatalogNameFacetDefinition
    ) -> String {
        let unknownNames = includeUnknown ? """
            UNION
            SELECT '' AS facetName
            FROM filtered
            WHERE NOT EXISTS (
                SELECT 1 FROM \(definition.relationshipTable)
                WHERE \(definition.relationshipTable).trackId = filtered.id
            )
            """ : ""
        return """
        WITH filtered AS (
            SELECT id
            FROM tracks
            WHERE \(whereClause)
        ), facetNames AS (
            SELECT DISTINCT \(definition.nameTable).name AS facetName
            FROM filtered
            JOIN \(definition.relationshipTable) ON \(definition.relationshipTable).trackId = filtered.id
            JOIN \(definition.nameTable) ON \(definition.nameTable).id =
                \(definition.relationshipTable).\(definition.nameIDColumn)
            WHERE \(facetWhereClause)
            \(unknownNames)
        )
        """
    }

    static func nameFacetPageOffset(
        db database: Database,
        query: String,
        selectedName: String,
        page: (requestedOffset: Int, limit: Int),
        definition: CatalogNameFacetDefinition
    ) throws -> Int {
        let (whereClause, searchArguments) = Self.searchPredicate(
            query: query,
            alias: "tracks",
            field: definition.searchField
        )
        let (facetWhereClause, facetArguments) = Self.nameSearchPredicate(
            query: query,
            alias: definition.nameTable
        )
        let facetNamesCTE = nameFacetNamesCTE(
            whereClause: whereClause,
            facetWhereClause: facetWhereClause,
            includeUnknown: SearchNormalizer.tokens(query).isEmpty,
            definition: definition
        )

        var rankArguments = searchArguments
        rankArguments += facetArguments
        rankArguments += [selectedName, selectedName, selectedName]
        let rank = try Int.fetchOne(
            database,
            sql: facetNamesCTE + """
            SELECT COUNT(*)
            FROM facetNames
            WHERE facetName COLLATE NOCASE < ?
               OR (facetName COLLATE NOCASE = ? AND facetName < ?)
            """,
            arguments: rankArguments
        ) ?? 0

        var existsArguments = searchArguments
        existsArguments += facetArguments
        existsArguments += [selectedName]
        let exists = try Int.fetchOne(
            database,
            sql: facetNamesCTE + "SELECT EXISTS (SELECT 1 FROM facetNames WHERE facetName = ?)",
            arguments: existsArguments
        ) == 1
        return exists ? Self.pageOffset(for: rank, limit: page.limit) : page.requestedOffset
    }

    static func fetchNameFacetPageKeys(
        db database: Database,
        query: String,
        limit: Int,
        offset: Int,
        definition: CatalogNameFacetDefinition
    ) throws -> CatalogNameFacetPageKeys {
        let (whereClause, searchArguments) = Self.searchPredicate(
            query: query,
            alias: "tracks",
            field: definition.searchField
        )
        let (facetWhereClause, facetArguments) = Self.nameSearchPredicate(
            query: query,
            alias: definition.nameTable
        )
        let facetNamesCTE = nameFacetNamesCTE(
            whereClause: whereClause,
            facetWhereClause: facetWhereClause,
            includeUnknown: SearchNormalizer.tokens(query).isEmpty,
            definition: definition
        )
        let keySQL = facetNamesCTE + """
        SELECT facetName
        FROM facetNames
        ORDER BY facetName COLLATE NOCASE, facetName
        LIMIT ? OFFSET ?
        """
        var keyArguments = searchArguments
        keyArguments += facetArguments
        keyArguments += [limit + 1, offset]
        CatalogFacetQueryTesting.record(
            CatalogFacetQueryEvent(kind: definition.kind, stage: .pageKeys, sql: keySQL)
        )
        let keyRows = try Row.fetchAll(database, sql: keySQL, arguments: keyArguments)
        var names: [String] = []
        names.reserveCapacity(min(keyRows.count, limit))
        for row in keyRows {
            try Self.checkCatalogCancellation()
            if names.count < limit {
                names.append(row["facetName"])
            }
        }
        return CatalogNameFacetPageKeys(names: names, hasMore: keyRows.count > limit)
    }
}
