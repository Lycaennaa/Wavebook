import Foundation
import GRDB
@testable import WavebookCore
import XCTest

@MainActor final class ListeningHistoryTrackerTests: XCTestCase {
    func testQualificationPersistsImmediatelyAndOnlyOnce() throws {
        let database = try LibraryDatabase(inMemory: true)
        let tracker = ListeningHistoryTracker(database: database)
        let start = Date(timeIntervalSince1970: 1_704_067_200)
        let eventID = try startTracker(tracker, database: database, at: start, duration: 60)
        XCTAssertEqual(try database.listeningHistoryHealth().eventCount, 1, tracker.persistenceWarning ?? "")

        tracker.sample(try sample(position: 10, at: start.addingTimeInterval(10)), monotonicTime: 10)
        tracker.sample(try sample(position: 30, at: start.addingTimeInterval(30)), monotonicTime: 30)
        tracker.sample(try sample(position: 40, at: start.addingTimeInterval(40)), monotonicTime: 40)

        let checkpointed = try XCTUnwrap(database.listeningEvent(id: eventID))
        XCTAssertNotNil(checkpointed.qualification)
        XCTAssertEqual(checkpointed.daySlices.reduce(0) { $0 + $1.actualListenedSeconds }, 30, accuracy: 0.0001)
        XCTAssertEqual(checkpointed.lastDurableCheckpointSequence, 1)
        XCTAssertTrue(
            tracker.endPlayback(
                reason: .stop,
                renderedPosition: 40,
                at: start.addingTimeInterval(40),
                monotonicTime: 40
            )
        )
        let event = try XCTUnwrap(database.listeningEvent(id: eventID))
        XCTAssertNotNil(event.qualification)
        XCTAssertEqual(
            event.qualification?.localDay,
            ListeningLocalDay(date: start.addingTimeInterval(40), timeZone: .current)
        )
        XCTAssertEqual(event.daySlices.reduce(0) { $0 + $1.actualListenedSeconds }, 40, accuracy: 0.0001)
    }

    func testPauseResumeAndSeekCountRenderedForwardTimeOnly() throws {
        let database = try LibraryDatabase(inMemory: true)
        let tracker = ListeningHistoryTracker(database: database)
        let start = Date(timeIntervalSince1970: 1_704_067_200)
        let eventID = try startTracker(tracker, database: database, at: start, duration: 60)

        tracker.sample(try sample(position: 10, at: start.addingTimeInterval(10)), monotonicTime: 10)
        tracker.prepareForSeek(renderedPosition: 10, at: start.addingTimeInterval(11), monotonicTime: 11)
        XCTAssertTrue(
            tracker.completeSeek(
                successfully: true,
                renderedPosition: 50,
                isPlaying: true,
                at: start.addingTimeInterval(11),
                monotonicTime: 11
            )
        )
        tracker.sample(try sample(position: 55, at: start.addingTimeInterval(16)), monotonicTime: 16)
        tracker.pause(renderedPosition: 55, at: start.addingTimeInterval(17), monotonicTime: 17)
        tracker.sample(
            try sample(position: 55, isPlaying: false, at: start.addingTimeInterval(100)),
            monotonicTime: 100
        )
        tracker.resume(renderedPosition: 55, at: start.addingTimeInterval(101), monotonicTime: 101)
        tracker.sample(try sample(position: 60, at: start.addingTimeInterval(106)), monotonicTime: 106)
        XCTAssertTrue(
            tracker.endPlayback(
                reason: .stop,
                renderedPosition: 60,
                at: start.addingTimeInterval(107),
                monotonicTime: 107
            )
        )

        let event = try XCTUnwrap(database.listeningEvent(id: eventID))
        XCTAssertEqual(event.daySlices.reduce(0) { $0 + $1.actualListenedSeconds }, 20, accuracy: 0.0001)
        XCTAssertNil(event.qualification)
        XCTAssertEqual(event.endReason, .stop)
    }

