import Foundation

private func collectCatalogPages<Item: Hashable & Sendable>(
    load: (Int) throws -> LibraryCatalogPage<Item>
) throws -> [Item] {
    var result: [Item] = []
    var offset = 0
    while true {
        try Task.checkCancellation()
        let page = try load(offset)
        result.append(contentsOf: page.items)
        guard page.hasMore, !page.items.isEmpty else { return result }
        offset = page.offset + page.items.count
    }
}

extension LibraryDatabase {
    /// Returns a page of artists.
    public func artistPage(
        matching query: String = "",
        limit: Int = LibraryDatabase.defaultTrackPageSize,
        offset: Int = 0,
        selectedArtist: String? = nil
    ) throws -> LibraryNamePage {
        let selection = selectedArtist.map { CatalogFacetSelection.artist($0) }
        let page = try catalogFacetPage(
            matching: query,
            kind: .artists,
            limit: limit,
            offset: offset,
            selection: selection
        )
        guard case let .artists(items) = page.snapshot else {
            return LibraryNamePage(items: [], offset: page.offset, limit: page.limit, hasMore: false)
        }
        return LibraryNamePage(items: items, offset: page.offset, limit: page.limit, hasMore: page.hasMore)
    }

    /// Returns all artists matching a query.
    @available(*, unavailable, message: "Use artistPage for bounded catalog consumption.")
    public func artists(matching query: String = "") throws -> [LibraryNameSummary] {
        try collectCatalogPages { offset in
            try artistPage(matching: query, limit: LibraryDatabase.maximumTrackPageSize, offset: offset)
        }
    }

    /// Returns a page of albums.
    public func albumPage(
        matching query: String = "",
        limit: Int = LibraryDatabase.defaultTrackPageSize,
        offset: Int = 0,
        selectedAlbum: AlbumKey? = nil
    ) throws -> LibraryAlbumPage {
        let selection = selectedAlbum.map { CatalogFacetSelection.album($0) }
        let page = try catalogFacetPage(
            matching: query,
            kind: .albums,
            limit: limit,
            offset: offset,
            selection: selection
        )
        guard case let .albums(items) = page.snapshot else {
            return LibraryAlbumPage(items: [], offset: page.offset, limit: page.limit, hasMore: false)
        }
        return LibraryAlbumPage(items: items, offset: page.offset, limit: page.limit, hasMore: page.hasMore)
    }

    /// Returns all albums matching a query.
    @available(*, unavailable, message: "Use albumPage for bounded catalog consumption.")
    public func albums(matching query: String = "") throws -> [LibraryAlbumSummary] {
        try collectCatalogPages { offset in
            try albumPage(matching: query, limit: LibraryDatabase.maximumTrackPageSize, offset: offset)
        }
    }

    /// Returns a page of genres.
    public func genrePage(
        matching query: String = "",
        limit: Int = LibraryDatabase.defaultTrackPageSize,
        offset: Int = 0,
        selectedGenre: String? = nil
    ) throws -> LibraryNamePage {
        let selection = selectedGenre.map { CatalogFacetSelection.genre($0) }
        let page = try catalogFacetPage(
            matching: query,
            kind: .genres,
            limit: limit,
            offset: offset,
            selection: selection
        )
        guard case let .genres(items) = page.snapshot else {
            return LibraryNamePage(items: [], offset: page.offset, limit: page.limit, hasMore: false)
        }
        return LibraryNamePage(items: items, offset: page.offset, limit: page.limit, hasMore: page.hasMore)
    }

    /// Returns all genres matching a query.
    @available(*, unavailable, message: "Use genrePage for bounded catalog consumption.")
    public func genres(matching query: String = "") throws -> [LibraryNameSummary] {
        try collectCatalogPages { offset in
            try genrePage(matching: query, limit: LibraryDatabase.maximumTrackPageSize, offset: offset)
        }
    }
}
