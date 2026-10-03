import Foundation

/// A catalog track.
public struct Track: Identifiable, Hashable, Sendable {
    /// Database identifier, if persisted.
    public var id: Int64?
    /// Canonical file path.
    public var path: String
    /// Track title.
    public var title: String
    /// Displayed artist name.
    public var artistDisplay: String
    /// Album title.
    public var albumTitle: String
    /// Album artist, if supplied.
    public var albumArtist: String?
    /// Displayed genre name.
    public var genreDisplay: String
    /// Track duration in seconds.
    public var duration: TimeInterval
    /// Audio format name.
    public var format: String
    /// Whether lyrics are available.
    public var hasLyrics: Bool
    /// Best-known UTC time at which the track was added to the catalog.
    public var firstSeenAtUTC: Date
    /// Filesystem resource identifier, when available.
    public var fileResourceIdentifier: String?
    /// Volume or device scope for the filesystem resource identifier.
    public var fileVolumeIdentifier: String?
    /// Whether the track is marked as a favorite.
    public var isFavorite: Bool

    /// Creates a catalog track.
    public init(
        id: Int64? = nil,
        path: String,
        title: String,
        artistDisplay: String,
        albumTitle: String,
        albumArtist: String? = nil,
        genreDisplay: String = "",
        duration: TimeInterval = 0,
        format: String = "",
        hasLyrics: Bool = false,
        firstSeenAtUTC: Date = Date(),
        fileResourceIdentifier: String? = nil,
        fileVolumeIdentifier: String? = nil,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.path = path
        self.title = title
        self.artistDisplay = artistDisplay
        self.albumTitle = albumTitle
        self.albumArtist = albumArtist
        self.genreDisplay = genreDisplay
        self.duration = duration
        self.format = format
        self.hasLyrics = hasLyrics
        self.firstSeenAtUTC = Self.normalizedFirstSeenAtUTC(firstSeenAtUTC)
        self.fileResourceIdentifier = fileResourceIdentifier
        self.fileVolumeIdentifier = fileVolumeIdentifier
        self.isFavorite = isFavorite
    }
    static func normalizedFirstSeenAtUTC(_ date: Date) -> Date {
        date.timeIntervalSinceReferenceDate.isFinite ? date : Date()
    }

    /// Individual artist names.
    public var artists: [String] {
        MetadataParser.splitList(artistDisplay)
    }

    /// Individual genre names.
    public var genres: [String] {
        MetadataParser.splitList(genreDisplay)
    }

    /// Canonical album identity.
    public var albumKey: AlbumKey {
        AlbumKey(title: albumTitle, owner: albumArtist?.nilIfBlank ?? artists.first ?? "")
    }

    /// Display subtitle built from artist, album, and genre metadata.
    public var subtitle: String {
        [artistDisplay, albumTitle, genreDisplay]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " • ")
    }
}

/// Additional track identity helpers.
public extension Track {
    /// Returns whether two tracks refer to the same catalog item.
    func hasSameIdentity(as other: Track) -> Bool {
        path == other.path || (id != nil && id == other.id)
    }
}

/// Canonical album title and owner.
public struct AlbumKey: Hashable, Sendable {
    /// Canonical album title.
    public var title: String
    /// Canonical album owner.
    public var owner: String

    /// Creates an album key from title and owner components.
    public init(title: String, owner: String) {
        self.title = Self.canonicalComponent(title)
        self.owner = Self.canonicalComponent(owner)
    }

    static func canonicalComponent(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
