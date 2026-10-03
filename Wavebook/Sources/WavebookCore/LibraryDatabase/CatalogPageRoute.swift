import Foundation

/// Route shown by the catalog browser.
public enum CatalogRoute: Hashable, Sendable {
    /// Global catalog search.
    case search
    /// All songs.
    case songs
    /// Artists, optionally focused on one artist.
    case artists(selectedArtist: String?)
    /// Albums, optionally focused on one album.
    case albums(selectedAlbum: AlbumKey?)
    /// Genres, optionally focused on one genre.
    case genres(selectedGenre: String?)
}

/// Query context used to load a catalog page.
public struct CatalogPageContext: Hashable, Sendable {
    /// Catalog route.
    public let route: CatalogRoute
    /// Search query.
    public let query: String

    /// Creates a catalog page context.
    public init(route: CatalogRoute, query: String) {
        self.route = route
        self.query = query
    }
}

/// Request to append one catalog page.
public enum CatalogPageAppendRequest: Sendable {
    /// Appends songs.
    case songs(query: String, offset: Int)
    /// Appends artist entries.
    case artistEntries(query: String, selectedArtist: String?, offset: Int)
    /// Appends artist detail.
    case artistDetail(query: String, selectedArtist: String, detailOffset: Int, trackOffset: Int)
    /// Appends album entries.
    case albumEntries(query: String, selectedAlbum: AlbumKey?, offset: Int)
    /// Appends album detail.
    case albumDetail(query: String, selectedAlbum: AlbumKey, offset: Int)
    /// Appends genre entries.
    case genreEntries(query: String, selectedGenre: String?, offset: Int)
    /// Appends genre detail.
    case genreDetail(query: String, selectedGenre: String, offset: Int)

    /// Context associated with the append request.
    public var context: CatalogPageContext {
        switch self {
        case let .songs(query, _):
            return CatalogPageContext(route: .songs, query: query)
        case let .artistEntries(query, selectedArtist, _):
            return CatalogPageContext(route: .artists(selectedArtist: selectedArtist), query: query)
        case let .artistDetail(query, selectedArtist, _, _):
            return CatalogPageContext(route: .artists(selectedArtist: selectedArtist), query: query)
        case let .albumEntries(query, selectedAlbum, _):
            return CatalogPageContext(route: .albums(selectedAlbum: selectedAlbum), query: query)
        case let .albumDetail(query, selectedAlbum, _):
            return CatalogPageContext(route: .albums(selectedAlbum: selectedAlbum), query: query)
        case let .genreEntries(query, selectedGenre, _):
            return CatalogPageContext(route: .genres(selectedGenre: selectedGenre), query: query)
        case let .genreDetail(query, selectedGenre, _):
            return CatalogPageContext(route: .genres(selectedGenre: selectedGenre), query: query)
        }
    }
}

/// Request to replace or append catalog content.
public enum CatalogPageRequest: Sendable {
    /// Replaces the current page.
    case replace(CatalogPageContext)
    /// Appends content to the current page.
    case append(CatalogPageAppendRequest)

    /// Context associated with the request.
    public var context: CatalogPageContext {
        switch self {
        case let .replace(context):
            return context
        case let .append(request):
            return request.context
        }
    }
}

/// Change to a paged result.
public enum CatalogPageChange<Page: Sendable>: Sendable {
    /// Replaces page content.
    case replace(Page)
    /// Appends page content.
    case append(Page)
}

/// Artist entries and optional selected-artist detail.
public struct CatalogArtistsPage: Sendable {
    /// Artist entries.
    public let entries: LibraryNamePage
    /// Selected artist name.
    public let selectedArtist: String?
    /// Selected artist detail.
    public let detail: LibraryArtistDetailPage?

    /// Creates an artists page.
    public init(entries: LibraryNamePage, selectedArtist: String?, detail: LibraryArtistDetailPage?) {
        self.entries = entries
        self.selectedArtist = selectedArtist
        self.detail = detail
    }
}

/// Change to an artists page.
public enum CatalogArtistsPageChange: Sendable {
    /// Replaces artist content.
    case replace(CatalogArtistsPage)
    /// Appends artist entries.
    case appendEntries(LibraryNamePage)
    /// Appends artist detail.
    case appendDetail(LibraryArtistDetailPage)
}

/// Album entries and optional selected-album tracks.
public struct CatalogAlbumsPage: Sendable {
    /// Album entries.
    public let entries: LibraryAlbumPage
    /// Selected album key.
    public let selectedAlbum: AlbumKey?
    /// Tracks for the selected album.
    public let tracks: LibraryTrackPage

    /// Creates an albums page.
    public init(entries: LibraryAlbumPage, selectedAlbum: AlbumKey?, tracks: LibraryTrackPage) {
        self.entries = entries
        self.selectedAlbum = selectedAlbum
        self.tracks = tracks
    }
}

