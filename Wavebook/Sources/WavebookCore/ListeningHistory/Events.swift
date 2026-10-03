import Foundation

/// Listening time attributed to one local calendar day.
public struct ListeningDaySlice: Equatable, Hashable, Sendable {
    /// Event to which the slice belongs.
    public let eventID: UUID
    /// Local calendar day containing the listening time.
    public let localDay: ListeningLocalDay
    /// UTC offset in seconds for the local day.
    public let utcOffsetSeconds: Int
    /// Listening time attributed to the day.
    public let actualListenedSeconds: TimeInterval
    /// Whether the input listening time was valid.
    public let isValid: Bool

    /// Creates a day slice from a typed local day.
    public init(
        eventID: UUID,
        localDay: ListeningLocalDay,
        utcOffsetSeconds: Int,
        actualListenedSeconds: TimeInterval
    ) {
        self.eventID = eventID
        self.localDay = localDay
        self.utcOffsetSeconds = utcOffsetSeconds
        self.isValid = actualListenedSeconds.isFinite && actualListenedSeconds >= 0
        self.actualListenedSeconds = isValid && actualListenedSeconds > 0 ? actualListenedSeconds : 0
    }

    /// Creates a day slice from a YYYY-MM-DD local-day string.
    public init?(
        eventID: UUID,
        localDay: String,
        utcOffsetSeconds: Int,
        actualListenedSeconds: TimeInterval
    ) {
        guard let localDay = ListeningLocalDay(localDay) else { return nil }
        self.init(
            eventID: eventID,
            localDay: localDay,
            utcOffsetSeconds: utcOffsetSeconds,
            actualListenedSeconds: actualListenedSeconds
        )
    }
}

/// Current listening-history state.
public struct ListeningHistoryState: Equatable, Sendable {
    /// Current history generation.
    public let generation: Int64
    /// UTC time at which tracking began.
    public let trackingStartedAtUTC: Date
    /// Whether private mode is enabled.
    public let isPrivate: Bool

    /// Creates listening-history state.
    public init(generation: Int64, trackingStartedAtUTC: Date, isPrivate: Bool) {
        self.generation = max(generation, 0)
        self.trackingStartedAtUTC = trackingStartedAtUTC
        self.isPrivate = isPrivate
    }
}

/// Result of a listening-history mutation.
public enum ListeningHistoryMutationResult: Equatable, Sendable {
    /// The mutation was applied.
    case applied
    /// The mutation used an old history generation.
    case staleGeneration
    /// Private mode prevented the mutation.
    case privateMode
    /// The target event does not exist.
    case missingEvent
    /// The target event was already finished.
    case alreadyFinished
    /// The mutation used an old checkpoint sequence.
    case staleCheckpointSequence
}

/// Result of recovering abandoned listening events.
public enum ListeningHistoryRecoveryResult: Equatable, Sendable {
    /// Number of events finalized during recovery.
    case finalized(Int)
    /// Recovery used an old history generation.
    case staleGeneration

    /// Number of events finalized during recovery.
    public var finalizedCount: Int {
        if case let .finalized(count) = self { return count }
        return 0
    }
}

/// A validated qualification or skip occurrence.
public struct ListeningEventOccurrence: Equatable, Hashable, Sendable {
    /// UTC timestamp of the occurrence.
    public let timestampUTC: Date
    /// Local calendar day containing the occurrence.
    public let localDay: ListeningLocalDay
    /// UTC offset in seconds at the occurrence.
    public let utcOffsetSeconds: Int

    /// Creates an occurrence when its timestamp matches its local day.
    public init?(timestampUTC: Date, localDay: ListeningLocalDay, utcOffsetSeconds: Int) {
        guard
            timestampUTC.timeIntervalSinceReferenceDate.isFinite,
            let timeZone = TimeZone(secondsFromGMT: utcOffsetSeconds),
            ListeningLocalDay(date: timestampUTC, timeZone: timeZone) == localDay
        else {
            return nil
        }
        self.timestampUTC = timestampUTC
        self.localDay = localDay
        self.utcOffsetSeconds = utcOffsetSeconds
    }

