import Foundation

/// A playback sample used by listening-history tracking.
public struct ListeningPlaybackSample: Equatable, Sendable {
    /// Rendered playback position in seconds.
    public let renderedPosition: TimeInterval
    /// Whether playback was active when sampled.
    public let isPlaying: Bool
    /// UTC time at which the sample was observed.
    public let observedAtUTC: Date
    /// Local UTC offset in seconds at observation time.
    public let utcOffsetSeconds: Int

    /// Creates a sample when its time and position are valid.
    public init?(
        renderedPosition: TimeInterval,
        isPlaying: Bool,
        observedAtUTC: Date,
        utcOffsetSeconds: Int? = nil
    ) {
        guard renderedPosition.isFinite,
              observedAtUTC.timeIntervalSinceReferenceDate.isFinite else {
            return nil
        }
        let offset = utcOffsetSeconds ?? TimeZone.current.secondsFromGMT(for: observedAtUTC)
        guard TimeZone(secondsFromGMT: offset) != nil else { return nil }
        self.renderedPosition = max(renderedPosition, 0)
        self.isPlaying = isPlaying
        self.observedAtUTC = observedAtUTC
        self.utcOffsetSeconds = offset
    }
}

/// Result of attempting to start listening-history tracking.
public enum ListeningTrackingStartResult: Equatable, Sendable {
    /// A new event was started.
    case started(UUID)
    /// Tracking is disabled by private mode.
    case privateMode
    /// The pending-mutation limit rejected the event.
    case rejectedPendingLimit
    /// Event metadata was invalid.
    case rejectedInvalidMetadata
    /// The history generation is stale.
    case staleGeneration
    /// Another event is already active.
    case activeSessionExists
}

/// Coordinates playback sampling and listening-history persistence.
@MainActor public final class ListeningHistoryTracker: NSObject {
    /// Produces the latest playback sample for tracking.
    public typealias SampleProvider = @MainActor () -> ListeningPlaybackSample?

    /// Default interval between playback samples.
    public static let defaultSamplingInterval: TimeInterval = 0.5
    /// Interval between durable listening-history checkpoints.
    public static let checkpointInterval: TimeInterval = 15
    /// Maximum number of pending listening sessions.
    public static let maximumPendingSessions = MutationPersistenceState.maximumPendingSessions
    /// Maximum serialized size of pending listening mutations.
    public static let maximumPendingSerializedBytes = MutationPersistenceState.maximumPendingSerializedBytes
    /// Maximum number of day slices retained for one session.
    public static let maximumDaySlices = MutationPersistenceState.maximumDaySlices
    static let terminationFlushTimeout: TimeInterval = 2
    static let terminationFlushRetryInterval: TimeInterval = 0.1
    static let terminationFlushMaximumAttempts = 20

    let database: LibraryDatabase
    let samplingInterval: TimeInterval
    let clock: @MainActor () -> Date
    let monotonicClock: @MainActor () -> TimeInterval
    nonisolated(unsafe) var samplingTimer: Timer?
    nonisolated(unsafe) var persistenceRetryTimer: Timer?
    var sampleProvider: SampleProvider
    var valueState = ValueState()
    var terminationFlushCompletion: (@MainActor (Bool) -> Void)?
    var terminationFlushDeadlineUptime: TimeInterval?
    var terminationFlushAttempt = 0

    /// Current listening-history generation.
    public var historyGeneration: Int64 { valueState.history.generation }
    /// UTC time at which tracking started.
    public var trackingStartedAtUTC: Date { valueState.history.trackingStartedAtUTC }
    /// Whether private mode is enabled.
    public var isPrivateMode: Bool { valueState.history.isPrivate }
    /// Current persistence warning, if any.
    public var persistenceWarning: String? { valueState.persistence.warning }

    /// Reports a persistence error.
    public var onPersistenceError: ((String) -> Void)?
    /// Reports changes to the persistence warning.
    public var onPersistenceWarningChanged: ((String?) -> Void)?

    /// Identifier of the active listening event, if any.
    public var activeEventID: UUID? { valueState.activeSession?.eventID }
    /// Number of pending persistence mutations.
    public var pendingMutationCount: Int { valueState.persistence.pendingMutationCount }
    /// Whether persistence can currently accept writes.
    public var isPersistenceHealthy: Bool { valueState.persistence.isHealthy }
    /// Whether new listening sessions can be accepted.
    public var acceptsNewSessions: Bool {
        valueState.persistence.acceptsNewSession()
    }

    /// Creates a listening-history tracker.
    public init(
        database: LibraryDatabase,
        sampleProvider: @escaping SampleProvider = { nil },
        samplingInterval: TimeInterval = 0.5,
        clock: @escaping @MainActor () -> Date = { Date() },
        monotonicClock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.database = database
        self.sampleProvider = sampleProvider
        self.samplingInterval = samplingInterval.isFinite && samplingInterval > 0
            ? min(samplingInterval, Self.checkpointInterval)
            : Self.defaultSamplingInterval
        self.clock = clock
        self.monotonicClock = monotonicClock
        super.init()

        do {
            valueState.history = try database.listeningHistoryState()
            do {
                let result = try database.recoverAbandonedListeningEvents(expectedGeneration: historyGeneration)
                if case .staleGeneration = result {
                    valueState.persistence.beginRecovery(atUptime: normalizedMonotonicTime(nil))
                    setPersistenceWarning("Listening history recovery is waiting for a stable history generation.")
                    schedulePersistenceRetryTimer()
                }
            } catch {
                valueState.persistence.beginRecovery(atUptime: normalizedMonotonicTime(nil))
                reportPersistenceFailure(error)
                schedulePersistenceRetryTimer()
            }
        } catch {
            valueState.persistence.beginRecovery(atUptime: normalizedMonotonicTime(nil))
            reportPersistenceFailure(error)
            schedulePersistenceRetryTimer()
        }
    }

    deinit {
        samplingTimer?.invalidate()
        persistenceRetryTimer?.invalidate()
    }

}
