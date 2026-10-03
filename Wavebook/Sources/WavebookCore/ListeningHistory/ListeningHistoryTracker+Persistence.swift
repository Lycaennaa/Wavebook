import Foundation

// Pending mutation queue: retry, recovery, capacity, and warning reporting.
extension ListeningHistoryTracker {
    func persistCheckpoint(forceRebase: Bool, immediately: Bool, atUptime: TimeInterval) {
        guard var session = valueState.activeSession else { return }
        guard session.checkpointSequence < Int64.max else {
            reportPersistenceFailure(LibraryDatabaseError.invalidListeningEvent)
            return
        }
        session.checkpointSequence += 1
        let payload = CheckpointPayload(
            checkpointAtUTC: session.lastSampleAtUTC,
            renderedPosition: session.lastRenderedPosition,
            checkpointUTCOffsetSeconds: session.lastSampleUTCOffsetSeconds,
            forceRebase: forceRebase,
            checkpointSequence: session.checkpointSequence,
            daySlices: makeDaySlices(for: session),
            qualification: session.qualificationOccurrence,
            containsOverflow: session.daySliceOverflowed
        )
        var mutation = PendingMutation(
            eventID: session.eventID,
            expectedGeneration: session.generation,
            snapshot: session.snapshot,
            snapshotID: session.snapshotID,
            source: session.source,
            startedAtUTC: session.startedAtUTC,
            startedUTCOffsetSeconds: session.startedUTCOffsetSeconds,
            startPosition: session.startPosition,
            operation: .checkpoint(payload),
            estimatedSerializedBytes: 0
        )
        mutation.estimatedSerializedBytes = valueState.persistence.estimatedSerializedBytes(for: mutation)
        let hadPending = valueState.persistence.hasPendingMutation(for: session.eventID)
        guard upsertPending(mutation) else { return }
        if !hadPending || immediately {
            attemptPending(for: session.eventID, atUptime: atUptime)
        }

    }
    func attemptPending(for eventID: UUID? = nil, atUptime: TimeInterval) {
        let ids = eventID.map { [$0] } ?? valueState.persistence.pendingEventIDs()
        var didFail = false
        for id in ids {
            guard var mutation = valueState.persistence.pendingMutation(for: id) else { continue }
            switch attempt(&mutation, atUptime: atUptime) {
            case .committed:
                removePending(id)
            case .discarded:
                removePending(id)
            case let .failed(error):
                valueState.persistence.updateAfterAttempt(mutation)
                didFail = true
                reportPersistenceFailure(error)
            }
        }
        if didFail {
            valueState.persistence.scheduleRetry(atUptime: atUptime)
        } else if !valueState.persistence.hasPendingMutations {
            valueState.persistence.resetRetry()
            clearPersistenceWarningIfPossible()
        }
    }
    func beginTerminationFlush(
        atUptime: TimeInterval,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard terminationFlushCompletion == nil else {
            completion(false)
            return
        }
        terminationFlushCompletion = completion
        terminationFlushDeadlineUptime = atUptime + Self.terminationFlushTimeout
        terminationFlushAttempt = 0
        flushTermination(atUptime: atUptime)
    }

    func flushTermination(atUptime: TimeInterval) {
        guard terminationFlushCompletion != nil,
              let deadline = terminationFlushDeadlineUptime else { return }
        guard valueState.persistence.hasPendingMutations else {

            completeTerminationFlush(successfully: true)
            return
        }
        guard atUptime < deadline,
              terminationFlushAttempt < Self.terminationFlushMaximumAttempts else {
            completeTerminationFlush(successfully: false)
            return
        }

        terminationFlushAttempt += 1
        attemptPending(atUptime: atUptime)
        guard valueState.persistence.hasPendingMutations else {
            completeTerminationFlush(successfully: true)
            return
        }
        guard atUptime < deadline,
              terminationFlushAttempt < Self.terminationFlushMaximumAttempts else {
            completeTerminationFlush(successfully: false)
            return
        }
        scheduleTerminationFlush()
    }

