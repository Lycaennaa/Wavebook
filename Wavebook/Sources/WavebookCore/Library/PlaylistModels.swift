import Foundation

/// Persisted user-playlist kind.
public enum PlaylistKind: String, CaseIterable, Codable, Hashable, Sendable {
    /// A manually ordered playlist.
    case manual
    /// A rule-based playlist resolved from the current catalog.
    case smart
}

/// Field used to order smart-playlist results.
public enum PlaylistSortField: String, CaseIterable, Codable, Hashable, Sendable {
    /// Album title.
    case album
    /// Best-known first-seen date.
    case firstSeen
    /// Qualified listening count.
    case qualifiedPlays
    /// Track duration.
    case duration
}

/// Kind-specific persisted state for a user playlist.
public enum PlaylistDefinition: Hashable, Sendable {
    /// A manually ordered playlist.
    case manual
    /// A rule-based playlist with its ordering configuration.
    case smart(rulesJSON: String, sortField: PlaylistSortField, sortDescending: Bool)

    /// Stored playlist kind.
    public var kind: PlaylistKind {
        switch self {
        case .manual:
            return .manual
        case .smart:
            return .smart
        }
    }

    /// Stored smart-playlist rules, when applicable.
    public var rulesJSON: String? {
        guard case let .smart(rulesJSON, _, _) = self else { return nil }
        return rulesJSON
    }

    /// Stored smart-playlist sort field, when applicable.
    public var sortField: PlaylistSortField? {
        guard case let .smart(_, sortField, _) = self else { return nil }
        return sortField
    }

    /// Stored smart-playlist direction, or ascending for manual playlists.
    public var sortDescending: Bool {
        guard case let .smart(_, _, sortDescending) = self else { return false }
        return sortDescending
    }

}

/// A persisted user playlist.
public struct Playlist: Identifiable, Hashable, Sendable {
    /// Database identifier.
    public let id: Int64
    /// User-visible playlist name.
    public let name: String
    /// UTC creation time.
    public let createdAtUTC: Date
    /// Kind-specific playlist state.
    public let definition: PlaylistDefinition

    /// Persisted playlist kind.
    public var kind: PlaylistKind { definition.kind }
    /// Persisted smart-playlist rules, when applicable.
    public var rulesJSON: String? { definition.rulesJSON }
    /// Persisted smart-playlist sort field, when applicable.
    public var sortField: PlaylistSortField? { definition.sortField }
    /// Persisted smart-playlist direction, or ascending for manual playlists.
    public var sortDescending: Bool { definition.sortDescending }

    /// Creates a playlist read model from kind-specific state.
    public init(
        id: Int64,
        name: String,
        createdAtUTC: Date,
        definition: PlaylistDefinition
    ) {
        self.id = id
        self.name = name
        self.createdAtUTC = createdAtUTC
        self.definition = definition
    }
}

/// Metadata retained for a playlist item when its catalog track is unavailable.
public struct PlaylistItemSnapshot: Codable, Hashable, Sendable {
    /// Original file path.
    public let path: String
    /// Track title at insertion time.
    public let title: String
    /// Displayed artist at insertion time.
    public let artistDisplay: String
    /// Album title at insertion time.
    public let albumTitle: String
    /// Genre display at insertion time.
    public let genreDisplay: String
    /// Duration at insertion time.
    public let duration: TimeInterval
    /// Audio format at insertion time.
    public let format: String

    /// Creates retained playlist-item metadata.
    public init(
        path: String,
        title: String,
        artistDisplay: String,
        albumTitle: String,
        genreDisplay: String = "",
        duration: TimeInterval = 0,
        format: String = ""
    ) {
        self.path = path
        self.title = title
        self.artistDisplay = artistDisplay
        self.albumTitle = albumTitle
        self.genreDisplay = genreDisplay
        self.duration = duration
        self.format = format
    }
}

/// One ordered playlist row with optional live catalog data.
public struct PlaylistItem: Identifiable, Hashable, Sendable {
    /// Database identifier. Duplicate tracks have different item identifiers.
    public let id: Int64
    /// Owning playlist identifier.
    public let playlistID: Int64
    /// Zero-based playlist position.
    public let ordinal: Int
    /// Volume or device scope for the source resource identifier.
    public let sourceVolumeIdentifier: String?
    /// Source filesystem resource identifier.
    public let sourceResourceIdentifier: String?
    /// Current catalog track, if available.
    public let track: Track?
    /// Metadata retained independently of catalog availability.
    public let snapshot: PlaylistItemSnapshot

    /// Whether this row currently resolves to a live catalog track.
    public var isAvailable: Bool { track != nil }

    /// Creates a playlist-item read model.
    public init(
        id: Int64,
        playlistID: Int64,
        ordinal: Int,
        sourceVolumeIdentifier: String? = nil,
        sourceResourceIdentifier: String? = nil,
        track: Track?,
        snapshot: PlaylistItemSnapshot
    ) {
        self.id = id
        self.playlistID = playlistID
        self.ordinal = ordinal
        self.sourceVolumeIdentifier = sourceVolumeIdentifier
        self.sourceResourceIdentifier = sourceResourceIdentifier
        self.track = track
        self.snapshot = snapshot
    }
}

/// A page of ordered playlist items.
public typealias LibraryPlaylistItemPage = LibraryCatalogPage<PlaylistItem>
/// A page of live tracks resolved from a smart or system playlist.
public typealias LibraryPlaylistTrackPage = LibraryCatalogPage<Track>

public extension PlaylistItem {
    /// Current title, or preserved title when unavailable.
    var displayTitle: String { track?.title ?? snapshot.title }
    /// Current artist, or preserved artist when unavailable.
    var displayArtist: String { track?.artistDisplay ?? snapshot.artistDisplay }
}
