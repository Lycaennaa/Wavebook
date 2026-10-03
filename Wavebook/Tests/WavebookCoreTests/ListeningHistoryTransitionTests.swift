@testable import WavebookCore
import XCTest

// Phase 4: proves explicit playback transition sequences end-to-end through
// the same tracker calls MainViewController makes for each transition.
@MainActor final class ListeningHistoryTransitionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_704_067_200)

    func testNaturalCompletionThenRepeatPassCreatesTwoDistinctNonSkipSessions() throws {
        let database = try LibraryDatabase(inMemory: true)
        let tracker = ListeningHistoryTracker(database: database)
        let track = try makeTrack(in: database)

        let first = try startSession(tracker, track: track, duration: 60)
        tracker.sample(try sample(position: 20, at: start.addingTimeInterval(20)), monotonicTime: 20)
        // playbackFinished(): commit final delta with .naturalCompletion before queue advances.
         XCTAssertTrue(
             tracker.endPlayback(
                 reason: .naturalCompletion,
                 renderedPosition: 60,
                 at: start.addingTimeInterval(60),
                 monotonicTime: 60
             )
         )

        // Automatic repeat/queue advancement starts a new session; not a skip.
         let second = try startSession(
             tracker,
             track: track,
             duration: 60,
             at: start.addingTimeInterval(61),
             monotonicTime: 61
         )
        tracker.endPlayback(reason: .stop, renderedPosition: 70, at: start.addingTimeInterval(70), monotonicTime: 70)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try database.listeningHistoryHealth().eventCount, 2)
        let firstEvent = try XCTUnwrap(database.listeningEvent(id: first))
        XCTAssertEqual(firstEvent.endReason, .naturalCompletion)
        XCTAssertNil(firstEvent.skip)
        XCTAssertNotNil(firstEvent.qualification)
        let secondEvent = try XCTUnwrap(database.listeningEvent(id: second))
        XCTAssertNil(secondEvent.skip)
    }

    func testExplicitNextMarksSkipOnlyAfterFiveSecondsListened() throws {
        let database = try LibraryDatabase(inMemory: true)
        let tracker = ListeningHistoryTracker(database: database)
        let track = try makeTrack(in: database)

        let short = try startSession(tracker, track: track, duration: 600)
        tracker.sample(try sample(position: 4.9, at: start.addingTimeInterval(4.9)), monotonicTime: 4.9)
         XCTAssertTrue(
             tracker.endPlayback(
                 reason: .next,
                 renderedPosition: 4.9,
                 at: start.addingTimeInterval(5),
                 monotonicTime: 5
             )
         )
        XCTAssertNil(try database.listeningEvent(id: short)?.skip)

         let long = try startSession(
             tracker,
             track: track,
             duration: 600,
             at: start.addingTimeInterval(6),
             monotonicTime: 6
         )
        tracker.sample(try sample(position: 5, at: start.addingTimeInterval(11)), monotonicTime: 11)
         XCTAssertTrue(
             tracker.endPlayback(
                 reason: .next,
                 renderedPosition: 5,
                 at: start.addingTimeInterval(12),
                 monotonicTime: 12
             )
         )
        XCTAssertNotNil(try database.listeningEvent(id: long)?.skip)
        XCTAssertNil(try database.listeningEvent(id: long)?.qualification)
    }

    func testPlayPlusExplicitNextQualifiesAndSkipsSameSession() throws {
        let database = try LibraryDatabase(inMemory: true)
        let tracker = ListeningHistoryTracker(database: database)
        let track = try makeTrack(in: database)

        let eventID = try startSession(tracker, track: track, duration: 60)
        tracker.sample(try sample(position: 35, at: start.addingTimeInterval(35)), monotonicTime: 35)
         XCTAssertTrue(
             tracker.endPlayback(
                 reason: .next,
                 renderedPosition: 35,
                 at: start.addingTimeInterval(36),
                 monotonicTime: 36
             )
         )

        let event = try XCTUnwrap(database.listeningEvent(id: eventID))
        XCTAssertNotNil(event.qualification)
        XCTAssertNotNil(event.skip)
    }

    func testSameTrackRestartIsNotASkipAndDifferentSelectionIs() throws {
        let database = try LibraryDatabase(inMemory: true)
        let tracker = ListeningHistoryTracker(database: database)
        let track = try makeTrack(in: database)

        let restart = try startSession(tracker, track: track, duration: 600)
        tracker.sample(try sample(position: 30, at: start.addingTimeInterval(30)), monotonicTime: 30)
         XCTAssertTrue(
             tracker.endPlayback(
                 reason: .sameTrackRestart,
                 renderedPosition: 0,
                 at: start.addingTimeInterval(31),
                 monotonicTime: 31
             )
         )
        let restartEvent = try XCTUnwrap(database.listeningEvent(id: restart))
        XCTAssertEqual(restartEvent.endReason, .sameTrackRestart)
        XCTAssertNil(restartEvent.skip)

        let selection = try startSession(tracker, track: track, duration: 600, initialPosition: 0)
        tracker.sample(try sample(position: 10, at: start.addingTimeInterval(41)), monotonicTime: 41)
         XCTAssertTrue(
             tracker.endPlayback(
                 reason: .differentTrackSelection,
                 renderedPosition: 10,
                 at: start.addingTimeInterval(42),
                 monotonicTime: 42
             )
         )
        let selectionEvent = try XCTUnwrap(database.listeningEvent(id: selection))
        XCTAssertEqual(selectionEvent.endReason, .differentTrackSelection)
        XCTAssertNotNil(selectionEvent.skip)
    }

    func testFailedNavigationLeavesActiveSessionIntact() throws {
        let database = try LibraryDatabase(inMemory: true)
        let tracker = ListeningHistoryTracker(database: database)
        let track = try makeTrack(in: database)

        let eventID = try startSession(tracker, track: track, duration: 60)
        tracker.sample(try sample(position: 10, at: start.addingTimeInterval(10)), monotonicTime: 10)

        // Failed next (no queue item) never reaches the tracker; a replacement
        // session must not be creatable and the original stays active.
         XCTAssertEqual(
             tracker.startPlayback(
                 track: track,
                 openedDuration: 60,
                 openedFormat: "flac",
                 at: start.addingTimeInterval(11),
                 monotonicTime: 11
             ),
             .activeSessionExists
         )
         XCTAssertEqual(tracker.activeEventID, eventID)

         tracker.sample(try sample(position: 40, at: start.addingTimeInterval(40)), monotonicTime: 40)
         XCTAssertTrue(
             tracker.endPlayback(
                 reason: .stop,
                 renderedPosition: 40,
                 at: start.addingTimeInterval(41),
                 monotonicTime: 41
             )
         )
         let event = try XCTUnwrap(database.listeningEvent(id: eventID))
         XCTAssertEqual(event.daySlices.reduce(0) { $0 + $1.actualListenedSeconds }, 40, accuracy: 0.0001)
         XCTAssertNil(event.skip)
     }

    func testDeviceRecoveryDropsRenderedPositionWithoutInflatingListenedTime() throws {
        let database = try LibraryDatabase(inMemory: true)
        let tracker = ListeningHistoryTracker(database: database)
        let track = try makeTrack(in: database)

        let eventID = try startSession(tracker, track: track, duration: 60)
        tracker.sample(try sample(position: 10, at: start.addingTimeInterval(10)), monotonicTime: 10)
        // Engine reconfiguration rebases the player to ~8s rendered; the
        // negative delta is ignored and later progress counts from there.
        tracker.sample(try sample(position: 8, at: start.addingTimeInterval(11)), monotonicTime: 11)
        tracker.sample(try sample(position: 13, at: start.addingTimeInterval(16)), monotonicTime: 16)
        tracker.sample(try sample(position: 33, at: start.addingTimeInterval(36)), monotonicTime: 36)

         XCTAssertTrue(
             tracker.endPlayback(
                 reason: .stop,
                 renderedPosition: 33,
                 at: start.addingTimeInterval(37),
                 monotonicTime: 37
             )
         )
        let event = try XCTUnwrap(database.listeningEvent(id: eventID))
        // 10 + 0 + 5 + 20 = 35 rendered seconds; the 2-second drop is not counted.
        XCTAssertEqual(event.daySlices.reduce(0) { $0 + $1.actualListenedSeconds }, 35, accuracy: 0.0001)
        XCTAssertNotNil(event.qualification)
        XCTAssertEqual(event.endReason, .stop)
    }

    func testRelaunchFinalizesOpenEventAsAbandonedIdempotently() throws {
        let database = try LibraryDatabase(inMemory: true)
        let crashed = ListeningHistoryTracker(database: database)
        let eventID = try startSession(crashed, track: try makeTrack(in: database), duration: 600)
        crashed.sample(try sample(position: 25, at: start.addingTimeInterval(25)), monotonicTime: 25)

        // Relaunch: new tracker recovers the open event at its last checkpoint.
        let relaunched = ListeningHistoryTracker(database: database)
        let recovered = try XCTUnwrap(database.listeningEvent(id: eventID))
        XCTAssertEqual(recovered.endReason, .abandoned)
        XCTAssertEqual(recovered.daySlices.reduce(0) { $0 + $1.actualListenedSeconds }, 25, accuracy: 0.0001)

        _ = relaunched
        let again = try XCTUnwrap(database.listeningEvent(id: eventID))
        XCTAssertEqual(again.endReason, .abandoned)
        XCTAssertEqual(again.daySlices.reduce(0) { $0 + $1.actualListenedSeconds }, 25, accuracy: 0.0001)
        XCTAssertNil(again.skip)
    }

    // MARK: - Helpers

    private func startSession(
        _ tracker: ListeningHistoryTracker,
        track: Track,
        duration: TimeInterval,
        at date: Date? = nil,
        monotonicTime: TimeInterval = 0,
        initialPosition: TimeInterval = 0
    ) throws -> UUID {
        guard case let .started(eventID) = tracker.startPlayback(
            track: track,
            openedDuration: duration,
            openedFormat: "flac",
            initialPosition: initialPosition,
            at: date ?? start,
            utcOffsetSeconds: 0,
            monotonicTime: monotonicTime
        ) else {
            throw NSError(domain: "ListeningHistoryTransitionTests", code: 1)
        }
        return eventID
    }

    private func sample(position: TimeInterval, at date: Date) throws -> ListeningPlaybackSample {
        try XCTUnwrap(ListeningPlaybackSample(
            renderedPosition: position,
            isPlaying: true,
            observedAtUTC: date,
            utcOffsetSeconds: 0
        ))
    }

    private func makeTrack(in database: LibraryDatabase) throws -> Track {
        var track = Track(
            path: "/music/song.flac",
            title: "Song",
            artistDisplay: "Artist",
            albumTitle: "Album",
            albumArtist: "Artist",
            genreDisplay: "Genre",
            duration: 60,
            format: "flac"
        )
        let rootID = try database.addRoot(path: "/music")
        track.id = try database.save(track: track, rootID: rootID)
        return track
    }
}
