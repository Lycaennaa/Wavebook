import Foundation

// Public playback-session control: start, sample, pause/resume, seek, finish.
extension ListeningHistoryTracker {
    private struct PlaybackStartRequest {
        let track: Track
        let openedDuration: TimeInterval
        let openedFormat: String
        let source: ListeningPlaybackSource
        let position: TimeInterval
        let isPlaying: Bool
        let timestamp: Date
        let offset: Int
        let uptime: TimeInterval
    }

    /// Starts tracking playback for a track.
    @discardableResult
    public func startPlayback(
        track: Track,
        openedDuration: TimeInterval,
        openedFormat: String,
        source: ListeningPlaybackSource = ListeningPlaybackSource(kind: .library),
        initialPosition: TimeInterval = 0,
        isPlaying: Bool = true,
        at observedAtUTC: Date? = nil,
        utcOffsetSeconds: Int? = nil,
        monotonicTime: TimeInterval? = nil
    ) -> ListeningTrackingStartResult {
        guard valueState.activeSession == nil else { return .activeSessionExists }

        let timestamp = normalizedDate(observedAtUTC)
        let offset = normalizedOffset(utcOffsetSeconds, for: timestamp)
        let position = normalizedPosition(initialPosition, duration: openedDuration)
        valueState.playbackContext = PlaybackContext(
            track: track,
            openedDuration: openedDuration,
            openedFormat: openedFormat,
            source: source,
            renderedPosition: position,
            isPlaying: isPlaying,
            sessionToken: UUID()
        )
        let request = PlaybackStartRequest(
            track: track,
            openedDuration: openedDuration,
            openedFormat: openedFormat,
            source: source,
            position: position,
            isPlaying: isPlaying,
            timestamp: timestamp,
            offset: offset,
            uptime: normalizedMonotonicTime(monotonicTime)
        )
        let result = startPersistedPlayback(request)
        if valueState.activeSession?.isPlaying == true {
            startSampling()
        } else {
            stopSamplingIfIdle()
        }
        return result
    }

    private func startPersistedPlayback(_ request: PlaybackStartRequest) -> ListeningTrackingStartResult {
        guard !valueState.history.isPrivate else {
            stopSamplingIfIdle()
            return .privateMode
        }
        guard valueState.persistence.acceptsNewSession() else {
            guard !valueState.persistence.recoveryPending else {
                setPersistenceWarning(
                    "Listening history recovery is still in progress; this session will not be tracked."
                )
                return rejectStart(.rejectedPendingLimit)
            }
            markCapacityBlocked()
            return rejectStart(.rejectedPendingLimit)
        }
        switch prepareStartMutation(request: request) {
        case let .prepared(snapshot, mutation):
            return enqueueStartedPlayback(request: request, snapshot: snapshot, mutation: mutation)
        case let .rejected(result):
            return rejectStart(result)
        }
    }

    private enum StartPreparation {
        case prepared(snapshot: ListeningMediaSnapshot, mutation: PendingMutation)
        case rejected(ListeningTrackingStartResult)
    }

    private func prepareStartMutation(request: PlaybackStartRequest) -> StartPreparation {
        guard request.track.id != nil else {
            reportPersistenceFailure(ListeningHistoryTrackingError.invalidMetadata)
            return .rejected(.rejectedInvalidMetadata)
        }
        guard let snapshot = ListeningMediaSnapshot(
            liveTrackID: request.track.id,
            track: request.track,
            openedDuration: request.openedDuration,
            openedFormat: request.openedFormat,
            createdAtUTC: request.timestamp
        ) else {
            reportPersistenceFailure(ListeningHistoryTrackingError.invalidMetadata)
            return .rejected(.rejectedInvalidMetadata)
        }
        let mutation = makeStartMutation(request: request, snapshot: snapshot)
        guard mutation.estimatedSerializedBytes <= Self.maximumPendingSerializedBytes else {
            setPersistenceWarning("This listening session exceeds the pending-write limit and will not be tracked.")
            return .rejected(.rejectedPendingLimit)
        }
        guard valueState.persistence.canEnqueueNewMutation(mutation) else {
            markCapacityBlocked()
            return .rejected(.rejectedPendingLimit)
        }
        return .prepared(snapshot: snapshot, mutation: mutation)
    }

    private func rejectStart(_ result: ListeningTrackingStartResult) -> ListeningTrackingStartResult {
        valueState.playbackContext = nil
        stopSamplingIfIdle()
        return result
    }

    private func makeStartMutation(
        request: PlaybackStartRequest,
        snapshot: ListeningMediaSnapshot
    ) -> PendingMutation {
        var mutation = PendingMutation(
            eventID: UUID(),
            expectedGeneration: historyGeneration,
            snapshot: snapshot,
            snapshotID: nil,
            source: request.source,
            startedAtUTC: request.timestamp,
            startedUTCOffsetSeconds: request.offset,
            startPosition: request.position,
            operation: .begin,
            estimatedSerializedBytes: 0
        )
        mutation.estimatedSerializedBytes = valueState.persistence.estimatedSerializedBytes(for: mutation)
        return mutation
    }