    func testPausedSessionStopsSamplingUntilResumed() throws {
        let database = try LibraryDatabase(inMemory: true)
        let tracker = ListeningHistoryTracker(database: database)
        defer { tracker.stopSampling() }
        let start = Date(timeIntervalSince1970: 1_704_067_200)
        _ = try startTracker(tracker, database: database, at: start, duration: 60)
        XCTAssertNotNil(tracker.samplingTimer)

        tracker.pause(renderedPosition: 5, at: start.addingTimeInterval(5), monotonicTime: 5)
        XCTAssertNil(tracker.samplingTimer)

        tracker.resume(renderedPosition: 5, at: start.addingTimeInterval(6), monotonicTime: 6)
        XCTAssertNotNil(tracker.samplingTimer)

        tracker.pause(renderedPosition: 5, at: start.addingTimeInterval(7), monotonicTime: 7)
        XCTAssertNil(tracker.samplingTimer)
    }

    func testPausedPersistenceFailureUsesOneShotRetry() throws {
        let database = try LibraryDatabase(inMemory: true)
        let tracker = ListeningHistoryTracker(database: database)
        defer {
            tracker.stopSampling()
            try? setWriteFailure(false, in: database)
        }
        let start = Date(timeIntervalSince1970: 1_704_067_200)
        _ = try startTracker(tracker, database: database, at: start, duration: 600)
        try setWriteFailure(true, in: database)

        tracker.pause(renderedPosition: 10, at: start.addingTimeInterval(10), monotonicTime: 10)

        XCTAssertEqual(tracker.pendingMutationCount, 1)
        XCTAssertNil(tracker.samplingTimer)
        XCTAssertNotNil(tracker.persistenceRetryTimer)

        let retryAt = tracker.valueState.persistence.retryAtUptime
        try setWriteFailure(false, in: database)
        tracker.retryIfDue(atUptime: retryAt)

        XCTAssertEqual(tracker.pendingMutationCount, 0)
        XCTAssertNil(tracker.samplingTimer)
        XCTAssertNil(tracker.persistenceRetryTimer)
    }

    func testDaySlicesSplitAcrossMidnightWithoutUsingWallTimeAsProgress() throws {
        let database = try LibraryDatabase(inMemory: true)
        let tracker = ListeningHistoryTracker(database: database)
        let start = try XCTUnwrap(currentLocalDate(DateComponents(
            year: 2024,
            month: 1,
            day: 1,
            hour: 23,
            minute: 59,
            second: 50
        )))
        let eventID = try startTracker(tracker, database: database, at: start, duration: 120)

        tracker.sample(try sample(position: 10, at: start.addingTimeInterval(20)), monotonicTime: 20)
        XCTAssertTrue(
            tracker.endPlayback(
                reason: .naturalCompletion,
                renderedPosition: 20,
                at: start.addingTimeInterval(40),
                monotonicTime: 40
            )
        )

        let event = try XCTUnwrap(database.listeningEvent(id: eventID))
        let slices = Dictionary(
            uniqueKeysWithValues: event.daySlices.map { ($0.localDay.rawValue, $0.actualListenedSeconds) }
        )
        XCTAssertEqual(try XCTUnwrap(slices["2024-01-01"]), 5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(slices["2024-01-02"]), 15, accuracy: 0.0001)
        XCTAssertEqual(slices.values.reduce(0, +), 20, accuracy: 0.0001)
    }

    func testDaySliceBoundPreservesListenedSeconds() throws {
        let database = try LibraryDatabase(inMemory: true)
        let tracker = ListeningHistoryTracker(database: database)
        let start = Date(timeIntervalSince1970: 1_704_067_200)
        let eventID = try startTracker(tracker, database: database, at: start, duration: 600)
        let finalPosition = Double(ListeningHistoryTracker.maximumDaySlices + 1)

        for index in 1...(ListeningHistoryTracker.maximumDaySlices + 1) {
            let value = Double(index)
            tracker.sample(
                try sample(position: value, at: start.addingTimeInterval(value * 2 * 86_400)),
                monotonicTime: value
            )
        }

        XCTAssertTrue(
            tracker.endPlayback(
                reason: .stop,
                renderedPosition: finalPosition,
                at: start.addingTimeInterval(finalPosition * 2 * 86_400),
                monotonicTime: finalPosition
            )
        )
        let event = try XCTUnwrap(database.listeningEvent(id: eventID))
        XCTAssertEqual(event.daySlices.reduce(0) { $0 + $1.actualListenedSeconds }, finalPosition, accuracy: 0.0001)
    }