    private func scheduleTerminationFlush() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.terminationFlushRetryInterval) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.terminationFlushCompletion != nil else { return }
                self.flushTermination(atUptime: self.normalizedMonotonicTime(nil))
            }
        }
    }

    private func completeTerminationFlush(successfully: Bool) {
        guard let completion = terminationFlushCompletion else { return }
        terminationFlushCompletion = nil
        terminationFlushDeadlineUptime = nil
        terminationFlushAttempt = 0
        if !successfully {
            // Keep the process alive through the app-level cancel reply so the pending payload remains retryable.
            schedulePersistenceRetryTimer()
        }
        completion(successfully)
    }
    func attempt(_ mutation: inout PendingMutation, atUptime: TimeInterval) -> AttemptResult {
        do {
            let snapshotID = try persistedSnapshotID(for: &mutation)
            switch mutation.operation {
            case .begin:
                return try attemptBegin(mutation, snapshotID: snapshotID, atUptime: atUptime)
            case .checkpoint:
                return try attemptCheckpoint(mutation, snapshotID: snapshotID, atUptime: atUptime)
            case .finish:
                return try attemptFinish(mutation, snapshotID: snapshotID)
            }
        } catch let error as LibraryDatabaseError {
            switch error {
            case .staleListeningGeneration, .privateListeningHistory:
                discardStaleMutation(mutation)
                return .discarded
            default:
                return .failed(error)
            }
        } catch {
            return .failed(error)
        }
    }

    private func persistedSnapshotID(for mutation: inout PendingMutation) throws -> Int64 {
        let savedSnapshot: ListeningMediaSnapshot
        if let snapshotID = mutation.snapshotID {
            guard let snapshot = ListeningMediaSnapshot(
                id: snapshotID,
                liveTrackID: mutation.snapshot.liveTrackID,
                title: mutation.snapshot.title,
                artistDisplay: mutation.snapshot.artistDisplay,
                albumTitle: mutation.snapshot.albumTitle,
                albumOwner: mutation.snapshot.albumOwner,
                genreDisplay: mutation.snapshot.genreDisplay,
                artists: mutation.snapshot.artists,
                genres: mutation.snapshot.genres,
                openedDuration: mutation.snapshot.openedDuration,
                format: mutation.snapshot.format,
                createdAtUTC: mutation.snapshot.createdAtUTC
            ) else {
                throw ListeningHistoryTrackingError.invalidMetadata
            }
            savedSnapshot = try database.createOrReuseListeningSnapshot(
                snapshot,
                expectedGeneration: mutation.expectedGeneration
            )
        } else {
            savedSnapshot = try database.createOrReuseListeningSnapshot(
                mutation.snapshot,
                expectedGeneration: mutation.expectedGeneration
            )
        }
        mutation.snapshotID = savedSnapshot.id
        guard let snapshotID = savedSnapshot.id else {
            throw LibraryDatabaseError.invalidListeningSnapshot
        }
        return snapshotID
    }

    private func beginPendingMutation(
        _ mutation: PendingMutation,
        snapshotID: Int64
    ) throws -> ListeningHistoryMutationResult {
        try database.beginListeningEvent(
            eventID: mutation.eventID,
            expectedGeneration: mutation.expectedGeneration,
            snapshotID: snapshotID,
            source: mutation.source,
            startedAtUTC: mutation.startedAtUTC,
            startedUTCOffsetSeconds: mutation.startedUTCOffsetSeconds,
            startPosition: mutation.startPosition
        )
    }

    private func attemptBegin(
        _ mutation: PendingMutation,
        snapshotID: Int64,
        atUptime: TimeInterval
    ) throws -> AttemptResult {
        switch try beginPendingMutation(mutation, snapshotID: snapshotID) {
        case .applied:
            updateActiveAfterCommit(mutation, atUptime: atUptime)
            return .committed
        case .staleGeneration, .privateMode:
            discardStaleMutation(mutation)
            return .discarded
        case .missingEvent, .alreadyFinished, .staleCheckpointSequence:
            return .failed(ListeningHistoryTrackingError.mutationRejected)
        }
    }

    private func beginPendingMutationResult(
        _ mutation: PendingMutation,
        snapshotID: Int64
    ) throws -> AttemptResult? {
        switch try beginPendingMutation(mutation, snapshotID: snapshotID) {
        case .applied:
            return nil
        case .staleGeneration, .privateMode:
            discardStaleMutation(mutation)
            return .discarded
        case .missingEvent, .alreadyFinished, .staleCheckpointSequence:
            return .failed(ListeningHistoryTrackingError.mutationRejected)
        }
    }

    private func attemptCheckpoint(
        _ mutation: PendingMutation,
        snapshotID: Int64,
        atUptime: TimeInterval
    ) throws -> AttemptResult {
        guard case let .checkpoint(payload) = mutation.operation else {
            return .failed(ListeningHistoryTrackingError.mutationRejected)
        }
        if let result = try beginPendingMutationResult(mutation, snapshotID: snapshotID) {
            return result
        }
        let result = try database.checkpointListeningEvent(
            eventID: mutation.eventID,
            expectedGeneration: mutation.expectedGeneration,
            checkpointAtUTC: payload.checkpointAtUTC,
            renderedPosition: payload.renderedPosition,
            daySlices: payload.daySlices,
            qualification: payload.qualification,
            checkpointUTCOffsetSeconds: payload.checkpointUTCOffsetSeconds,
            forceRebase: payload.forceRebase,
            checkpointSequence: payload.checkpointSequence
        )
        return checkpointResult(result, mutation: mutation, payload: payload, atUptime: atUptime)
    }

    private func checkpointResult(
        _ result: ListeningHistoryMutationResult,
        mutation: PendingMutation,
        payload: CheckpointPayload,
        atUptime: TimeInterval
    ) -> AttemptResult {
        switch result {
        case .applied:
            updateActiveAfterCommit(mutation, atUptime: atUptime)
            return .committed
        case .staleGeneration, .privateMode:
            discardStaleMutation(mutation)
            return .discarded
        case .staleCheckpointSequence:
            return checkpointIsDurablyApplied(mutation, payload: payload)
                ? .committed
                : .failed(ListeningHistoryTrackingError.mutationRejected)
        case .missingEvent, .alreadyFinished:
            return .failed(ListeningHistoryTrackingError.mutationRejected)
        }
    }

    private func attemptFinish(
        _ mutation: PendingMutation,
        snapshotID: Int64
    ) throws -> AttemptResult {
        guard case let .finish(payload) = mutation.operation else {
            return .failed(ListeningHistoryTrackingError.mutationRejected)
        }
        if let result = try beginPendingMutationResult(mutation, snapshotID: snapshotID) {
            return result
        }
        let result = try database.finishListeningEvent(
            request: .init(
                eventID: mutation.eventID,
                expectedGeneration: mutation.expectedGeneration,
                endedAtUTC: payload.endedAtUTC,
                endReason: payload.endReason,
                details: .init(
                    endedUTCOffsetSeconds: payload.endedUTCOffsetSeconds,
                    endPosition: payload.endPosition,
                    daySlices: payload.daySlices,
                    qualification: payload.qualification,
                    skip: payload.skip
                )
            )
        )
        return finishResult(result, mutation: mutation)
    }

    private func finishResult(
        _ result: ListeningHistoryMutationResult,
        mutation: PendingMutation
    ) -> AttemptResult {
        switch result {
        case .applied:
            return .committed
        case .staleGeneration, .privateMode:
            discardStaleMutation(mutation)
            return .discarded
        case .missingEvent, .alreadyFinished, .staleCheckpointSequence:
            return .failed(ListeningHistoryTrackingError.mutationRejected)
        }
    }

    func discardStaleMutation(_ mutation: PendingMutation) {
        valueState.persistence.rememberDiscarded(mutation)
        synchronizeStateAfterStaleMutation()
    }

    func checkpointIsDurablyApplied(_ mutation: PendingMutation, payload: CheckpointPayload) -> Bool {
        guard let event = try? database.listeningEvent(id: mutation.eventID),
              (event.lastDurableCheckpointSequence ?? -1) >= payload.checkpointSequence else {
            return false
        }
        for target in payload.daySlices {
            let stored = event.daySlices.first {
                $0.localDay == target.localDay && $0.utcOffsetSeconds == target.utcOffsetSeconds
            }
            guard let stored, stored.actualListenedSeconds >= target.actualListenedSeconds else { return false }
        }
        if payload.qualification != nil, event.qualification == nil { return false }
        return true
    }

    func updateActiveAfterCommit(_ mutation: PendingMutation, atUptime: TimeInterval) {
        guard var session = valueState.activeSession, session.eventID == mutation.eventID else { return }
        session.snapshotID = mutation.snapshotID
        if case let .checkpoint(payload) = mutation.operation {
            session.durableDaySliceKeys.formUnion(
                payload.daySlices.map {
                    SliceKey(localDay: $0.localDay, utcOffsetSeconds: $0.utcOffsetSeconds)
                }
            )
            session.nextCheckpointUptime = atUptime + Self.checkpointInterval
            session.checkpointSequence = max(session.checkpointSequence, payload.checkpointSequence)
        }
        valueState.activeSession = session
    }

    func attemptRecovery(atUptime: TimeInterval) {
        guard valueState.persistence.recoveryPending else { return }
        do {
            switch try database.recoverAbandonedListeningEvents(expectedGeneration: historyGeneration) {
            case .finalized:
                valueState.persistence.completeRecovery()
                clearPersistenceWarningIfPossible()
                stopSamplingIfIdle()
            case .staleGeneration:
                do {
                    valueState.history = try database.listeningHistoryState()
                } catch {
                    reportPersistenceFailure(error)
                }
                valueState.persistence.scheduleRecoveryRetry(atUptime: atUptime)
            }
        } catch {
            reportPersistenceFailure(error)
            valueState.persistence.scheduleRecoveryRetry(atUptime: atUptime)
        }

    }
    @discardableResult
    func upsertPending(_ mutation: PendingMutation) -> Bool {
        let oldWarning = valueState.persistence.warning
        let result = valueState.persistence.enqueue(mutation)
        notifyWarningIfChanged(from: oldWarning)
        return result == .accepted
    }

    func removePending(_ eventID: UUID) {
        valueState.persistence.removePending(eventID)
        clearPersistenceWarningIfPossible()
        stopSamplingIfIdle()
    }

    func synchronizeStateAfterStaleMutation() {
        do {
            let state = try database.listeningHistoryState()
            valueState.history = state
            discardMutationsFromOtherGenerations(reportLoss: true)
            if let session = valueState.activeSession, session.generation != state.generation {
                valueState.activeSession = nil
            }
        } catch {
            reportPersistenceFailure(error)
        }
    }

    func discardMutationsFromOtherGenerations(reportLoss: Bool) {
        let ids = valueState.persistence.eventIDs(fromOtherThan: historyGeneration)
        guard !ids.isEmpty else { return }
        for id in ids { removePending(id) }
        if reportLoss {
            setPersistenceWarning("Some listening history changes were invalidated by a history boundary.")
        }
    }

    func reportPersistenceFailure(_ error: Error) {
        let message = "Listening history persistence is unhealthy: \(String(describing: error))"
        if valueState.persistence.warning == nil { onPersistenceError?(message) }
        setPersistenceWarning(message)
    }

    func setPersistenceWarning(_ warning: String) {
        guard valueState.persistence.setWarning(warning) else { return }
        notifyWarningChanged()
    }
    func markCapacityBlocked() {
        let oldWarning = valueState.persistence.warning
        valueState.persistence.markCapacityBlocked()
        notifyWarningIfChanged(from: oldWarning)
    }

    func notifyWarningIfChanged(from oldWarning: String?) {
        guard oldWarning != valueState.persistence.warning else { return }
        notifyWarningChanged()
    }

    func clearPersistenceWarningIfPossible() {
        let changed = valueState.persistence.clearWarningIfPossible(
            activeSessionHasOverflow: valueState.activeSession?.daySliceOverflowed == true
        )
        if changed {
            notifyWarningChanged()
        }
    }

    func notifyWarningChanged() {
        onPersistenceWarningChanged?(valueState.persistence.warning)
    }
}

/// Errors raised while tracking listening history.
public enum ListeningHistoryTrackingError: Error, Equatable, Sendable {
    /// Event metadata was invalid.
    case invalidMetadata
    /// Persistence rejected the mutation.
    case mutationRejected
}