    private func enqueueStartedPlayback(
        request: PlaybackStartRequest,
        snapshot: ListeningMediaSnapshot,
        mutation: PendingMutation
    ) -> ListeningTrackingStartResult {
        let eventID = mutation.eventID
        valueState.activeSession = ActiveSession(
            eventID: eventID,
            generation: historyGeneration,
            snapshot: snapshot,
            snapshotID: nil,
            source: request.source,
            startedAtUTC: request.timestamp,
            startedUTCOffsetSeconds: request.offset,
            startPosition: request.position,
            lastRenderedPosition: request.position,
            lastSampleAtUTC: request.timestamp,
            lastSampleUTCOffsetSeconds: request.offset,
            isPlaying: request.isPlaying,
            qualification: ListeningQualificationState(openedDuration: request.openedDuration),
            qualificationOccurrence: nil,
            listenedSeconds: 0,
            daySlices: [:],
            durableDaySliceKeys: [],
            daySliceOverflowed: false,
            checkpointSequence: 0,
            nextCheckpointUptime: request.uptime + Self.checkpointInterval
        )
        guard upsertPending(mutation) else {
            valueState.activeSession = nil
            valueState.playbackContext = nil
            stopSamplingIfIdle()
            return .rejectedPendingLimit
        }
        attemptPending(for: eventID, atUptime: request.uptime)
        if valueState.persistence.consumeDiscarded(eventID: eventID) {
            valueState.activeSession = nil
            valueState.playbackContext = nil
            stopSamplingIfIdle()
            return .staleGeneration
        }
        return .started(eventID)
    }

    /// Records a playback sample.
    public func sample(_ sample: ListeningPlaybackSample, monotonicTime: TimeInterval? = nil) {
        let uptime = normalizedMonotonicTime(monotonicTime)
        guard valueState.activeSession != nil else {
            updatePlaybackContext(with: sample)
            retryIfDue(atUptime: uptime)
            return
        }

        let result = process(sample: sample, countRenderedDelta: sample.isPlaying)
        guard let session = valueState.activeSession else {
            retryIfDue(atUptime: uptime)
            return
        }
        if result.didQualify || session.daySliceOverflowed {
            persistCheckpoint(forceRebase: false, immediately: true, atUptime: uptime)
        } else if result.didProgress, valueState.persistence.hasPendingMutation(for: session.eventID) {
            persistCheckpoint(forceRebase: false, immediately: false, atUptime: uptime)
        } else if !valueState.persistence.hasPendingMutation(for: session.eventID),
                  uptime >= session.nextCheckpointUptime {
            persistCheckpoint(forceRebase: false, immediately: true, atUptime: uptime)
        }
        retryIfDue(atUptime: uptime)
    }

    /// Pauses playback tracking.
    public func pause(
        renderedPosition: TimeInterval? = nil,
        at observedAtUTC: Date? = nil,
        utcOffsetSeconds: Int? = nil,
        monotonicTime: TimeInterval? = nil
    ) {
        guard valueState.activeSession != nil else {
            if var context = valueState.playbackContext {
                if let renderedPosition {
                    context.renderedPosition = normalizedPosition(renderedPosition, duration: context.openedDuration)
                }
                context.isPlaying = false
                valueState.playbackContext = context
            }
            stopSamplingIfIdle()
            return
        }
        let timestamp = normalizedDate(observedAtUTC)
        guard let sample = makeSample(
            renderedPosition: renderedPosition,
            isPlaying: true,
            observedAtUTC: timestamp,
            utcOffsetSeconds: utcOffsetSeconds
        ) else { return }
        let uptime = normalizedMonotonicTime(monotonicTime)
        _ = process(sample: sample, countRenderedDelta: true)
        persistCheckpoint(forceRebase: false, immediately: true, atUptime: uptime)
        guard var session = valueState.activeSession else { return }
        session.isPlaying = false
        session.lastRenderedPosition = normalizedPosition(
            sample.renderedPosition,
            duration: session.snapshot.openedDuration
        )
        session.lastSampleAtUTC = sample.observedAtUTC
        session.lastSampleUTCOffsetSeconds = sample.utcOffsetSeconds
        valueState.activeSession = session
        valueState.playbackContext?.isPlaying = false
        valueState.playbackContext?.renderedPosition = session.lastRenderedPosition
        retryIfDue(atUptime: uptime)
        stopSamplingIfIdle()
    }

