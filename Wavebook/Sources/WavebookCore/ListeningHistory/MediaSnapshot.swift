import Foundation

/// A normalized media snapshot stored with a listening event.
public struct ListeningMediaSnapshot: Identifiable, Codable, Equatable, Hashable, Sendable {
    /// Database identifier, if persisted.
    public let id: Int64?
    /// Live catalog track identifier, if still present.
    public let liveTrackID: Int64?
    /// Normalized track title.
    public let title: String
    /// Normalized displayed artist name.
    public let artistDisplay: String
    /// Normalized album title.
    public let albumTitle: String
    /// Normalized album owner.
    public let albumOwner: String
    /// Normalized genre display.
    public let genreDisplay: String
    /// Distinct normalized artists.
    public let artists: [String]
    /// Distinct normalized genres.
    public let genres: [String]
    /// Duration when the snapshot was opened.
    public let openedDuration: TimeInterval
    /// Audio format when the snapshot was opened.
    public let format: String
    /// UTC time at which the snapshot was created.
    public let createdAtUTC: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case liveTrackID
        case title
        case artistDisplay
        case albumTitle
        case albumOwner
        case genreDisplay
        case artists
        case genres
        case openedDuration
        case format
        case createdAtUTC
    }

    /// Decodes and validates a media snapshot.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let snapshot = ListeningMediaSnapshot(
            id: try container.decodeIfPresent(Int64.self, forKey: .id),
            liveTrackID: try container.decodeIfPresent(Int64.self, forKey: .liveTrackID),
            title: try container.decode(String.self, forKey: .title),
            artistDisplay: try container.decode(String.self, forKey: .artistDisplay),
            albumTitle: try container.decode(String.self, forKey: .albumTitle),
            albumOwner: try container.decodeIfPresent(String.self, forKey: .albumOwner),
            genreDisplay: try container.decode(String.self, forKey: .genreDisplay),
            artists: try container.decodeIfPresent([String].self, forKey: .artists),
            genres: try container.decodeIfPresent([String].self, forKey: .genres),
            openedDuration: try container.decode(TimeInterval.self, forKey: .openedDuration),
            format: try container.decode(String.self, forKey: .format),
            createdAtUTC: try container.decode(Date.self, forKey: .createdAtUTC)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .createdAtUTC,
                in: container,
                debugDescription: "invalid listening snapshot"
            )
        }
        self = snapshot
    }

    /// Creates and normalizes a media snapshot.
    public init?(
        id: Int64? = nil,
        liveTrackID: Int64? = nil,
        title: String = "",
        artistDisplay: String = "",
        albumTitle: String = "",
        albumOwner: String? = nil,
        genreDisplay: String = "",
        artists: [String]? = nil,
        genres: [String]? = nil,
        openedDuration: TimeInterval = 0,
        format: String = "",
        createdAtUTC: Date
    ) {
        guard createdAtUTC.timeIntervalSinceReferenceDate.isFinite else { return nil }

        let normalizedTitle = title.listeningTrimmed
        guard !normalizedTitle.isEmpty else { return nil }

        let normalizedArtistDisplay = artistDisplay.listeningTrimmed
        let normalizedAlbumTitle = albumTitle.listeningTrimmed
        let normalizedGenreDisplay = genreDisplay.listeningTrimmed
        let normalizedArtists = Self.normalizedDistinct(
            artists ?? MetadataParser.splitList(normalizedArtistDisplay)
        )
        let normalizedGenres = Self.normalizedDistinct(
            genres ?? MetadataParser.splitList(normalizedGenreDisplay)
        )

        self.id = id
        self.liveTrackID = liveTrackID
        self.title = normalizedTitle
        self.artistDisplay = normalizedArtistDisplay
        self.albumTitle = normalizedAlbumTitle
        self.albumOwner = albumOwner?.listeningTrimmedOrNil ?? normalizedArtists.first ?? ""
        self.genreDisplay = normalizedGenreDisplay
        self.artists = normalizedArtists
        self.genres = normalizedGenres
        self.openedDuration = openedDuration.isFinite && openedDuration > 0 ? openedDuration : 0
        self.format = format.listeningTrimmed
        self.createdAtUTC = createdAtUTC
    }

    /// Creates a media snapshot from a catalog track.
    public init?(
        id: Int64? = nil,
        liveTrackID: Int64?,
        track: Track,
        openedDuration: TimeInterval,
        openedFormat: String,
        createdAtUTC: Date
    ) {
        let trackTitle = track.title.listeningTrimmed
        let url = URL(fileURLWithPath: track.path)
        let stemTitle = url.deletingPathExtension().lastPathComponent.listeningTrimmed
        let fallbackTitle = stemTitle.isEmpty ? url.lastPathComponent.listeningTrimmed : stemTitle

        self.init(
            id: id,
            liveTrackID: liveTrackID,
            title: trackTitle.isEmpty ? fallbackTitle : trackTitle,
            artistDisplay: track.artistDisplay,
            albumTitle: track.albumTitle,
            albumOwner: track.albumArtist,
            genreDisplay: track.genreDisplay,
            artists: track.artists,
            genres: track.genres,
            openedDuration: openedDuration,
            format: openedFormat,
            createdAtUTC: createdAtUTC
        )
    }

    /// Album key derived from normalized album metadata.
    public var albumKey: AlbumKey? {
        guard !albumTitle.isEmpty else { return nil }
        return AlbumKey(title: albumTitle, owner: albumOwner)
    }

    /// Stable metadata signature for snapshot reuse.
    public var metadataSignature: String {
        var components = ["v1"]
        components.append(contentsOf: [
            "title", Self.signatureValue(title),
            "artistDisplay", Self.signatureValue(artistDisplay),
            "albumTitle", Self.signatureValue(albumTitle),
            "albumOwner", Self.signatureValue(albumOwner),
            "genreDisplay", Self.signatureValue(genreDisplay),
            "format", Self.signatureValue(format),
            "durationBits", String(openedDuration.bitPattern, radix: 16),
            "artists", String(artists.count)
        ])
        components.append(contentsOf: artists.map(Self.signatureValue))
        components.append("genres")
        components.append(String(genres.count))
        components.append(contentsOf: genres.map(Self.signatureValue))
        return components.joined(separator: ":")
    }

    private static func normalizedDistinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = value.listeningTrimmed
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private static func signatureValue(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }
}
