import Foundation

/// A bounded page of catalog values.
public struct LibraryCatalogPage<Item: Hashable & Sendable>: Hashable, Sendable {
    /// Items on this page.
    public let items: [Item]
    /// Zero-based offset of the first item.
    public let offset: Int
    /// Maximum number of items requested.
    public let limit: Int
    /// Whether another page is available.
    public let hasMore: Bool
    /// Total number of matching catalog values, when computed by the query.
    public let totalCount: Int?

    /// Creates a catalog page.
    public init(items: [Item], offset: Int, limit: Int, hasMore: Bool, totalCount: Int? = nil) {
        self.items = items
        self.offset = offset
        self.limit = limit
        self.hasMore = hasMore
        self.totalCount = totalCount
    }
}

/// A page of library-name summaries.
public typealias LibraryNamePage = LibraryCatalogPage<LibraryNameSummary>
/// A page of library-album summaries.
public typealias LibraryAlbumPage = LibraryCatalogPage<LibraryAlbumSummary>

/// Scope used for track queries.
public enum LibraryTrackScope: Hashable, Sendable {
    /// All tracks in the library.
    case all
    /// Tracks by artist name.
    case artist(String)
    /// Tracks by album key.
    case album(AlbumKey)
    /// Tracks by genre name.
    case genre(String)
}

/// A paged artist detail result.
public struct LibraryArtistDetailPage: Hashable, Sendable {
    /// Artist details for the page.
    public let detail: LibraryArtistDetail
    /// Tracks included in the page.
    public let tracks: LibraryTrackPage
    /// Offset used for artist details.
    public let detailOffset: Int
    /// Maximum number of artist details requested.
    public let detailLimit: Int
    /// Whether another detail page is available.
    public let hasMoreDetail: Bool

    /// Creates an artist detail page.
    public init(
        detail: LibraryArtistDetail,
        tracks: LibraryTrackPage,
        detailOffset: Int,
        detailLimit: Int,
        hasMoreDetail: Bool
    ) {
        self.detail = detail
        self.tracks = tracks
        self.detailOffset = detailOffset
        self.detailLimit = detailLimit
        self.hasMoreDetail = hasMoreDetail
    }

    /// Whether either detail or track results have another page.
    public var hasMore: Bool {
        hasMoreDetail || tracks.hasMore
    }
}

/// Database page-size defaults.
public extension LibraryDatabase {
    /// Default number of tracks requested per page.
    static let defaultTrackPageSize = 500
    /// Maximum number of tracks requested per page.
    static let maximumTrackPageSize = 1_000
}
