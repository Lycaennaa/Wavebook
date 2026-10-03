import WavebookCore

struct FacetTracksPageState {
    enum Content {
        case empty
        case artists(entries: LibraryNamePage, detail: LibraryArtistDetailPage?)
        case albums(entries: LibraryAlbumPage, tracks: LibraryTrackPage)
        case genres(entries: LibraryNamePage, tracks: LibraryTrackPage)
    }

    private(set) var content: Content = .empty
    private(set) var selectedArtist: String?
    private(set) var selectedAlbum: AlbumKey?
    private(set) var selectedGenre: String?

    private static let maximumRetainedFacetCount = PlaybackQueue.maximumEntryCount

    private static func appendBounded<T>(
        _ current: [T],
        _ page: [T],
        hasMore: Bool
    ) -> (items: [T], hasMore: Bool) {
        guard current.count < maximumRetainedFacetCount else {
            return (current, false)
        }
        let appendCount = min(page.count, maximumRetainedFacetCount - current.count)
        var items = current
        items.reserveCapacity(current.count + appendCount)
        items.append(contentsOf: page.prefix(appendCount))
        return (items, hasMore && appendCount == page.count)
    }
    var artistPage: LibraryNamePage? {
        guard case let .artists(entries, _) = content else { return nil }
        return entries
    }

    var albumPage: LibraryAlbumPage? {
        guard case let .albums(entries, _) = content else { return nil }
        return entries
    }

    var genrePage: LibraryNamePage? {
        guard case let .genres(entries, _) = content else { return nil }
        return entries
    }

    var artistDetailPage: LibraryArtistDetailPage? {
        guard case let .artists(_, detail) = content else { return nil }
        return detail
    }

    var albumTrackPage: LibraryTrackPage? {
        guard case let .albums(_, tracks) = content else { return nil }
        return tracks
    }

    var genreTrackPage: LibraryTrackPage? {
        guard case let .genres(_, tracks) = content else { return nil }
        return tracks
    }

    var artistEntries: [LibraryNameSummary] {
        artistPage?.items ?? []
    }

    var albumEntries: [LibraryAlbumSummary] {
        albumPage?.items ?? []
    }

    var genreEntries: [LibraryNameSummary] {
        genrePage?.items ?? []
    }

    var hasMoreFacets: Bool {
        switch content {
        case let .artists(entries, _): return entries.hasMore
        case let .albums(entries, _): return entries.hasMore
        case let .genres(entries, _): return entries.hasMore
        case .empty: return false
        }
    }

    var loadedFacetCount: Int {
        if let page = artistPage { return page.offset + page.items.count }
        if let page = albumPage { return page.offset + page.items.count }
        if let page = genrePage { return page.offset + page.items.count }
        return 0
    }

    var hasMoreDetails: Bool {
        artistDetailPage?.hasMore ?? albumTrackPage?.hasMore ?? genreTrackPage?.hasMore ?? false
    }

    var loadedDetailTrackCount: Int {
        artistDetailPage?.tracks.tracks.count
            ?? albumTrackPage?.tracks.count
            ?? genreTrackPage?.tracks.count
            ?? 0
    }

    var detailOffset: Int {
        artistDetailPage?.detailOffset ?? 0
    }

    var detailLimit: Int {
        artistDetailPage?.detailLimit ?? LibraryDatabase.defaultTrackPageSize
    }

    var tracks: [Track] {
        switch content {
        case let .artists(_, detail):
            return detail?.tracks.tracks ?? []
        case let .albums(_, tracks), let .genres(_, tracks):
            return tracks.tracks
        case .empty:
            return []
        }
    }

    mutating func applyArtists(
        entries: LibraryNamePage,
        selectedArtist: String?,
        detail: LibraryArtistDetailPage?
    ) {
        content = .artists(entries: entries, detail: detail)
        self.selectedArtist = selectedArtist
    }

    mutating func applyAlbums(
        entries: LibraryAlbumPage,
        selectedAlbum: AlbumKey?,
        tracks: LibraryTrackPage
    ) {
        content = .albums(entries: entries, tracks: tracks)
        self.selectedAlbum = selectedAlbum
    }

    mutating func applyGenres(
        entries: LibraryNamePage,
        selectedGenre: String?,
        tracks: LibraryTrackPage
    ) {
        content = .genres(entries: entries, tracks: tracks)
        self.selectedGenre = selectedGenre
    }

    @discardableResult
    mutating func appendArtists(_ page: LibraryNamePage) -> Bool {
        guard case let .artists(current, detail) = content,
              page.offset == current.offset + current.items.count else { return false }
        let appended = Self.appendBounded(current.items, page.items, hasMore: page.hasMore)
        content = .artists(
            entries: LibraryNamePage(
                items: appended.items,
                offset: current.offset,
                limit: page.limit,
                hasMore: appended.hasMore
            ),
            detail: detail
        )
        return true
    }

