import Foundation

// Sample processing, listened-time accounting, day slices, and normalization.
extension ListeningHistoryTracker {
    private struct ProgressRequest {
        let acceptedDelta: TimeInterval
        let previousListenedSeconds: TimeInterval
        let previousDate: Date
        let previousOffset: Int
        let sample: ListeningPlaybackSample
        let position: TimeInterval
    }

    func process(sample: ListeningPlaybackSample, countRenderedDelta: Bool) -> SampleResult {
        guard var session = valueState.activeSession else {
            updatePlaybackContext(with: sample)
            return SampleResult(didProgress: false, didQualify: false)
        }
        updatePlaybackContext(with: sample)
        let position = normalizedPosition(sample.renderedPosition, duration: session.snapshot.openedDuration)
        let previousPosition = session.lastRenderedPosition
        let previousDate = session.lastSampleAtUTC
        let previousOffset = session.lastSampleUTCOffsetSeconds
        session.lastSampleAtUTC = sample.observedAtUTC
        session.lastSampleUTCOffsetSeconds = sample.utcOffsetSeconds
        guard countRenderedDelta, sample.isPlaying, session.isPlaying, position >= previousPosition else {
            return storeNonProgress(sample: sample, position: position, session: &session)
        }
        let rawDelta = position - previousPosition
        let remainingDuration = session.snapshot.openedDuration > 0
            ? max(session.snapshot.openedDuration - previousPosition, 0)
            : rawDelta
        let acceptedDelta = min(rawDelta, remainingDuration)
        guard acceptedDelta.isFinite, acceptedDelta > 0 else {
            return storeNonProgress(sample: sample, position: position, session: &session)
        }
        let request = ProgressRequest(
            acceptedDelta: acceptedDelta,
            previousListenedSeconds: session.listenedSeconds,
            previousDate: previousDate,
            previousOffset: previousOffset,
            sample: sample,
            position: position
        )
        return recordProgress(request, session: &session)
    }

    private func storeNonProgress(
        sample: ListeningPlaybackSample,
        position: TimeInterval,
        session: inout ActiveSession
    ) -> SampleResult {
        session.lastRenderedPosition = position
        session.isPlaying = sample.isPlaying
        valueState.activeSession = session
        return SampleResult(didProgress: false, didQualify: false)
    }

    private func recordProgress(
        _ request: ProgressRequest,
        session: inout ActiveSession
    ) -> SampleResult {
        addListenedDelta(
            request.acceptedDelta,
            to: &session,
            from: request.previousDate,
            fromOffset: request.previousOffset,
            to: request.sample.observedAtUTC,
            toOffset: request.sample.utcOffsetSeconds
        )
        session.listenedSeconds = min(
            request.previousListenedSeconds + request.acceptedDelta,
            TimeInterval.greatestFiniteMagnitude
        )
        var didQualify = false
        if session.qualification.update(actualListenedSeconds: session.listenedSeconds) {
            session.qualificationOccurrence = qualificationOccurrence(
                threshold: session.qualification.threshold.seconds,
                previousListenedSeconds: request.previousListenedSeconds,
                delta: request.acceptedDelta,
                from: request.previousDate,
                fromOffset: request.previousOffset,
                at: request.sample.observedAtUTC,
                offset: request.sample.utcOffsetSeconds
            )
            didQualify = true
        }
        session.lastRenderedPosition = request.position
        session.isPlaying = true
        valueState.activeSession = session
        return SampleResult(didProgress: true, didQualify: didQualify)
    }

    func finishActive(
        reason: ListeningEventEndReason,
        endedAtUTC: Date,
        endedUTCOffsetSeconds: Int,
        endPosition: TimeInterval?,
        preservePlaybackContext: Bool = false,
        atUptime: TimeInterval
    ) -> Bool {
        guard let session = valueState.activeSession else { return false }
        let mutation = makeFinishMutation(
            session: session,
            reason: reason,
            endedAtUTC: endedAtUTC,
            endedUTCOffsetSeconds: endedUTCOffsetSeconds,
            endPosition: endPosition
        )
        let persisted = upsertPending(mutation)
        // Clear the active session even when the finish payload could not be
        // queued: retaining it would attribute the replacement track's
        // listening time to this event and block all future sessions.
        valueState.activeSession = nil
        valueState.clearSeekPreparation()
        if !preservePlaybackContext {
            valueState.playbackContext = nil
        }
        guard persisted else {
            stopSamplingIfIdle()
            return false
        }
        attemptPending(for: session.eventID, atUptime: atUptime)
        stopSamplingIfIdle()
        return true
    }