    /// Creates an occurrence from a YYYY-MM-DD local-day string.
    public init?(timestampUTC: Date, localDay: String, utcOffsetSeconds: Int) {
        guard let localDay = ListeningLocalDay(localDay) else { return nil }
        self.init(timestampUTC: timestampUTC, localDay: localDay, utcOffsetSeconds: utcOffsetSeconds)
    }
}

/// A persisted listening event and its derived results.
public struct ListeningEvent: Identifiable, Equatable, Sendable {
    /// Event identifier.
    public let id: UUID
    /// History generation in which the event was created.
    public let historyGeneration: Int64
    /// Snapshot identifier associated with the event.
    public let snapshotID: Int64
    /// Playback source that created the event.
    public let source: ListeningPlaybackSource
    /// UTC time at which playback started.
    public let startedAtUTC: Date
    /// UTC offset in seconds at playback start.
    public let startedUTCOffsetSeconds: Int
    /// UTC time at which playback ended.
    public let endedAtUTC: Date?
    /// UTC offset in seconds at playback end.
    public let endedUTCOffsetSeconds: Int?
    /// Playback position at the start of the event.
    public let startPosition: TimeInterval
    /// Playback position at the end of the event.
    public let endPosition: TimeInterval?
    /// UTC time of the last durable checkpoint.
    public let lastDurableCheckpointAtUTC: Date?
    /// UTC offset at the last durable checkpoint.
    public let lastDurableCheckpointUTCOffsetSeconds: Int?
    /// Sequence number of the last durable checkpoint.
    public let lastDurableCheckpointSequence: Int64?
    /// Reason the event ended.
    public let endReason: ListeningEventEndReason?
    /// Qualification occurrence, if any.
    public let qualification: ListeningEventOccurrence?
    /// Skip occurrence, if any.
    public let skip: ListeningEventOccurrence?
    /// Listening time attributed to each local day.
    public let daySlices: [ListeningDaySlice]

    /// Creates a listening event.
    public init(
        id: UUID,
        historyGeneration: Int64,
        snapshotID: Int64,
        source: ListeningPlaybackSource,
        startedAtUTC: Date,
        startedUTCOffsetSeconds: Int = 0,
        endedAtUTC: Date? = nil,
        endedUTCOffsetSeconds: Int? = nil,
        startPosition: TimeInterval = 0,
        endPosition: TimeInterval? = nil,
        lastDurableCheckpointAtUTC: Date? = nil,
        lastDurableCheckpointUTCOffsetSeconds: Int? = nil,
        lastDurableCheckpointSequence: Int64? = nil,
        endReason: ListeningEventEndReason? = nil,
        qualification: ListeningEventOccurrence? = nil,
        skip: ListeningEventOccurrence? = nil,
        daySlices: [ListeningDaySlice] = []
    ) {
        self.id = id
        self.historyGeneration = max(historyGeneration, 0)
        self.snapshotID = snapshotID
        self.source = source
        self.startedAtUTC = startedAtUTC
        self.startedUTCOffsetSeconds = startedUTCOffsetSeconds
        self.endedAtUTC = endedAtUTC
        self.endedUTCOffsetSeconds = endedUTCOffsetSeconds
        self.startPosition = max(startPosition.isFinite ? startPosition : 0, 0)
        self.endPosition = endPosition.map { max($0.isFinite ? $0 : 0, 0) }
        self.lastDurableCheckpointAtUTC = lastDurableCheckpointAtUTC
        self.lastDurableCheckpointUTCOffsetSeconds = lastDurableCheckpointUTCOffsetSeconds
        self.lastDurableCheckpointSequence = lastDurableCheckpointSequence
        self.endReason = endReason
        self.qualification = qualification
        self.skip = skip
        self.daySlices = daySlices
    }
}
