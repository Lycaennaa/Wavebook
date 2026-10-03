import Foundation

struct SliceKey: Hashable {
    let localDay: ListeningLocalDay
    let utcOffsetSeconds: Int
}

struct PlaybackContext {
    let track: Track
    let openedDuration: TimeInterval
    let openedFormat: String
    let source: ListeningPlaybackSource
    var renderedPosition: TimeInterval
    var isPlaying: Bool
    var sessionToken = UUID()
}

struct ActiveSession {
    let eventID: UUID
    let generation: Int64
    let snapshot: ListeningMediaSnapshot
    var snapshotID: Int64?
    let source: ListeningPlaybackSource
    let startedAtUTC: Date
    let startedUTCOffsetSeconds: Int
    let startPosition: TimeInterval
    var lastRenderedPosition: TimeInterval
    var lastSampleAtUTC: Date
    var lastSampleUTCOffsetSeconds: Int
    var isPlaying: Bool
    var qualification: ListeningQualificationState
    var qualificationOccurrence: ListeningEventOccurrence?
    var listenedSeconds: TimeInterval
    var daySlices: [SliceKey: TimeInterval]
    var durableDaySliceKeys: Set<SliceKey>
    var daySliceOverflowed: Bool
    var checkpointSequence: Int64
    var nextCheckpointUptime: TimeInterval
}

struct SampleResult {
    let didProgress: Bool
    let didQualify: Bool
}

struct ValueState {
    var history = ListeningHistoryState(
        generation: 0,
        trackingStartedAtUTC: Date(),
        isPrivate: false
    )
    var activeSession: ActiveSession?
    var playbackContext: PlaybackContext?
    var persistence = MutationPersistenceState()
    private var seekPreparedEventID: UUID?
    private var seekPreparedSessionToken: UUID?

    mutating func prepareForHistoryReset(playbackContext: PlaybackContext?) {
        activeSession = nil
        self.playbackContext = playbackContext
        persistence.reset()
        seekPreparedEventID = nil
        seekPreparedSessionToken = nil
    }

    mutating func prepareSeek(eventID: UUID, sessionToken: UUID?) {
        seekPreparedEventID = eventID
        seekPreparedSessionToken = sessionToken
    }

    var hasSeekPreparation: Bool {
        seekPreparedEventID != nil || seekPreparedSessionToken != nil
    }

    func isSeekPrepared(eventID: UUID, sessionToken: UUID?) -> Bool {
        seekPreparedEventID == eventID && seekPreparedSessionToken == sessionToken
    }

    mutating func clearSeekPreparation() {
        seekPreparedEventID = nil
        seekPreparedSessionToken = nil
    }

    var requiresSampling: Bool {
        activeSession != nil || persistence.requiresSampling
    }
}
