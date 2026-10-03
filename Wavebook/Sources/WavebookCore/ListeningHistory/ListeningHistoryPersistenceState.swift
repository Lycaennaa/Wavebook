import Foundation

struct CheckpointPayload {
    let checkpointAtUTC: Date
    let renderedPosition: TimeInterval
    let checkpointUTCOffsetSeconds: Int
    let forceRebase: Bool
    let checkpointSequence: Int64
    let daySlices: [ListeningDaySlice]
    let qualification: ListeningEventOccurrence?
    let containsOverflow: Bool
}

struct FinishPayload {
    let endedAtUTC: Date
    let endedUTCOffsetSeconds: Int
    let endPosition: TimeInterval
    let endReason: ListeningEventEndReason
    let daySlices: [ListeningDaySlice]
    let qualification: ListeningEventOccurrence?
    let skip: ListeningEventOccurrence?
    let containsOverflow: Bool
}

enum PendingOperation {
    case begin
    case checkpoint(CheckpointPayload)
    case finish(FinishPayload)
}

struct PendingMutation {
    let eventID: UUID
    let expectedGeneration: Int64
    let snapshot: ListeningMediaSnapshot
    var snapshotID: Int64?
    let source: ListeningPlaybackSource
    let startedAtUTC: Date
    let startedUTCOffsetSeconds: Int
    let startPosition: TimeInterval
    var operation: PendingOperation
    var estimatedSerializedBytes: Int
}

enum AttemptResult {
    case committed
    case discarded
    case failed(Error)
}

struct MutationPersistenceState {
    enum EnqueueResult {
        case accepted
        case rejected
    }

    static let maximumPendingSessions = 64
    static let maximumPendingSerializedBytes = 1_048_576
    static let maximumDaySlices = 512
    static let maximumOperationOverhead = (maximumDaySlices * 96) + (3 * 96)
    private static let capacityWarning =
        "Listening history has reached its pending-write limit; "
        + "new sessions are not being tracked."

    private struct RetryState {
        private(set) var attempt = 0
        private(set) var dueAtUptime = 0.0

        mutating func schedule(atUptime: TimeInterval) {
            attempt = min(attempt + 1, 7)
            dueAtUptime = atUptime + min(pow(2, Double(attempt - 1)), 60)
        }

        mutating func reset() {
            self = RetryState()
        }
    }

    private struct RecoveryState {
        private(set) var isPending = false
        private var retry = RetryState()

        var retryDueAtUptime: TimeInterval { retry.dueAtUptime }

        mutating func begin(atUptime: TimeInterval) {
            isPending = true
            retry.schedule(atUptime: atUptime)
        }

        mutating func scheduleRetry(atUptime: TimeInterval) {
            retry.schedule(atUptime: atUptime)
        }

        mutating func reset() {
            self = RecoveryState()
        }
    }

    private var pendingMutations: [UUID: PendingMutation] = [:]
    private var pendingSerializedBytes = 0
    private var retry = RetryState()
    private var recovery = RecoveryState()
    private(set) var capacityBlocked = false
    private(set) var warning: String?
    private var lastDiscardedEventID: UUID?

    var pendingMutationCount: Int { pendingMutations.count }
    var hasPendingMutations: Bool { !pendingMutations.isEmpty }
    var retryAtUptime: TimeInterval { retry.dueAtUptime }
    var recoveryPending: Bool { recovery.isPending }
    var recoveryRetryAtUptime: TimeInterval { recovery.retryDueAtUptime }
    var isHealthy: Bool {
        warning == nil && pendingMutations.isEmpty && !recovery.isPending
    }
    var requiresSampling: Bool {
        !pendingMutations.isEmpty || recovery.isPending
    }

    func pendingMutation(for eventID: UUID) -> PendingMutation? {
        pendingMutations[eventID]
    }

    func hasPendingMutation(for eventID: UUID) -> Bool {
        pendingMutations[eventID] != nil
    }

    func pendingEventIDs() -> [UUID] {
        pendingMutations.keys.sorted { $0.uuidString < $1.uuidString }
    }

    func eventIDs(fromOtherThan generation: Int64) -> [UUID] {
        pendingMutations.values
            .filter { $0.expectedGeneration != generation }
            .map(\.eventID)
    }

    func acceptsNewSession() -> Bool {
        !recovery.isPending
            && !capacityBlocked
            && pendingMutations.count < Self.maximumPendingSessions
            && pendingSerializedBytes < Self.maximumPendingSerializedBytes
    }

    func canEnqueueNewMutation(_ mutation: PendingMutation) -> Bool {
        !recovery.isPending
            && !capacityBlocked
            && pendingMutations.count < Self.maximumPendingSessions
            && mutation.estimatedSerializedBytes <= Self.maximumPendingSerializedBytes
            && pendingSerializedBytes + mutation.estimatedSerializedBytes <= Self.maximumPendingSerializedBytes
    }

