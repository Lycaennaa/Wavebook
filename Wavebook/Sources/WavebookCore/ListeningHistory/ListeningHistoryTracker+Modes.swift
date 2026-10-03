import Foundation

// Private mode, history reset, and termination.
extension ListeningHistoryTracker {
    private struct PrivateModePersistenceRequest {
        let enabled: Bool
        let renderedPosition: TimeInterval?
        let timestamp: Date
        let offset: Int
        let uptime: TimeInterval
        let wasTracking: Bool
        let isPlaying: Bool?
    }

    /// Changes private listening-history mode.
    @discardableResult
    public func setPrivateMode(
        _ enabled: Bool,
        renderedPosition: TimeInterval? = nil,
        isPlaying: Bool? = nil,
        at observedAtUTC: Date? = nil,
        utcOffsetSeconds: Int? = nil,
        monotonicTime: TimeInterval? = nil
    ) -> Bool {
        guard enabled != valueState.history.isPrivate else { return true }
        let timestamp = normalizedDate(observedAtUTC)
        let offset = normalizedOffset(utcOffsetSeconds, for: timestamp)
        let uptime = normalizedMonotonicTime(monotonicTime)
        if valueState.persistence.recoveryPending {
            attemptRecovery(atUptime: uptime)
            if valueState.persistence.recoveryPending {
                setPersistenceWarning(
                    "Listening history recovery is still in progress; private mode cannot change until it completes."
                )
                return false
            }
        }

        let wasTracking = enabled && valueState.activeSession != nil
        if enabled,
           !finishPrivateTransition(
               renderedPosition: renderedPosition,
               isPlaying: isPlaying,
               timestamp: timestamp,
               offset: offset,
               uptime: uptime
           ) {
            reportPersistenceFailure(ListeningHistoryTrackingError.mutationRejected)
            _ = restartTrackingAfterPrivateTransitionFailure(at: timestamp, offset: offset, uptime: uptime)
            return false
        }
        if enabled {
            attemptPending(atUptime: uptime)
            guard !valueState.persistence.hasPendingMutations else {
                reportPersistenceFailure(ListeningHistoryTrackingError.mutationRejected)
                _ = restartTrackingAfterPrivateTransitionFailure(at: timestamp, offset: offset, uptime: uptime)
                return false
            }
        }
        return persistPrivateMode(
            request: PrivateModePersistenceRequest(
                enabled: enabled,
                renderedPosition: renderedPosition,
                timestamp: timestamp,
                offset: offset,
                uptime: uptime,
                wasTracking: wasTracking,
                isPlaying: isPlaying
            )
        )
    }

    private func finishPrivateTransition(
        renderedPosition: TimeInterval?,
        isPlaying: Bool?,
        timestamp: Date,
        offset: Int,
        uptime: TimeInterval
    ) -> Bool {
        guard let session = valueState.activeSession else { return true }
        let position = renderedPosition ?? session.lastRenderedPosition
        if let sample = makeSample(
            renderedPosition: position,
            isPlaying: isPlaying ?? session.isPlaying,
            observedAtUTC: timestamp,
            utcOffsetSeconds: offset
        ) {
            _ = process(sample: sample, countRenderedDelta: sample.isPlaying)
        }
        return finishActive(
            reason: .privateModeBoundary,
            endedAtUTC: timestamp,
            endedUTCOffsetSeconds: offset,
            endPosition: renderedPosition,
            preservePlaybackContext: true,
            atUptime: uptime
        )
    }