    private func makeFinishMutation(
        session: ActiveSession,
        reason: ListeningEventEndReason,
        endedAtUTC: Date,
        endedUTCOffsetSeconds: Int,
        endPosition: TimeInterval?
    ) -> PendingMutation {
        let finalPosition = normalizedPosition(
            endPosition ?? session.lastRenderedPosition,
            duration: session.snapshot.openedDuration
        )
        let skip = ListeningHistoryThresholds.qualifiesSkip(
            after: session.listenedSeconds,
            endReason: reason
        ) ? occurrence(at: endedAtUTC, offset: endedUTCOffsetSeconds) : nil
        let payload = FinishPayload(
            endedAtUTC: endedAtUTC,
            endedUTCOffsetSeconds: endedUTCOffsetSeconds,
            endPosition: finalPosition,
            endReason: reason,
            daySlices: makeDaySlices(for: session),
            qualification: session.qualificationOccurrence,
            skip: skip,
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
            operation: .finish(payload),
            estimatedSerializedBytes: 0
        )
        mutation.estimatedSerializedBytes = valueState.persistence.estimatedSerializedBytes(for: mutation)
        return mutation
    }

    private struct DaySliceRequest {
        let delta: TimeInterval
        let fallbackDay: ListeningLocalDay
        let from: Date
        let date: Date
        let wallDelta: TimeInterval
        let fromOffset: Int
        let toOffset: Int
    }

    func addListenedDelta(
        _ delta: TimeInterval,
        to session: inout ActiveSession,
        from: Date,
        fromOffset: Int = 0,
        to date: Date,
        toOffset: Int = 0
    ) {
        guard delta.isFinite, delta > 0 else { return }
        guard let fallbackDay = localDay(for: date, offset: toOffset) else { return }
        let wallDelta = date.timeIntervalSince(from)
        guard from.timeIntervalSinceReferenceDate.isFinite,
              wallDelta > 0,
              wallDelta <= 36 * 60 * 60,
              fromOffset == toOffset else {
            addSlice(delta, day: fallbackDay, offset: toOffset, to: &session)
            return
        }
        let request = DaySliceRequest(
            delta: delta,
            fallbackDay: fallbackDay,
            from: from,
            date: date,
            wallDelta: wallDelta,
            fromOffset: fromOffset,
            toOffset: toOffset
        )
        addWallClockSlices(request, to: &session)
    }

    private func addWallClockSlices(
        _ request: DaySliceRequest,
        to session: inout ActiveSession
    ) {
        var segmentStart = request.from
        var consumed = 0.0
        for _ in 0..<8 {
            guard segmentStart < request.date else { break }
            guard let day = localDay(for: segmentStart, offset: request.fromOffset),
                  let boundary = nextLocalMidnight(after: segmentStart, offset: request.fromOffset) else {
                break
            }
            let segmentEnd = min(boundary, request.date)
            let fraction = max(
                min(segmentEnd.timeIntervalSince(request.from) / request.wallDelta, 1),
                0
            )
            let amount = request.delta * max(fraction - consumed / request.delta, 0)
            if amount > 0 {
                addSlice(amount, day: day, offset: request.fromOffset, to: &session)
            }
            consumed += amount
            guard segmentEnd < request.date, segmentEnd > segmentStart else { break }
            segmentStart = segmentEnd
        }
        if consumed < request.delta {
            addSlice(
                request.delta - consumed,
                day: request.fallbackDay,
                offset: request.toOffset,
                to: &session
            )
        }
    }

    func addSlice(
        _ seconds: TimeInterval,
        day: ListeningLocalDay,
        offset: Int,
        to session: inout ActiveSession
    ) {
        guard seconds.isFinite, seconds > 0 else { return }
        let key = SliceKey(localDay: day, utcOffsetSeconds: offset)
        if let existing = session.daySlices[key] {
            session.daySlices[key] = min(existing + seconds, TimeInterval.greatestFiniteMagnitude)
            return
        }
        guard session.daySlices.count < Self.maximumDaySlices else {
            // Detail is capped; fold excess seconds into the earliest bucket so
            // total listened time stays exact while the dictionary stays bounded.
            session.daySliceOverflowed = true
            guard let foldKey = session.daySlices.keys.min(by: {
                if $0.localDay != $1.localDay { return $0.localDay < $1.localDay }
                return $0.utcOffsetSeconds < $1.utcOffsetSeconds
            }) else { return }
            let current = session.daySlices[foldKey] ?? 0
            session.daySlices[foldKey] = min(current + seconds, TimeInterval.greatestFiniteMagnitude)
            setPersistenceWarning(
                "Listening history day-slice detail exceeded its in-memory bound; "
                    + "excess time was folded into an existing day bucket."
            )
            return
        }
        session.daySlices[key] = seconds
    }

