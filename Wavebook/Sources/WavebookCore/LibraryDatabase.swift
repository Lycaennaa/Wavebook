import Foundation
import GRDB

/// A library root tracked by the database.
public struct LibraryRoot: Identifiable, Hashable, Sendable {
    /// Database identifier.
    public var id: Int64
    /// Canonical root path.
    public var path: String
    /// UTC time of the last scan.
    public var lastScanAt: Date?

    /// URL for the library root.
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// Aggregate counts for one library name.
public struct LibraryNameSummary: Hashable, Sendable {
    /// Displayed name.
    public var name: String
    /// Number of tracks.
    public var trackCount: Int
    /// Number of albums.
    public var albumCount: Int
    /// Number of artists.
    public var artistCount: Int
    /// Number of appearances.
    public var appearanceCount: Int

    /// Creates a library-name summary.
    public init(
        name: String,
        trackCount: Int,
        albumCount: Int = 0,
        artistCount: Int = 0,
        appearanceCount: Int = 0
    ) {
        self.name = name
        self.trackCount = trackCount
        self.albumCount = albumCount
        self.artistCount = artistCount
        self.appearanceCount = appearanceCount
    }
}

/// Aggregate counts for one library album.
public struct LibraryAlbumSummary: Hashable, Sendable {
    /// Album identity.
    public var key: AlbumKey
    /// Number of tracks.
    public var trackCount: Int
    /// Path used to load artwork.
    public var artworkTrackPath: String

    /// Creates a library-album summary.
    public init(key: AlbumKey, trackCount: Int, artworkTrackPath: String = "") {
        self.key = key
        self.trackCount = trackCount
        self.artworkTrackPath = artworkTrackPath
    }
}

/// Album summary within an artist detail result.
public struct LibraryArtistAlbumSummary: Hashable, Sendable {
    /// Album identity.
    public var key: AlbumKey
    /// Number of tracks.
    public var trackCount: Int
    /// Path used to load artwork.
    public var artworkTrackPath: String

    /// Creates an artist-album summary.
    public init(key: AlbumKey, trackCount: Int, artworkTrackPath: String) {
        self.key = key
        self.trackCount = trackCount
        self.artworkTrackPath = artworkTrackPath
    }
}

/// Album and genre information for an artist.
public struct LibraryArtistDetail: Hashable, Sendable {
    /// Albums owned by the artist.
    public var ownedAlbums: [LibraryArtistAlbumSummary]
    /// Albums on which the artist appears.
    public var appearingAlbums: [LibraryArtistAlbumSummary]
    /// Genres associated with the artist.
    public var genres: [String]

    /// Creates artist detail information.
    public init(
        ownedAlbums: [LibraryArtistAlbumSummary],
        appearingAlbums: [LibraryArtistAlbumSummary],
        genres: [String]
    ) {
        self.ownedAlbums = ownedAlbums
        self.appearingAlbums = appearingAlbums
        self.genres = genres
    }
}

/// A page of library tracks.
public struct LibraryTrackPage: Hashable, Sendable {
    /// Tracks on this page.
    public let tracks: [Track]
    /// Zero-based offset of the first track.
    public let offset: Int
    /// Maximum number of tracks requested.
    public let limit: Int
    /// Whether another page is available.
    public let hasMore: Bool

    /// Creates a track page.
    public init(tracks: [Track], offset: Int, limit: Int, hasMore: Bool) {
        self.tracks = tracks
        self.offset = offset
        self.limit = limit
        self.hasMore = hasMore
    }
}

/// Database access for library catalog and listening history.
public final class LibraryDatabase: @unchecked Sendable {
    static let replayGainAlbumFailureMarker = "[Album] "
    let writer: any DatabaseWriter
    let catalogFacetSnapshotStore = CatalogFacetSnapshotStore()
    /// Opens or creates a library database at a path.
    public init(path: String) throws {
        writer = try DatabaseQueue(path: path)
        try writer.write { database in
            try Self.createSchema(db: database)
        }
        try prepareReplayGainQueue()
    }

    /// Creates an in-memory library database for isolated use.
    public init(inMemory: Bool) throws {
        guard inMemory else { throw LibraryDatabaseError.inMemoryRequired }
        writer = try DatabaseQueue()
        try writer.write { database in
            try Self.createSchema(db: database)
        }
        try prepareReplayGainQueue()
    }