    func testPrivateModeCreatesNoPrivateEventAndStartsFreshSessionWhenDisabled() throws {
        let database = try LibraryDatabase(inMemory: true)
        let tracker = ListeningHistoryTracker(database: database)
        let start = Date(timeIntervalSince1970: 1_704_067_200)
        let source = ListeningPlaybackSource(
            kind: .playlist,
            persistentID: 42,
            sourceName: "Road Trip"
        )
        let firstEventID = try startTracker(
            tracker,
            database: database,
            at: start,
            duration: 60,
            source: source
        )
        tracker.sample(try sample(position: 10, at: start.addingTimeInterval(10)), monotonicTime: 10)

        XCTAssertTrue(
            tracker.setPrivateMode(
                true,
                renderedPosition: 10,
                at: start.addingTimeInterval(10),
                monotonicTime: 10
            )
        )
        XCTAssertTrue(tracker.isPrivateMode)
        XCTAssertNil(tracker.activeEventID)
        XCTAssertEqual(try database.listeningHistoryHealth().eventCount, 1)
        XCTAssertNil(try database.listeningEvent(id: firstEventID)?.skip)
        XCTAssertEqual(try database.listeningEvent(id: firstEventID)?.source, source)

        XCTAssertEqual(
            tracker.startPlayback(
                track: try makeTrack(in: database),
                openedDuration: 60,
                openedFormat: "flac",
                source: source,
                at: start.addingTimeInterval(11),
                monotonicTime: 11
            ),
            .privateMode
        )
        XCTAssertTrue(
            tracker.setPrivateMode(
                false,
                renderedPosition: 3,
                isPlaying: false,
                at: start.addingTimeInterval(20),
                monotonicTime: 20
            )
        )
        XCTAssertFalse(tracker.isPrivateMode)
        guard let secondEventID = tracker.activeEventID else {
            return XCTFail("disabling private mode must start a fresh session")
        }
        XCTAssertEqual(try XCTUnwrap(database.listeningEvent(id: secondEventID)?.startPosition), 3, accuracy: 0.0001)
        XCTAssertEqual(try database.listeningEvent(id: secondEventID)?.source, source)
        tracker.sample(try sample(position: 20, at: start.addingTimeInterval(30)), monotonicTime: 30)
        XCTAssertNil(try database.listeningEvent(id: secondEventID)?.qualification)
    }