    private func persistPrivateMode(
        request: PrivateModePersistenceRequest
    ) -> Bool {
        let rollbackState = valueState
        do {
            let state = try database.saveListeningHistoryPrivateMode(request.enabled)
            valueState.history = state
            discardMutationsFromOtherGenerations(reportLoss: true)
            if !request.enabled, var context = valueState.playbackContext {
                let position = normalizedPosition(
                    request.renderedPosition ?? context.renderedPosition,
                    duration: context.openedDuration
                )
                let playing = request.isPlaying ?? context.isPlaying
                context.renderedPosition = position
                context.isPlaying = playing
                valueState.playbackContext = context
                let result = startPlayback(
                    track: context.track,
                    openedDuration: context.openedDuration,
                    openedFormat: context.openedFormat,
                    source: context.source,
                    initialPosition: position,
                    isPlaying: playing,
                    at: request.timestamp,
                    utcOffsetSeconds: request.offset,
                    monotonicTime: request.uptime
                )
                guard case .started = result else {
                    reportPersistenceFailure(ListeningHistoryTrackingError.mutationRejected)
                    return false
                }
            }
            return true
        } catch {
            reportPersistenceFailure(error)
            if request.wasTracking, let context = valueState.playbackContext {
                let result = startPlayback(
                    track: context.track,
                    openedDuration: context.openedDuration,
                    openedFormat: context.openedFormat,
                    source: context.source,
                    initialPosition: context.renderedPosition,
                    isPlaying: context.isPlaying,
                    at: request.timestamp,
                    utcOffsetSeconds: request.offset,
                    monotonicTime: request.uptime
                )
                if case .started = result { return false }
                reportPersistenceFailure(ListeningHistoryTrackingError.mutationRejected)
            }
            valueState = rollbackState
            return false
        }
    }

    func restartTrackingAfterPrivateTransitionFailure(
        at timestamp: Date,
        offset: Int,
        uptime: TimeInterval
    ) -> Bool {
        guard valueState.activeSession == nil,
              let context = valueState.playbackContext,
              !valueState.history.isPrivate else { return false }
        let result = startPlayback(
            track: context.track,
            openedDuration: context.openedDuration,
            openedFormat: context.openedFormat,
            source: context.source,
            initialPosition: context.renderedPosition,
            isPlaying: context.isPlaying,
            at: timestamp,
            utcOffsetSeconds: offset,
            monotonicTime: uptime
        )
        if case .started = result { return true }
        return false
    }

    /// Resets listening history and preserves playback context.
    @discardableResult
    public func resetHistory(
        at timestamp: Date? = nil,
        renderedPosition: TimeInterval? = nil,
        isPlaying: Bool? = nil,
        utcOffsetSeconds: Int? = nil,
        monotonicTime: TimeInterval? = nil
    ) -> Bool {
        let resetAt = normalizedDate(timestamp)
        let resetOffset = normalizedOffset(utcOffsetSeconds, for: resetAt)
        let uptime = normalizedMonotonicTime(monotonicTime)
        let rollbackState = valueState
        var resetContext = valueState.playbackContext
        if let renderedPosition, var context = resetContext {
            context.renderedPosition = normalizedPosition(renderedPosition, duration: context.openedDuration)
            resetContext = context
        }
        if let isPlaying, var context = resetContext {
            context.isPlaying = isPlaying
            resetContext = context
        }

        valueState.prepareForHistoryReset(playbackContext: resetContext)
        stopSamplingIfIdle()

        do {
            let state = try database.resetListeningHistory(at: resetAt)
            valueState.history = state
            notifyWarningChanged()

            if let resetContext {
                if !state.isPrivate {
                    _ = startPlayback(
                        track: resetContext.track,
                        openedDuration: resetContext.openedDuration,
                        openedFormat: resetContext.openedFormat,
                        source: resetContext.source,
                        initialPosition: resetContext.renderedPosition,
                        isPlaying: resetContext.isPlaying,
                        at: resetAt,
                        utcOffsetSeconds: resetOffset,
                        monotonicTime: uptime
                    )
                } else {
                    stopSamplingIfIdle()
                }
            }
            stopSamplingIfIdle()
            return true
        } catch {
            valueState = rollbackState
            if valueState.activeSession?.isPlaying == true {
                startSampling()
            } else {
                stopSamplingIfIdle()
            }
            reportPersistenceFailure(error)
            return false
        }
    }

    /// Terminates active listening and flushes pending history.
    public func terminate(
        at observedAtUTC: Date? = nil,
        renderedPosition: TimeInterval? = nil,
        isPlaying: Bool = true,
        utcOffsetSeconds: Int? = nil,
        monotonicTime: TimeInterval? = nil,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        let timestamp = normalizedDate(observedAtUTC)
        let uptime = normalizedMonotonicTime(monotonicTime)
        if valueState.activeSession != nil {
            _ = endPlayback(
                reason: .appTermination,
                renderedPosition: renderedPosition,
                isPlaying: isPlaying,
                at: timestamp,
                utcOffsetSeconds: utcOffsetSeconds,
                monotonicTime: uptime
            )
        }
        stopSampling()
        beginTerminationFlush(atUptime: uptime, completion: completion)
    }
}