    func makeDaySlices(for session: ActiveSession) -> [ListeningDaySlice] {
        session.daySlices.keys.sorted {
            if $0.localDay != $1.localDay { return $0.localDay < $1.localDay }
            return $0.utcOffsetSeconds < $1.utcOffsetSeconds
        }.compactMap { key in
            guard let seconds = session.daySlices[key] else { return nil }
            return ListeningDaySlice(
                eventID: session.eventID,
                localDay: key.localDay,
                utcOffsetSeconds: key.utcOffsetSeconds,
                actualListenedSeconds: seconds
            )
        }
    }

    func qualificationOccurrence(
        threshold: TimeInterval,
        previousListenedSeconds: TimeInterval,
        delta: TimeInterval,
        from: Date,
        fromOffset: Int = 0,
        at date: Date,
        offset: Int = 0
    ) -> ListeningEventOccurrence? {
        let fraction = delta > 0
            ? max(min((threshold - previousListenedSeconds) / delta, 1), 0)
            : 1
        let wallDelta = date.timeIntervalSince(from)
        let crossingDate: Date
        let crossingOffset: Int
        if wallDelta > 0, wallDelta.isFinite, wallDelta <= 36 * 60 * 60 {
            crossingDate = from.addingTimeInterval(wallDelta * fraction)
            crossingOffset = fromOffset == offset
                ? offset
                : (fraction < 1 ? fromOffset : offset)
        } else {
            crossingDate = date
            crossingOffset = offset
        }
        return occurrence(at: crossingDate, offset: crossingOffset)
    }

    func occurrence(at date: Date, offset: Int) -> ListeningEventOccurrence? {
        guard let day = localDay(for: date, offset: offset) else { return nil }
        return ListeningEventOccurrence(timestampUTC: date, localDay: day, utcOffsetSeconds: offset)
    }

    func nextLocalMidnight(after date: Date, offset: Int) -> Date? {
        let localSeconds = date.timeIntervalSince1970 + Double(offset)
        let dayNumber = floor(localSeconds / 86_400)
        guard dayNumber.isFinite else { return nil }
        let utcSeconds = (dayNumber + 1) * 86_400 - Double(offset)
        guard utcSeconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: utcSeconds)
    }

    func localDay(for date: Date, offset: Int) -> ListeningLocalDay? {
        guard let timeZone = TimeZone(secondsFromGMT: offset) else { return nil }
        return ListeningLocalDay(date: date, timeZone: timeZone)
    }

    func makeSample(
        renderedPosition: TimeInterval?,
        isPlaying: Bool,
        observedAtUTC: Date,
        utcOffsetSeconds: Int?
    ) -> ListeningPlaybackSample? {
        let position = renderedPosition
            ?? valueState.activeSession?.lastRenderedPosition
            ?? valueState.playbackContext?.renderedPosition
            ?? 0
        return ListeningPlaybackSample(
            renderedPosition: position,
            isPlaying: isPlaying,
            observedAtUTC: observedAtUTC,
            utcOffsetSeconds: utcOffsetSeconds
        )
    }

    func updatePlaybackContext(with sample: ListeningPlaybackSample) {
        guard var context = valueState.playbackContext else { return }
        context.renderedPosition = normalizedPosition(sample.renderedPosition, duration: context.openedDuration)
        context.isPlaying = sample.isPlaying
        valueState.playbackContext = context
    }

    func normalizedDate(_ date: Date?) -> Date {
        let date = date ?? clock()
        return date.timeIntervalSinceReferenceDate.isFinite ? date : Date()
    }

    func normalizedOffset(_ offset: Int?, for date: Date) -> Int {
        if let offset, TimeZone(secondsFromGMT: offset) != nil { return offset }
        return TimeZone.current.secondsFromGMT(for: date)
    }

    func normalizedMonotonicTime(_ time: TimeInterval?) -> TimeInterval {
        let time = time ?? monotonicClock()
        return time.isFinite ? time : 0
    }

    func normalizedPosition(_ position: TimeInterval, duration: TimeInterval) -> TimeInterval {
        let position = position.isFinite ? max(position, 0) : 0
        guard duration.isFinite, duration > 0 else { return position }
        return min(position, duration)
    }
}