    /// Resumes playback tracking.
    public func resume(
        renderedPosition: TimeInterval? = nil,
        at observedAtUTC: Date? = nil,
        utcOffsetSeconds: Int? = nil,
        monotonicTime: TimeInterval? = nil
    ) {
        guard valueState.activeSession != nil else {
            if var context = valueState.playbackContext {
                if let renderedPosition {
                    context.renderedPosition = normalizedPosition(renderedPosition, duration: context.openedDuration)
                }
                context.isPlaying = true
                valueState.playbackContext = context
            }
            return
        }
        let timestamp = normalizedDate(observedAtUTC)
        guard let sample = makeSample(
            renderedPosition: renderedPosition,
            isPlaying: false,
            observedAtUTC: timestamp,
            utcOffsetSeconds: utcOffsetSeconds
        ) else { return }
        let uptime = normalizedMonotonicTime(monotonicTime)
        _ = process(sample: sample, countRenderedDelta: false)
        guard var session = valueState.activeSession else { return }
        session.isPlaying = true
        valueState.activeSession = session
        valueState.playbackContext?.isPlaying = true
        startSampling()
        persistCheckpoint(forceRebase: true, immediately: true, atUptime: uptime)
        retryIfDue(atUptime: uptime)
    }

    /// Prepares the active session for a seek.
    public func prepareForSeek(
        renderedPosition: TimeInterval? = nil,
        at observedAtUTC: Date? = nil,
        utcOffsetSeconds: Int? = nil,
        monotonicTime: TimeInterval? = nil
    ) {
        guard let session = valueState.activeSession else {
            if let renderedPosition, var context = valueState.playbackContext {
                context.renderedPosition = normalizedPosition(renderedPosition, duration: context.openedDuration)
                valueState.playbackContext = context
            }
            return
        }
        let timestamp = normalizedDate(observedAtUTC)
        guard let sample = makeSample(
            renderedPosition: renderedPosition,
            isPlaying: session.isPlaying,
            observedAtUTC: timestamp,
            utcOffsetSeconds: utcOffsetSeconds
        ) else { return }
        let uptime = normalizedMonotonicTime(monotonicTime)
        _ = process(sample: sample, countRenderedDelta: session.isPlaying)
        valueState.prepareSeek(
            eventID: session.eventID,
            sessionToken: valueState.playbackContext?.sessionToken
        )
        persistCheckpoint(forceRebase: false, immediately: true, atUptime: uptime)
        retryIfDue(atUptime: uptime)
    }

    /// Completes a pending seek operation.
    @discardableResult
    public func completeSeek(
        successfully: Bool,
        renderedPosition: TimeInterval? = nil,
        isPlaying: Bool? = nil,
        at observedAtUTC: Date? = nil,
        utcOffsetSeconds: Int? = nil,
        monotonicTime: TimeInterval? = nil
    ) -> Bool {
        defer {
            valueState.clearSeekPreparation()
        }
        guard let session = valueState.activeSession else {
            guard !valueState.hasSeekPreparation,
                  successfully,
                  var context = valueState.playbackContext else { return false }
            if let renderedPosition {
                context.renderedPosition = normalizedPosition(renderedPosition, duration: context.openedDuration)
            }
            if let isPlaying { context.isPlaying = isPlaying }
            valueState.playbackContext = context
            return true
        }
        guard valueState.isSeekPrepared(
            eventID: session.eventID,
            sessionToken: valueState.playbackContext?.sessionToken
        ) else {
            return false
        }
        guard successfully else { return true }

        let timestamp = normalizedDate(observedAtUTC)
        let offset = normalizedOffset(utcOffsetSeconds, for: timestamp)
        let position = normalizedPosition(
            renderedPosition ?? session.lastRenderedPosition,
            duration: session.snapshot.openedDuration
        )
        var updated = session
        updated.lastRenderedPosition = position
        updated.lastSampleAtUTC = timestamp
        updated.lastSampleUTCOffsetSeconds = offset
        if let isPlaying { updated.isPlaying = isPlaying }
        valueState.activeSession = updated
        valueState.playbackContext?.renderedPosition = position
        if let isPlaying { valueState.playbackContext?.isPlaying = isPlaying }
        let uptime = normalizedMonotonicTime(monotonicTime)
        persistCheckpoint(forceRebase: true, immediately: true, atUptime: uptime)
        retryIfDue(atUptime: uptime)
        return true
    }
    /// Ends the active playback session.
    @discardableResult
    public func endPlayback(
        reason: ListeningEventEndReason,
        renderedPosition: TimeInterval? = nil,
        isPlaying: Bool = true,
        at observedAtUTC: Date? = nil,
        utcOffsetSeconds: Int? = nil,
        monotonicTime: TimeInterval? = nil
    ) -> Bool {
        guard valueState.activeSession != nil else {
            valueState.playbackContext = nil
            stopSamplingIfIdle()
            return false
        }
        let timestamp = normalizedDate(observedAtUTC)
        if let sample = makeSample(
            renderedPosition: renderedPosition,
            isPlaying: isPlaying,
            observedAtUTC: timestamp,
            utcOffsetSeconds: utcOffsetSeconds
        ) {
            _ = process(sample: sample, countRenderedDelta: isPlaying)
        }
        let uptime = normalizedMonotonicTime(monotonicTime)
        let result = finishActive(
            reason: reason,
            endedAtUTC: timestamp,
            endedUTCOffsetSeconds: normalizedOffset(utcOffsetSeconds, for: timestamp),
            endPosition: renderedPosition,
            preservePlaybackContext: false,
            atUptime: uptime
        )
        retryIfDue(atUptime: uptime)
        return result
    }
}