    static let trackSelection = """
    tracks.*, EXISTS (
        SELECT 1 FROM lyricFiles WHERE lyricFiles.lyricsKey = tracks.lyricsKey
    ) AS hasLyrics
    """
}

/// Errors raised by library database operations.
public enum LibraryDatabaseError: Error, Equatable, Sendable, LocalizedError {
    /// An in-memory database was required.
    case inMemoryRequired
    /// The database schema version is unsupported.
    case unsupportedSchemaVersion(Int)
    /// The schema is invalid.
    case invalidSchema(String)
    /// A requested root is missing.
    case missingRoot(String)
    /// A root overlaps an existing root.
    case overlappingRoot(String, existingPath: String)
    /// A path is outside its root.
    case pathOutsideRoot(String, rootPath: String)
    /// A requested track is missing.
    case missingTrack(String)
    /// A user-playlist name is empty or not trimmed.
    case invalidPlaylistName
    /// A user-playlist name is reserved for a system playlist.
    case reservedPlaylistName(String)
    /// A user-playlist name is already in use.
    case duplicatePlaylistName(String)
    /// A persisted or requested playlist definition is invalid.
    case invalidPlaylistDefinition(String)
    /// A smart-playlist rule list violates the supported grammar.
    case invalidSmartPlaylistRules(PlaylistRuleValidationError)
    /// A playlist identifier does not exist.
    case missingPlaylist(Int64)
    /// An operation requires a different playlist kind.
    case playlistKindMismatch(Int64)
    /// A playlist item identifier does not exist.
    case missingPlaylistItem(Int64)
    /// A playlist item ordinal is invalid.
    case invalidPlaylistOrdinal(Int)
    /// A playlist item row is invalid.
    case invalidPlaylistItem
    /// A catalog write referenced a stale track identifier.
    case staleTrackID(Int64)
    /// A catalog write supplied an identity that conflicts with the stored track.
    case conflictingTrackIdentity(String)
    /// Too many tracks were supplied.
    case tooManyTracks(limit: Int)
    /// Too many lyric files were supplied.
    case tooManyLyricFiles(limit: Int)
    /// A listening snapshot is invalid.
    case invalidListeningSnapshot
    /// A listening event is invalid.
    case invalidListeningEvent
    /// A listening occurrence is invalid.
    case invalidListeningOccurrence
    /// A listening event identifier collided.
    case listeningEventIDCollision(UUID)
    /// A listening event was already finished.
    case listeningEventAlreadyFinished(UUID)
    /// A listening event is missing.
    case missingListeningEvent(UUID)
    /// A listening year is invalid.
    case invalidListeningYear(Int)
    /// A listening day is invalid.
    case invalidListeningDay(String)
    /// Private listening history blocked the operation.
    case privateListeningHistory
    /// A listening generation is stale.
    case staleListeningGeneration(Int64)
    /// A skip segment is invalid.
    case invalidSkipSegment(String)

    /// Human-readable database error text when available.
    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            return "Unsupported library schema version \(version)."
        case let .invalidSchema(reason):
            return "Invalid library schema: \(reason)."
        case let .invalidSkipSegment(reason):
            return "Invalid skip segment: \(reason)."
        case let .staleTrackID(trackID):
            return "Catalog track \(trackID) is stale."
        case let .conflictingTrackIdentity(path):
            return "Catalog track identity conflicts at \(path)."
        case .invalidPlaylistName:
            return "Playlist name must not be empty and must be trimmed."
        case let .reservedPlaylistName(name):
            return "Playlist name \(name) is reserved for a system playlist."
        case let .duplicatePlaylistName(name):
            return "A playlist named \(name) already exists."
        case let .invalidPlaylistDefinition(reason):
            return "Invalid playlist definition: \(reason)."
        case let .invalidSmartPlaylistRules(error):
            return error.localizedDescription
        case let .missingPlaylist(id):
            return "Playlist \(id) does not exist."
        case let .playlistKindMismatch(id):
            return "Playlist \(id) has the wrong kind for this operation."
        case let .missingPlaylistItem(id):
            return "Playlist item \(id) does not exist."
        case let .invalidPlaylistOrdinal(ordinal):
            return "Playlist ordinal \(ordinal) is invalid."
        case .invalidPlaylistItem:
            return "The playlist item could not be persisted."
        default:
            return nil
        }
    }
}