    func estimatedSerializedBytes(for mutation: PendingMutation) -> Int {
        var bytes = 256
        bytes += mutation.snapshot.title.utf8.count
        bytes += mutation.snapshot.artistDisplay.utf8.count
        bytes += mutation.snapshot.albumTitle.utf8.count
        bytes += mutation.snapshot.albumOwner.utf8.count
        bytes += mutation.snapshot.genreDisplay.utf8.count
        bytes += mutation.snapshot.format.utf8.count
        bytes += mutation.snapshot.artists.reduce(0) { $0 + $1.utf8.count }
        bytes += mutation.snapshot.genres.reduce(0) { $0 + $1.utf8.count }
        bytes += mutation.source.sourceName?.utf8.count ?? 0
        let operationBytes: Int
        switch mutation.operation {
        case .begin:
            operationBytes = 0
        case let .checkpoint(payload):
            let sliceBytes = min(payload.daySlices.count, Self.maximumDaySlices) * 96
            operationBytes = sliceBytes + (payload.qualification == nil ? 0 : 96)
        case let .finish(payload):
            let sliceBytes = min(payload.daySlices.count, Self.maximumDaySlices) * 96
            operationBytes = sliceBytes
                + (payload.qualification == nil ? 0 : 96)
                + (payload.skip == nil ? 0 : 96)
        }
        bytes += min(operationBytes, Self.maximumOperationOverhead)
        return bytes
    }

    mutating func markCapacityBlocked() {
        capacityBlocked = true
        warning = Self.capacityWarning
    }

    mutating func enqueue(_ mutation: PendingMutation) -> EnqueueResult {
        var mutation = mutation
        let replacing = pendingMutations[mutation.eventID] != nil
        let previousBytes = pendingMutations[mutation.eventID]?.estimatedSerializedBytes ?? 0
        let projectedBytes = pendingSerializedBytes - previousBytes + mutation.estimatedSerializedBytes
        let countExceeded = !replacing && pendingMutations.count >= Self.maximumPendingSessions
        let bytesExceeded = mutation.estimatedSerializedBytes > Self.maximumPendingSerializedBytes
            || projectedBytes > Self.maximumPendingSerializedBytes
        let isFinish: Bool
        if case .finish = mutation.operation {
            isFinish = true
        } else {
            isFinish = false
        }

        if countExceeded || bytesExceeded {
            markCapacityBlocked()
            guard isFinish else { return .rejected }
        }

        if let existing = pendingMutations[mutation.eventID], mutation.snapshotID == nil {
            mutation.snapshotID = existing.snapshotID
        }
        pendingMutations[mutation.eventID] = mutation
        pendingSerializedBytes = projectedBytes
        return .accepted
    }

    mutating func updateAfterAttempt(_ mutation: PendingMutation) {
        guard let existing = pendingMutations[mutation.eventID] else { return }
        pendingMutations[mutation.eventID] = mutation
        pendingSerializedBytes += mutation.estimatedSerializedBytes - existing.estimatedSerializedBytes
    }

    mutating func removePending(_ eventID: UUID) {
        guard let mutation = pendingMutations.removeValue(forKey: eventID) else { return }
        pendingSerializedBytes = max(pendingSerializedBytes - mutation.estimatedSerializedBytes, 0)
        if pendingMutations.isEmpty {
            capacityBlocked = false
        }
    }

    mutating func scheduleRetry(atUptime: TimeInterval) {
        retry.schedule(atUptime: atUptime)
    }

    mutating func resetRetry() {
        retry.reset()
    }

    mutating func beginRecovery(atUptime: TimeInterval) {
        recovery.begin(atUptime: atUptime)
    }

    mutating func scheduleRecoveryRetry(atUptime: TimeInterval) {
        recovery.scheduleRetry(atUptime: atUptime)
    }

    mutating func completeRecovery() {
        recovery.reset()
    }

    mutating func rememberDiscarded(_ mutation: PendingMutation) {
        lastDiscardedEventID = mutation.eventID
    }

    mutating func consumeDiscarded(eventID: UUID) -> Bool {
        guard lastDiscardedEventID == eventID else { return false }
        lastDiscardedEventID = nil
        return true
    }

    mutating func setWarning(_ warning: String?) -> Bool {
        guard self.warning != warning else { return false }
        self.warning = warning
        return true
    }

    mutating func clearWarningIfPossible(activeSessionHasOverflow: Bool) -> Bool {
        guard pendingMutations.isEmpty,
              !capacityBlocked,
              !recovery.isPending,
              !activeSessionHasOverflow,
              warning != nil else { return false }
        warning = nil
        return true
    }

    mutating func reset() {
        self = MutationPersistenceState()
    }
}