/// Change to an albums page.
public enum CatalogAlbumsPageChange: Sendable {
    /// Replaces album content.
    case replace(CatalogAlbumsPage)
    /// Appends album entries.
    case appendEntries(LibraryAlbumPage)
    /// Appends album detail tracks.
    case appendDetail(LibraryTrackPage)
}

/// Genre entries and tracks for the selected genre.
public struct CatalogGenresPage: Sendable {
    /// Genre entries.
    public let entries: LibraryNamePage
    /// Selected genre name.
    public let selectedGenre: String?
    /// Tracks for the selected genre.
    public let tracks: LibraryTrackPage

    /// Creates a genres page.
    public init(entries: LibraryNamePage, selectedGenre: String?, tracks: LibraryTrackPage) {
        self.entries = entries
        self.selectedGenre = selectedGenre
        self.tracks = tracks
    }
}

/// Change to a genres page.
public enum CatalogGenresPageChange: Sendable {
    /// Replaces genre content.
    case replace(CatalogGenresPage)
    /// Appends genre entries.
    case appendEntries(LibraryNamePage)
    /// Appends genre detail tracks.
    case appendDetail(LibraryTrackPage)
}

/// Songs, artists, albums, and genres matching one query.
public struct CatalogSearchPage: Sendable {
    /// Matching songs.
    public let songs: LibraryTrackPage
    /// Matching artists.
    public let artists: LibraryNamePage
    /// Matching albums.
    public let albums: LibraryAlbumPage
    /// Matching genres.
    public let genres: LibraryNamePage

    /// Creates a global search page.
    public init(
        songs: LibraryTrackPage,
        artists: LibraryNamePage,
        albums: LibraryAlbumPage,
        genres: LibraryNamePage
    ) {
        self.songs = songs
        self.artists = artists
        self.albums = albums
        self.genres = genres
    }
}

/// Result of loading a catalog page.
public enum CatalogPageResult: Sendable {
    /// Global search result.
    case search(query: String, page: CatalogSearchPage)
    /// Songs result.
    case songs(query: String, change: CatalogPageChange<LibraryTrackPage>)
    /// Artists result.
    case artists(query: String, selectedArtist: String?, change: CatalogArtistsPageChange)
    /// Albums result.
    case albums(query: String, selectedAlbum: AlbumKey?, change: CatalogAlbumsPageChange)
    /// Genres result.
    case genres(query: String, selectedGenre: String?, change: CatalogGenresPageChange)

    /// Context associated with the result.
    public var context: CatalogPageContext {
        switch self {
        case let .search(query, _):
            return CatalogPageContext(route: .search, query: query)
        case let .songs(query, _):
            return CatalogPageContext(route: .songs, query: query)
        case let .artists(query, selectedArtist, _):
            return CatalogPageContext(route: .artists(selectedArtist: selectedArtist), query: query)
        case let .albums(query, selectedAlbum, _):
            return CatalogPageContext(route: .albums(selectedAlbum: selectedAlbum), query: query)
        case let .genres(query, selectedGenre, _):
            return CatalogPageContext(route: .genres(selectedGenre: selectedGenre), query: query)
        }
    }
}

/// Loads catalog pages from the database.
public extension CatalogPageRequest {
    /// Loads the requested catalog page.
    nonisolated func load(from database: LibraryDatabase) throws -> CatalogPageResult {
        try Task.checkCancellation()
        switch self {
        case let .replace(context):
            return try loadReplacement(from: database, context: context)
        case let .append(request):
            return try loadAppend(from: database, request: request)
        }
    }
}

private nonisolated func loadReplacement(
    from database: LibraryDatabase,
    context: CatalogPageContext
) throws -> CatalogPageResult {
    switch context.route {
    case .search:
        let songs = try database.trackPage(for: .all, matching: context.query, searchField: .title)
        try Task.checkCancellation()
        let artists = try database.artistPage(matching: context.query)
        try Task.checkCancellation()
        let albums = try database.albumPage(matching: context.query)
        try Task.checkCancellation()
        let genres = try database.genrePage(matching: context.query)
        try Task.checkCancellation()
        return .search(
            query: context.query,
            page: CatalogSearchPage(songs: songs, artists: artists, albums: albums, genres: genres)
        )
    case .songs:
        return .songs(
            query: context.query,
            change: .replace(try database.trackPage(for: .all, matching: context.query, searchField: .title))
        )
    case let .artists(requestedArtist):
        return try loadArtistReplacement(
            from: database,
            query: context.query,
            requestedArtist: requestedArtist
        )
    case let .albums(requestedAlbum):
        return try loadAlbumReplacement(
            from: database,
            query: context.query,
            requestedAlbum: requestedAlbum
        )
    case let .genres(requestedGenre):
        return try loadGenreReplacement(
            from: database,
            query: context.query,
            requestedGenre: requestedGenre
        )
    }
}