    func testResetInvalidatesActiveSessionAndStartsAtCurrentPosition() throws {
        let database = try LibraryDatabase(inMemory: true)
        let tracker = ListeningHistoryTracker(database: database)
        let start = Date(timeIntervalSince1970: 1_704_067_200)
        _ = try startTracker(tracker, database: database, at: start, duration: 60)
        tracker.sample(try sample(position: 10, at: start.addingTimeInterval(10)), monotonicTime: 10)

        let reset = start.addingTimeInterval(100)
        XCTAssertTrue(tracker.resetHistory(at: reset, renderedPosition: 10, isPlaying: true, monotonicTime: 100))
        XCTAssertEqual(try database.listeningHistoryState().generation, 1)
        XCTAssertEqual(try database.listeningHistoryHealth().eventCount, 1)
        let activeID = try XCTUnwrap(tracker.activeEventID)
        tracker.sample(try sample(position: 20, at: reset.addingTimeInterval(10)), monotonicTime: 110)
        XCTAssertTrue(
            tracker.endPlayback(
                reason: .stop,
                renderedPosition: 20,
                at: reset.addingTimeInterval(11),
                monotonicTime: 111
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(
                database.listeningEvent(id: activeID)?.daySlices.reduce(0) { $0 + $1.actualListenedSeconds }
            ),
            10,
            accuracy: 0.0001
        )
    }

    func testResetFailureRestoresActiveSessionValueState() throws {
        let database = try LibraryDatabase(inMemory: true)
        let tracker = ListeningHistoryTracker(database: database)
        let start = Date(timeIntervalSince1970: 1_704_067_200)
        let eventID = try startTracker(tracker, database: database, at: start, duration: 600)
        tracker.sample(try sample(position: 10, at: start.addingTimeInterval(10)), monotonicTime: 10)

        try setWriteFailure(true, in: database)
        defer { try? setWriteFailure(false, in: database) }
        XCTAssertFalse(
            tracker.resetHistory(
                at: start.addingTimeInterval(20),
                renderedPosition: 10,
                isPlaying: true,
                monotonicTime: 20
            )
        )

        XCTAssertEqual(tracker.historyGeneration, 0)
        XCTAssertEqual(tracker.activeEventID, eventID)
        XCTAssertNotNil(tracker.samplingTimer)

        try setWriteFailure(false, in: database)
        XCTAssertTrue(
            tracker.endPlayback(
                reason: .stop,
                renderedPosition: 15,
                at: start.addingTimeInterval(25),
                monotonicTime: 25
            )
        )
        let event = try XCTUnwrap(database.listeningEvent(id: eventID))
        XCTAssertEqual(event.daySlices.reduce(0) { $0 + $1.actualListenedSeconds }, 15, accuracy: 0.0001)
        XCTAssertNil(tracker.persistenceWarning)
    }

    func testPendingCheckpointRetrySurvivesResetRollback() throws {
        let database = try LibraryDatabase(inMemory: true)
        let tracker = ListeningHistoryTracker(database: database)
        let start = Date(timeIntervalSince1970: 1_704_067_200)
        let eventID = try startTracker(tracker, database: database, at: start, duration: 600)

        try setWriteFailure(true, in: database)
        defer { try? setWriteFailure(false, in: database) }
        tracker.pause(
            renderedPosition: 10,
            at: start.addingTimeInterval(10),
            utcOffsetSeconds: 0,
            monotonicTime: 10
        )
        XCTAssertEqual(tracker.pendingMutationCount, 1)

        XCTAssertFalse(
            tracker.resetHistory(
                at: start.addingTimeInterval(10.5),
                renderedPosition: 10,
                isPlaying: false,
                utcOffsetSeconds: 0,
                monotonicTime: 10.5
            )
        )
        XCTAssertEqual(tracker.activeEventID, eventID)
        XCTAssertEqual(tracker.pendingMutationCount, 1)

        try setWriteFailure(false, in: database)
        tracker.sample(
            try sample(position: 10, isPlaying: false, at: start.addingTimeInterval(10.75)),
            monotonicTime: 10.75
        )
        XCTAssertEqual(tracker.pendingMutationCount, 1)
        tracker.sample(
            try sample(position: 10, isPlaying: false, at: start.addingTimeInterval(11)),
            monotonicTime: 11
        )

        XCTAssertEqual(tracker.pendingMutationCount, 0)
        XCTAssertNil(tracker.persistenceWarning)
        let checkpointed = try XCTUnwrap(database.listeningEvent(id: eventID))
        XCTAssertEqual(checkpointed.daySlices.reduce(0) { $0 + $1.actualListenedSeconds }, 10, accuracy: 0.0001)
        XCTAssertTrue(
            tracker.endPlayback(
                reason: .stop,
                renderedPosition: 10,
                isPlaying: false,
                at: start.addingTimeInterval(12),
                monotonicTime: 12
            )
        )
    }
}

extension ListeningHistoryTrackerTests {
    func testResetRollbackPreservesRecoveryRetryState() throws {
        let database = try LibraryDatabase(inMemory: true)
        let crashed = ListeningHistoryTracker(database: database)
        let start = Date(timeIntervalSince1970: 1_704_067_200)
        let eventID = try startTracker(crashed, database: database, at: start, duration: 600)
        crashed.stopSampling()

        try setWriteFailure(true, in: database)
        let tracker = ListeningHistoryTracker(database: database)
        defer {
            tracker.stopSampling()
            try? setWriteFailure(false, in: database)
        }
        XCTAssertNotNil(tracker.persistenceWarning)

        XCTAssertFalse(
            tracker.resetHistory(
                at: start.addingTimeInterval(20),
                monotonicTime: 20
            )
        )
        XCTAssertNotNil(tracker.persistenceWarning)

        try setWriteFailure(false, in: database)
        tracker.attemptRecovery(atUptime: TimeInterval.greatestFiniteMagnitude)
        XCTAssertTrue(tracker.isPersistenceHealthy)
        XCTAssertNil(tracker.persistenceWarning)
        XCTAssertEqual(try database.listeningEvent(id: eventID)?.endReason, .abandoned)
    }

