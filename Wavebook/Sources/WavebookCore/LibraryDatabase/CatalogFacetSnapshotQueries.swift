import Foundation
import GRDB

struct CatalogFacetTextKey: Hashable, Sendable {
    let value: String
    let bytes: [UInt8]

    init(_ value: String) {
        self.value = value
        bytes = Array(value.utf8)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bytes == rhs.bytes
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bytes)
    }
}

/// Ordering helpers for catalog facet values.
public enum CatalogFacetOrdering {
    /// Compares localized names with a raw UTF-8 tie-breaker.
    public static func localizedNameComparison(_ lhs: String, _ rhs: String) -> ComparisonResult {
        rawTieBrokenComparison(
            localized: lhs.localizedCaseInsensitiveCompare(rhs),
            lhs: lhs,
            rhs: rhs
        )
    }

    /// Returns whether one localized name precedes another.
    public static func localizedNamePrecedes(_ lhs: String, _ rhs: String) -> Bool {
        localizedNameComparison(lhs, rhs) == .orderedAscending
    }

    /// Compares localized paths with a raw UTF-8 tie-breaker.
    public static func localizedPathComparison(_ lhs: String, _ rhs: String) -> ComparisonResult {
        rawTieBrokenComparison(
            localized: lhs.localizedStandardCompare(rhs),
            lhs: lhs,
            rhs: rhs
        )
    }

    /// Returns whether one localized path precedes another.
    public static func localizedPathPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        localizedPathComparison(lhs, rhs) == .orderedAscending
    }

    static func rawTieBrokenComparison(
        localized: ComparisonResult,
        lhs: String,
        rhs: String
    ) -> ComparisonResult {
        localized == .orderedSame ? rawValueComparison(lhs, rhs) : localized
    }

    static func rawValueComparison(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs.utf8.elementsEqual(rhs.utf8) { return .orderedSame }
        return lhs.utf8.lexicographicallyPrecedes(rhs.utf8) ? .orderedAscending : .orderedDescending
    }
}

extension LibraryDatabase {
    static func emptyFacetSnapshot(for kind: CatalogFacetKind) -> CatalogFacetSnapshot {
        switch kind {
        case .artists:
            return .artists([])
        case .albums:
            return .albums([])
        case .genres:
            return .genres([])
        }
    }

    static func catalogFacetRevision(in database: Database) throws -> CatalogFacetRevision {
        CatalogFacetRevision(
            totalChanges: try Int64.fetchOne(database, sql: "SELECT total_changes()") ?? 0,
            dataVersion: try Int64.fetchOne(database, sql: "PRAGMA data_version") ?? 0
        )
    }

    static func selectedFacetPageOffset(
        db database: Database,
        query: String,
        kind: CatalogFacetKind,
        selection: CatalogFacetSelection? = nil,
        requestedOffset: Int,
        limit: Int
    ) throws -> Int {
        switch (kind, selection) {
        case let (.artists, .artist(name)):
            return try artistPageOffset(
                db: database,
                query: query,
                selectedArtist: name,
                requestedOffset: requestedOffset,
                limit: limit
            )
        case let (.albums, .album(key)):
            return try albumPageOffset(
                db: database,
                query: query,
                selectedAlbum: key,
                requestedOffset: requestedOffset,
                limit: limit
            )
        case let (.genres, .genre(name)):
            return try genrePageOffset(
                db: database,
                query: query,
                selectedGenre: name,
                requestedOffset: requestedOffset,
                limit: limit
            )
        default:
            return requestedOffset
        }
    }

    static func fetchFacetPage(
        db database: Database,
        query: String,
        kind: CatalogFacetKind,
        limit: Int,
        offset: Int
    ) throws -> CatalogFacetPageResult {
        switch kind {
        case .artists:
            return try fetchArtistPage(db: database, query: query, limit: limit, offset: offset)
        case .albums:
            return try fetchAlbumPage(db: database, query: query, limit: limit, offset: offset)
        case .genres:
            return try fetchGenrePage(db: database, query: query, limit: limit, offset: offset)
        }
    }

}