    @discardableResult
    mutating func appendAlbums(_ page: LibraryAlbumPage) -> Bool {
        guard case let .albums(current, tracks) = content,
              page.offset == current.offset + current.items.count else { return false }
        let appended = Self.appendBounded(current.items, page.items, hasMore: page.hasMore)
        content = .albums(
            entries: LibraryAlbumPage(
                items: appended.items,
                offset: current.offset,
                limit: page.limit,
                hasMore: appended.hasMore
            ),
            tracks: tracks
        )
        return true
    }

    @discardableResult
    mutating func appendGenres(_ page: LibraryNamePage) -> Bool {
        guard case let .genres(current, tracks) = content,
              page.offset == current.offset + current.items.count else { return false }
        let appended = Self.appendBounded(current.items, page.items, hasMore: page.hasMore)
        content = .genres(
            entries: LibraryNamePage(
                items: appended.items,
                offset: current.offset,
                limit: page.limit,
                hasMore: appended.hasMore
            ),
            tracks: tracks
        )
        return true
    }

    @discardableResult
    mutating func appendArtistDetail(_ page: LibraryArtistDetailPage) -> Bool {
        guard case let .artists(entries, current) = content,
              let current,
              page.detailOffset == current.detailOffset + current.detailLimit,
              page.tracks.offset == current.tracks.tracks.count else { return false }
        let ownedAlbums = Self.appendBounded(
            current.detail.ownedAlbums,
            page.detail.ownedAlbums,
            hasMore: page.hasMoreDetail
        )
        let appearingAlbums = Self.appendBounded(
            current.detail.appearingAlbums,
            page.detail.appearingAlbums,
            hasMore: page.hasMoreDetail
        )
        let genres = Self.appendBounded(
            current.detail.genres,
            page.detail.genres,
            hasMore: page.hasMoreDetail
        )
        let tracks = Self.appendBounded(
            current.tracks.tracks,
            page.tracks.tracks,
            hasMore: page.tracks.hasMore
        )
        let detail = LibraryArtistDetail(
            ownedAlbums: ownedAlbums.items,
            appearingAlbums: appearingAlbums.items,
            genres: genres.items
        )
        content = .artists(
            entries: entries,
            detail: LibraryArtistDetailPage(
                detail: detail,
                tracks: LibraryTrackPage(
                    tracks: tracks.items,
                    offset: 0,
                    limit: page.tracks.limit,
                    hasMore: tracks.hasMore
                ),
                detailOffset: page.detailOffset,
                detailLimit: page.detailLimit,
                hasMoreDetail: page.hasMoreDetail
                    && (ownedAlbums.hasMore || appearingAlbums.hasMore || genres.hasMore)
            )
        )
        return true
    }

    @discardableResult
    mutating func appendDetailTracks(_ page: LibraryTrackPage, kind: FacetTracksPageViewController.Kind) -> Bool {
        switch kind {
        case .artists:
            return false
        case .albums:
            guard case let .albums(entries, current) = content,
                  page.offset == current.tracks.count else { return false }
            let appended = Self.appendBounded(current.tracks, page.tracks, hasMore: page.hasMore)
            content = .albums(
                entries: entries,
                tracks: LibraryTrackPage(
                    tracks: appended.items,
                    offset: 0,
                    limit: page.limit,
                    hasMore: appended.hasMore
                )
            )
            return true
        case .genres:
            guard case let .genres(entries, current) = content,
                  page.offset == current.tracks.count else { return false }
            let appended = Self.appendBounded(current.tracks, page.tracks, hasMore: page.hasMore)
            content = .genres(
                entries: entries,
                tracks: LibraryTrackPage(
                    tracks: appended.items,
                    offset: 0,
                    limit: page.limit,
                    hasMore: appended.hasMore
                )
            )
            return true
        }
    }

    @discardableResult
    mutating func selectFacet(at index: Int, kind: FacetTracksPageViewController.Kind) -> Bool {
        switch kind {
        case .artists where artistEntries.indices.contains(index):
            selectedArtist = artistEntries[index].name
        case .albums where albumEntries.indices.contains(index):
            selectedAlbum = albumEntries[index].key
        case .genres where genreEntries.indices.contains(index):
            selectedGenre = genreEntries[index].name
        default:
            return false
        }
        return true
    }

    mutating func clearContent() {
        content = .empty
    }

    mutating func selectAlbum(_ key: AlbumKey) {
        selectedAlbum = key
    }

    mutating func selectArtist(_ artist: String) {
        selectedArtist = artist
    }

    mutating func selectGenre(_ genre: String) {
        selectedGenre = genre
    }
}