private nonisolated func loadArtistReplacement(
    from database: LibraryDatabase,
    query: String,
    requestedArtist: String?
) throws -> CatalogPageResult {
    let entries = try database.artistPage(matching: query, selectedArtist: requestedArtist)
    let selectedArtist = requestedArtist.flatMap { requested in
        entries.items.first { $0.name == requested }?.name
    }
    let detail = try selectedArtist.map {
        try database.artistDetailPage(artist: $0, matching: query)
    }
    try Task.checkCancellation()
    return .artists(
        query: query,
        selectedArtist: requestedArtist,
        change: .replace(CatalogArtistsPage(entries: entries, selectedArtist: selectedArtist, detail: detail))
    )
}

private nonisolated func loadAlbumReplacement(
    from database: LibraryDatabase,
    query: String,
    requestedAlbum: AlbumKey?
) throws -> CatalogPageResult {
    let entries = try database.albumPage(matching: query, selectedAlbum: requestedAlbum)
    try Task.checkCancellation()
    let selectedAlbum = requestedAlbum.flatMap { requested in
        entries.items.first { $0.key == requested }?.key
    } ?? entries.items.first?.key
    let tracks = try selectedAlbum.map {
        try database.trackPage(for: .album($0), matching: query)
    } ?? emptyCatalogTrackPage()
    try Task.checkCancellation()
    return .albums(
        query: query,
        selectedAlbum: requestedAlbum,
        change: .replace(CatalogAlbumsPage(entries: entries, selectedAlbum: selectedAlbum, tracks: tracks))
    )
}

private nonisolated func loadGenreReplacement(
    from database: LibraryDatabase,
    query: String,
    requestedGenre: String?
) throws -> CatalogPageResult {
    let entries = try database.genrePage(matching: query, selectedGenre: requestedGenre)
    try Task.checkCancellation()
    let selectedGenre = requestedGenre.flatMap { requested in
        entries.items.first { $0.name == requested }?.name
    } ?? entries.items.first?.name
    let tracks = try selectedGenre.map {
        try database.trackPage(for: .genre($0), matching: query)
    } ?? emptyCatalogTrackPage()
    try Task.checkCancellation()
    return .genres(
        query: query,
        selectedGenre: requestedGenre,
        change: .replace(CatalogGenresPage(entries: entries, selectedGenre: selectedGenre, tracks: tracks))
    )
}

private nonisolated func loadAppend(
    from database: LibraryDatabase,
    request: CatalogPageAppendRequest
) throws -> CatalogPageResult {
    switch request {
    case let .songs(query, offset):
        return .songs(
            query: query,
            change: .append(try database.trackPage(for: .all, matching: query, searchField: .title, offset: offset))
        )
    case let .artistEntries(query, selectedArtist, offset):
        return .artists(
            query: query,
            selectedArtist: selectedArtist,
            change: .appendEntries(try database.artistPage(matching: query, offset: offset))
        )
    case let .artistDetail(query, selectedArtist, detailOffset, trackOffset):
        return .artists(
            query: query,
            selectedArtist: selectedArtist,
            change: .appendDetail(try database.artistDetailPage(
                artist: selectedArtist,
                matching: query,
                detailOffset: detailOffset,
                trackPage: .init(offset: trackOffset)
            ))
        )
    case let .albumEntries(query, selectedAlbum, offset):
        return .albums(
            query: query,
            selectedAlbum: selectedAlbum,
            change: .appendEntries(try database.albumPage(matching: query, offset: offset))
        )
    case let .albumDetail(query, selectedAlbum, offset):
        return .albums(
            query: query,
            selectedAlbum: selectedAlbum,
            change: .appendDetail(try database.trackPage(for: .album(selectedAlbum), matching: query, offset: offset))
        )
    case let .genreEntries(query, selectedGenre, offset):
        return .genres(
            query: query,
            selectedGenre: selectedGenre,
            change: .appendEntries(try database.genrePage(matching: query, offset: offset))
        )
    case let .genreDetail(query, selectedGenre, offset):
        return .genres(
            query: query,
            selectedGenre: selectedGenre,
            change: .appendDetail(try database.trackPage(for: .genre(selectedGenre), matching: query, offset: offset))
        )
    }
}

private nonisolated func emptyCatalogTrackPage() -> LibraryTrackPage {
    LibraryTrackPage(
        tracks: [],
        offset: 0,
        limit: LibraryDatabase.defaultTrackPageSize,
        hasMore: false
    )
}
