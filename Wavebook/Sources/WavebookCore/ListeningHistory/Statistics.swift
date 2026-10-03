import Foundation

/// Health summary for persisted listening history.
public struct ListeningHistoryHealth: Equatable, Sendable {
    /// Current history state.
    public let state: ListeningHistoryState
    /// Number of open events.
    public let openEventCount: Int
    /// Total number of events.
    public let eventCount: Int
    /// Number of media snapshots.
    public let snapshotCount: Int

    /// Creates a listening-history health summary.
    public init(
        state: ListeningHistoryState,
        openEventCount: Int = 0,
        eventCount: Int = 0,
        snapshotCount: Int = 0
    ) {
        self.state = state
        self.openEventCount = max(openEventCount, 0)
        self.eventCount = max(eventCount, 0)
        self.snapshotCount = max(snapshotCount, 0)
    }
}

/// Cursor for a qualified-play timeline page.
public struct ListeningTimelineCursor: Codable, Equatable, Hashable, Sendable {
    /// UTC time of the qualified event.
    public let qualifiedAtUTC: Date
    /// Identifier of the qualified event.
    public let eventID: UUID

    /// Creates a cursor when its timestamp is finite.
    public init?(qualifiedAtUTC: Date, eventID: UUID) {
        guard qualifiedAtUTC.timeIntervalSinceReferenceDate.isFinite else { return nil }
        self.qualifiedAtUTC = qualifiedAtUTC
        self.eventID = eventID
    }
}

/// One qualified-play timeline entry.
public struct ListeningQualifiedPlayTimelineEntry: Identifiable, Equatable, Sendable {
    /// Identifier of the listening event.
    public let eventID: UUID
    /// UTC time at which the play qualified.
    public let qualifiedAtUTC: Date
    /// Local day on which the play qualified.
    public let localDay: ListeningLocalDay
    /// UTC offset in seconds for the local day.
    public let utcOffsetSeconds: Int
    /// Snapshot associated with the play.
    public let snapshotID: Int64
    /// Track title.
    public let title: String
    /// Displayed artist name.
    public let artistDisplay: String
    /// Album title.
    public let albumTitle: String

    /// Stable identity for the timeline entry.
    public var id: UUID { eventID }

    /// Creates a timeline entry.
    public init(
        eventID: UUID,
        qualifiedAtUTC: Date,
        localDay: ListeningLocalDay,
        utcOffsetSeconds: Int,
        snapshotID: Int64,
        title: String = "",
        artistDisplay: String = "",
        albumTitle: String = ""
    ) {
        self.eventID = eventID
        self.qualifiedAtUTC = qualifiedAtUTC
        self.localDay = localDay
        self.utcOffsetSeconds = utcOffsetSeconds
        self.snapshotID = snapshotID
        self.title = title.listeningTrimmed
        self.artistDisplay = artistDisplay.listeningTrimmed
        self.albumTitle = albumTitle.listeningTrimmed
    }
}

/// A page of qualified-play timeline entries.
public struct ListeningQualifiedPlayTimelinePage: Equatable, Sendable {
    /// Entries on this page.
    public let entries: [ListeningQualifiedPlayTimelineEntry]
    /// Cursor for the next page, if available.
    public let nextCursor: ListeningTimelineCursor?

    /// Creates a qualified-play timeline page.
    public init(entries: [ListeningQualifiedPlayTimelineEntry], nextCursor: ListeningTimelineCursor? = nil) {
        self.entries = entries
        self.nextCursor = nextCursor
    }
}

/// Dimension used to rank listening statistics.
public enum ListeningStatisticsDimension: String, CaseIterable, Codable, Sendable {
    /// Individual songs.
    case song
    /// Albums.
    case album
    /// Artists.
    case artist
    /// Genres.
    case genre
}

/// Bucket used to display a listening heatmap day.
public enum ListeningHeatmapBucket: String, CaseIterable, Codable, Sendable {
    /// No qualified plays.
    case zero
    /// One qualified play.
    case one
    /// Two or three qualified plays.
    case twoToThree
    /// Four to seven qualified plays.
    case fourToSeven
    /// Eight or more qualified plays.
    case eightOrMore

    /// Creates a bucket from a qualified-play count.
    public init(playCount: Int) {
        switch max(playCount, 0) {
        case 0: self = .zero
        case 1: self = .one
        case 2...3: self = .twoToThree
        case 4...7: self = .fourToSeven
        default: self = .eightOrMore
        }
    }
}

/// Qualified-play count for one local day.
public struct ListeningHeatmapDay: Identifiable, Equatable, Hashable, Sendable {
    /// Local day represented by the entry.
    public let day: ListeningLocalDay
    /// Number of qualified plays on the day.
    public let qualifiedPlayCount: Int