    func testResetCommitClearsPendingRetryBeforeFreshSession() throws {
        let database = try LibraryDatabase(inMemory: true)
        let tracker = ListeningHistoryTracker(database: database)
        let start = Date(timeIntervalSince1970: 1_704_067_200)
        let oldEventID = try startTracker(tracker, database: database, at: start, duration: 600)

        try setWriteFailure(true, in: database)
        tracker.pause(
            renderedPosition: 10,
            at: start.addingTimeInterval(10),
            utcOffsetSeconds: 0,
            monotonicTime: 10
        )
        XCTAssertEqual(tracker.pendingMutationCount, 1)

        try setWriteFailure(false, in: database)
        XCTAssertTrue(
            tracker.resetHistory(
                at: start.addingTimeInterval(20),
                renderedPosition: 10,
                isPlaying: false,
                utcOffsetSeconds: 0,
                monotonicTime: 20
            )
        )

        XCTAssertEqual(tracker.pendingMutationCount, 0)
        XCTAssertNil(tracker.persistenceWarning)
        XCTAssertTrue(tracker.isPersistenceHealthy)
        let freshEventID = try XCTUnwrap(tracker.activeEventID)
        XCTAssertNotEqual(freshEventID, oldEventID)
        XCTAssertEqual(try database.listeningHistoryHealth().eventCount, 1)
        XCTAssertTrue(
            tracker.endPlayback(
                reason: .stop,
                renderedPosition: 10,
                isPlaying: false,
                at: start.addingTimeInterval(21),
                monotonicTime: 21
            )
        )
    }

    func testTerminationFlushRetriesTransientWriteFailureWithoutLosingSkip() throws {
        let database = try LibraryDatabase(inMemory: true)
        let tracker = ListeningHistoryTracker(database: database)
        let start = Date(timeIntervalSince1970: 1_704_067_200)
        let eventID = try startTracker(tracker, database: database, at: start, duration: 600)
        tracker.sample(try sample(position: 10, at: start.addingTimeInterval(10)), monotonicTime: 10)
        try setQueryOnly(true, in: database)
        XCTAssertTrue(
            tracker.endPlayback(
                reason: .next,
                renderedPosition: 10,
                at: start.addingTimeInterval(11),
                monotonicTime: 11
            )
        )
        XCTAssertEqual(tracker.pendingMutationCount, 1)
        var terminationSucceeded: Bool?
        tracker.terminate(at: start.addingTimeInterval(12), monotonicTime: 12) { terminationSucceeded = $0 }
        XCTAssertNil(terminationSucceeded)
        try setQueryOnly(false, in: database)
        tracker.flushTermination(atUptime: 12.1)
        XCTAssertEqual(terminationSucceeded, true)
        XCTAssertEqual(tracker.pendingMutationCount, 0)
        let event = try XCTUnwrap(database.listeningEvent(id: eventID))
        XCTAssertEqual(event.endReason, .next)
        XCTAssertNotNil(event.skip)
        XCTAssertEqual(event.daySlices.reduce(0) { $0 + $1.actualListenedSeconds }, 10, accuracy: 0.0001)
    }
    func testTerminationFlushDeadlineCancelsAndRetainsPendingMutation() throws {
        let database = try LibraryDatabase(inMemory: true)
        let tracker = ListeningHistoryTracker(database: database)
        let start = Date(timeIntervalSince1970: 1_704_067_200)
        let eventID = try startTracker(tracker, database: database, at: start, duration: 600)
        tracker.sample(try sample(position: 10, at: start.addingTimeInterval(10)), monotonicTime: 10)
        try setQueryOnly(true, in: database)
        XCTAssertTrue(
            tracker.endPlayback(
                reason: .next,
                renderedPosition: 10,
                at: start.addingTimeInterval(11),
                monotonicTime: 11
            )
        )

        var terminationSucceeded: Bool?
        tracker.terminate(at: start.addingTimeInterval(12), monotonicTime: 12) { terminationSucceeded = $0 }
        tracker.flushTermination(atUptime: 12 + ListeningHistoryTracker.terminationFlushTimeout)

        XCTAssertEqual(terminationSucceeded, false)
        XCTAssertEqual(tracker.pendingMutationCount, 1)
        XCTAssertNil(try database.listeningEvent(id: eventID)?.endReason)
        tracker.stopSampling()
        try setQueryOnly(false, in: database)
    }
}
