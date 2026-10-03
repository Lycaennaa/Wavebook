import Foundation

/// The result of adding selected tracks to a manual playlist.
public struct PlaylistAddTracksResult: Equatable, Hashable, Sendable {
    /// Newly inserted playlist-item identifiers in selection order.
    public let itemIDs: [Int64]
    /// Selected track IDs already represented by an existing item.
    public let duplicateTrackIDs: [Int64]
    /// Whether this operation consumed the one-time duplicate warning.
    public let shouldWarnAboutDuplicates: Bool

    /// Creates an add result.
    public init(itemIDs: [Int64], duplicateTrackIDs: [Int64], shouldWarnAboutDuplicates: Bool) {
        self.itemIDs = itemIDs
        self.duplicateTrackIDs = duplicateTrackIDs
        self.shouldWarnAboutDuplicates = shouldWarnAboutDuplicates
    }
}

/// One favorite state change from an atomic batch.
public struct PlaylistFavoriteChange: Equatable, Hashable, Sendable {
    /// Live track identifier.
    public let trackID: Int64
    /// Resulting favorite state.
    public let isFavorite: Bool

    /// Creates a favorite change.
    public init(trackID: Int64, isFavorite: Bool) {
        self.trackID = trackID
        self.isFavorite = isFavorite
    }
}