    /// Creates a heatmap day.
    public init(day: ListeningLocalDay, qualifiedPlayCount: Int) {
        self.day = day
        self.qualifiedPlayCount = max(qualifiedPlayCount, 0)
    }

    /// Stable identity for the heatmap day.
    public var id: ListeningLocalDay { day }
    /// Display bucket for the qualified-play count.
    public var bucket: ListeningHeatmapBucket { ListeningHeatmapBucket(playCount: qualifiedPlayCount) }
}

/// Aggregate listening statistics.
public struct ListeningStatisticsSummary: Equatable, Hashable, Sendable {
    /// Number of qualified plays.
    public let qualifiedPlayCount: Int
    /// Total listened time in seconds.
    public let listenedSeconds: TimeInterval
    /// Number of unique songs.
    public let uniqueSongCount: Int
    /// Number of unique artists.
    public let uniqueArtistCount: Int
    /// Number of skips.
    public let skipCount: Int

    /// Creates an aggregate statistics summary.
    public init(
        qualifiedPlayCount: Int = 0,
        listenedSeconds: TimeInterval = 0,
        uniqueSongCount: Int = 0,
        uniqueArtistCount: Int = 0,
        skipCount: Int = 0
    ) {
        self.qualifiedPlayCount = max(qualifiedPlayCount, 0)
        self.listenedSeconds = listenedSeconds.isFinite && listenedSeconds > 0 ? listenedSeconds : 0
        self.uniqueSongCount = max(uniqueSongCount, 0)
        self.uniqueArtistCount = max(uniqueArtistCount, 0)
        self.skipCount = max(skipCount, 0)
    }
}

/// One rendered row of a statistics summary.
public enum ListeningStatisticsSummaryRenderRow: Equatable, Sendable {
    /// Qualified plays and listened time.
    case playsAndTime(qualifiedPlayCount: Int, listenedSeconds: TimeInterval)
    /// Unique songs, artists, and skips.
    case songsArtistsAndSkips(uniqueSongCount: Int, uniqueArtistCount: Int, skipCount: Int)
}

/// Render-ready statistics columns for year and lifetime totals.
public struct ListeningStatisticsSummaryRenderData: Equatable, Sendable {
    /// Statistics rows grouped by display column.
    public let columns: [[ListeningStatisticsSummaryRenderRow]]

    /// Creates render data from year and lifetime summaries.
    public init(year: ListeningStatisticsSummary, lifetime: ListeningStatisticsSummary) {
        columns = [Self.rows(for: year), Self.rows(for: lifetime)]
    }

    private static func rows(for summary: ListeningStatisticsSummary) -> [ListeningStatisticsSummaryRenderRow] {
        [
            .playsAndTime(
                qualifiedPlayCount: summary.qualifiedPlayCount,
                listenedSeconds: summary.listenedSeconds
            ),
            .songsArtistsAndSkips(
                uniqueSongCount: summary.uniqueSongCount,
                uniqueArtistCount: summary.uniqueArtistCount,
                skipCount: summary.skipCount
            )
        ]
    }
}

/// A ranked listening-statistics entry.
public struct ListeningRankingEntry: Identifiable, Equatable, Hashable, Sendable {
    /// Stable ranking identifier.
    public let id: String
    /// Ranking dimension.
    public let dimension: ListeningStatisticsDimension
    /// Display name.
    public let displayName: String
    /// Number of qualified plays.
    public let qualifiedPlayCount: Int
    /// Total listened time in seconds.
    public let listenedSeconds: TimeInterval

    /// Creates a ranking entry.
    public init(
        id: String,
        dimension: ListeningStatisticsDimension,
        displayName: String,
        qualifiedPlayCount: Int,
        listenedSeconds: TimeInterval
    ) {
        self.id = id
        self.dimension = dimension
        self.displayName = displayName.listeningTrimmed
        self.qualifiedPlayCount = max(qualifiedPlayCount, 0)
        self.listenedSeconds = listenedSeconds.isFinite && listenedSeconds > 0 ? listenedSeconds : 0
    }
}

/// A song ranked by skip count.
public struct ListeningSkippedSong: Identifiable, Equatable, Hashable, Sendable {
    /// Snapshot identifier.
    public let snapshotID: Int64
    /// Track title.
    public let title: String
    /// Displayed artist name.
    public let artistDisplay: String
    /// Album title.
    public let albumTitle: String
    /// Number of skips.
    public let skipCount: Int

    /// Creates a skipped-song entry.
    public init(
        snapshotID: Int64,
        title: String,
        artistDisplay: String,
        albumTitle: String,
        skipCount: Int
    ) {
        self.snapshotID = snapshotID
        self.title = title.listeningTrimmed
        self.artistDisplay = artistDisplay.listeningTrimmed
        self.albumTitle = albumTitle.listeningTrimmed
        self.skipCount = max(skipCount, 0)
    }

    /// Stable identity for the skipped song.
    public var id: Int64 { snapshotID }
}
