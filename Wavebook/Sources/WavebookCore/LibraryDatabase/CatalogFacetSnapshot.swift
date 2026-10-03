import Foundation

enum CatalogFacetKind: Hashable, Sendable {
    case artists
    case albums
    case genres
}

enum CatalogFacetSnapshot: Sendable {
    case artists([LibraryNameSummary])
    case albums([LibraryAlbumSummary])
    case genres([LibraryNameSummary])

    var artists: [LibraryNameSummary] {
        guard case let .artists(items) = self else { return [] }
        return items
    }

    var albums: [LibraryAlbumSummary] {
        guard case let .albums(items) = self else { return [] }
        return items
    }

    var genres: [LibraryNameSummary] {
        guard case let .genres(items) = self else { return [] }
        return items
    }
}

enum CatalogFacetSelection: Sendable {
    case artist(String)
    case album(AlbumKey)
    case genre(String)
}

struct CatalogFacetPageResult: Sendable {
    let snapshot: CatalogFacetSnapshot
    let offset: Int
    let limit: Int
    let hasMore: Bool
}

enum CatalogFacetQueryStage: Hashable, Sendable {
    case pageKeys
    case pageSummaries
}

struct CatalogFacetQueryEvent: Sendable {
    let kind: CatalogFacetKind
    let stage: CatalogFacetQueryStage
    let sql: String
}

enum CatalogFacetQueryTesting {
    @TaskLocal
    static var observer: (@Sendable (CatalogFacetQueryEvent) -> Void)?

    static func record(_ event: CatalogFacetQueryEvent) {
        observer?(event)
    }
}

struct CatalogFacetRevision: Equatable {
    let totalChanges: Int64
    let dataVersion: Int64
}

struct CatalogFacetCacheKey: Hashable {
    let query: String
    let kind: CatalogFacetKind
    let limit: Int
    let offset: Int
}

private struct CatalogFacetCacheEntry {
    let revision: CatalogFacetRevision
    let page: CatalogFacetPageResult
}

final class CatalogFacetSnapshotStore: @unchecked Sendable {
    private static let maximumPages = 4
    private let lock = NSLock()
    private var entries: [CatalogFacetCacheKey: CatalogFacetCacheEntry] = [:]
    private var order: [CatalogFacetCacheKey] = []

    func page(
        for key: CatalogFacetCacheKey,
        revision: CatalogFacetRevision
    ) -> CatalogFacetPageResult? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key], entry.revision == revision else { return nil }
        touch(key)
        return entry.page
    }

    func insert(
        _ page: CatalogFacetPageResult,
        for key: CatalogFacetCacheKey,
        revision: CatalogFacetRevision
    ) {
        lock.lock()
        defer { lock.unlock() }
        entries[key] = CatalogFacetCacheEntry(revision: revision, page: page)
        touch(key)
        while order.count > Self.maximumPages {
            let evicted = order.removeFirst()
            entries.removeValue(forKey: evicted)
        }
    }

    private func touch(_ key: CatalogFacetCacheKey) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

extension LibraryDatabase {
    func catalogFacetPage(
        matching query: String,
        kind: CatalogFacetKind,
        limit: Int,
        offset: Int,
        selection: CatalogFacetSelection?
    ) throws -> CatalogFacetPageResult {
        try Self.checkCatalogCancellation()
        let bounds = Self.pageBounds(limit: limit, offset: offset)
        guard bounds.limit > 0 else {
            return CatalogFacetPageResult(
                snapshot: Self.emptyFacetSnapshot(for: kind),
                offset: bounds.offset,
                limit: bounds.limit,
                hasMore: false
            )
        }

        return try readCatalog { database in
            let revision = try Self.catalogFacetRevision(in: database)
            let pageOffset = try Self.selectedFacetPageOffset(
                db: database,
                query: query,
                kind: kind,
                selection: selection,
                requestedOffset: bounds.offset,
                limit: bounds.limit
            )
            let key = CatalogFacetCacheKey(query: query, kind: kind, limit: bounds.limit, offset: pageOffset)
            if let cached = catalogFacetSnapshotStore.page(for: key, revision: revision) {
                return cached
            }

            let page = try Self.fetchFacetPage(
                db: database,
                query: query,
                kind: kind,
                limit: bounds.limit,
                offset: pageOffset
            )
            if try Self.catalogFacetRevision(in: database) == revision {
                catalogFacetSnapshotStore.insert(page, for: key, revision: revision)
            }
            return page
        }
    }
}
