import Foundation
@testable import WavebookCore
import XCTest

extension ListeningHistoryTests {
    func testDatabasePersistsEventsSlicesQueriesAndReusesSnapshots() throws {
        let fixture = try makeDatabasePersistenceFixture()
        let database = fixture.database
        let generation = try database.listeningHistoryState().generation

        XCTAssertEqual(
            try database.finishListeningEvent(
                request: .init(
                    eventID: fixture.eventID,
                    expectedGeneration: generation,
                    endedAtUTC: fixture.start.addingTimeInterval(13),
                    endReason: .next,
                    details: .init(
                        endedUTCOffsetSeconds: fixture.utcOffsetSeconds,
                        endPosition: 13,
                        daySlices: fixture.slices,
                        qualification: fixture.qualification,
                        skip: fixture.skip
                    )
                )
            ),
            .applied
        )
        XCTAssertEqual(
            try database.finishListeningEvent(
                request: .init(
                    eventID: fixture.eventID,
                    expectedGeneration: generation,
                    endedAtUTC: fixture.start.addingTimeInterval(13),
                    endReason: .next,
                    details: .init(
                        endedUTCOffsetSeconds: fixture.utcOffsetSeconds,
                        endPosition: 13,
                        daySlices: fixture.slices,
                        qualification: fixture.qualification,
                        skip: fixture.skip
                    )
                )
            ),
            .applied
        )

        try assertDatabasePersistenceQueries(fixture)
    }

    func testDaySliceUpsertRejectsFinishedEventWithoutChangingStoredSlice() throws {
        let database = try LibraryDatabase(inMemory: true)
        let storedSnapshot = try makeDatabaseSnapshot(in: database)
        let state = try database.listeningHistoryState()
        let eventID = UUID()
        let start = Date(timeIntervalSince1970: 100)
        let day = try XCTUnwrap(ListeningLocalDay("1970-01-01"))
        let slice = ListeningDaySlice(eventID: eventID, localDay: day, utcOffsetSeconds: 0, actualListenedSeconds: 4)

        XCTAssertEqual(
            try database.beginListeningEvent(
                eventID: eventID,
                expectedGeneration: state.generation,
                snapshotID: try XCTUnwrap(storedSnapshot.id),
                startedAtUTC: start
            ),
            .applied
        )
        XCTAssertEqual(
            try database.upsertListeningEventDaySlice(
                eventID: eventID,
                expectedGeneration: state.generation,
                localDay: day,
                utcOffsetSeconds: 0,
                actualListenedSeconds: 4
            ),
            .applied
        )
        XCTAssertEqual(
            try database.finishListeningEvent(
                request: .init(
                    eventID: eventID,
                    expectedGeneration: state.generation,
                    endedAtUTC: start.addingTimeInterval(1),
                    endReason: .stop,
                    details: .init(
                        endedUTCOffsetSeconds: 0,
                        endPosition: 4,
                        daySlices: [slice]
                    )
                )
            ),
            .applied
        )

        XCTAssertThrowsError(
            try database.upsertListeningEventDaySlice(
                eventID: eventID,
                expectedGeneration: state.generation,
                localDay: day,
                utcOffsetSeconds: 0,
                actualListenedSeconds: 8
            )
        ) { error in
            XCTAssertEqual(error as? LibraryDatabaseError, .listeningEventAlreadyFinished(eventID))
        }
        XCTAssertEqual(
            try database.listeningEventDaySlice(eventID: eventID, localDay: day, utcOffsetSeconds: 0),
            4
        )
    }

    func testDatabasePrivateModeAndResetRejectStaleMutations() throws {
        let database = try LibraryDatabase(inMemory: true)
        let storedSnapshot = try makeDatabaseSnapshot(in: database)
        let state = try database.saveListeningHistoryPrivateMode(true)
        XCTAssertTrue(state.isPrivate)
         XCTAssertEqual(
             try database.beginListeningEvent(
                 expectedGeneration: state.generation,
                 snapshotID: try XCTUnwrap(storedSnapshot.id)
             ),
             .privateMode
         )
        let enabledEvent = UUID()
         XCTAssertEqual(
             try database.beginListeningEvent(
                 eventID: enabledEvent,
                 expectedGeneration: state.generation,
                 snapshotID: try XCTUnwrap(storedSnapshot.id)
             ),
             .privateMode
         )

        let reset = try database.resetListeningHistory(at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(reset.generation, state.generation + 1)
        XCTAssertTrue(reset.isPrivate)
        XCTAssertNil(try database.listeningEvent(id: enabledEvent))
        XCTAssertEqual(try database.listeningStatisticsSummary(), ListeningStatisticsSummary())
        XCTAssertEqual(try database.listeningHistoryHealth().snapshotCount, 0)
    }

    func testDatabaseCheckpointIsIdempotentAndRecoveryUsesLastDurableState() throws {
        let fixture = try makeCheckpointFixture()
        try assertInvalidCheckpoint(fixture)
        try assertRepeatedCheckpoint(fixture)
        try assertSeekCheckpointAndRecovery(fixture)
    }

    private struct DatabasePersistenceFixture {
        let database: LibraryDatabase
        let eventID: UUID
        let start: Date
        let day: ListeningLocalDay
        let utcOffsetSeconds: Int
        let qualification: ListeningEventOccurrence
        let skip: ListeningEventOccurrence
        let slices: [ListeningDaySlice]
    }

    private func makeDatabasePersistenceFixture() throws -> DatabasePersistenceFixture {
         let database = try LibraryDatabase(inMemory: true)
         let first = try makeDatabasePersistenceSnapshot(in: database)

        let state = try database.listeningHistoryState()
        let eventID = UUID()
        let start = Date(timeIntervalSince1970: 1_704_110_400)
        let day = try XCTUnwrap(ListeningLocalDay(date: start.addingTimeInterval(12), timeZone: .current))
        let utcOffsetSeconds = TimeZone.current.secondsFromGMT(for: start.addingTimeInterval(12))
        let qualification = try XCTUnwrap(ListeningEventOccurrence(
            timestampUTC: start.addingTimeInterval(12),
            localDay: day,
            utcOffsetSeconds: utcOffsetSeconds
        ))
        let skip = try XCTUnwrap(ListeningEventOccurrence(
            timestampUTC: start.addingTimeInterval(13),
            localDay: day,
            utcOffsetSeconds: utcOffsetSeconds
        ))
        let slices = [
            ListeningDaySlice(
                eventID: eventID,
                localDay: day,
                utcOffsetSeconds: utcOffsetSeconds,
                actualListenedSeconds: 12
            )
        ]
        XCTAssertEqual(
            try database.beginListeningEvent(
                eventID: eventID,
                expectedGeneration: state.generation,
                snapshotID: try XCTUnwrap(first.id),
                startedAtUTC: start,
                startedUTCOffsetSeconds: utcOffsetSeconds
            ),
            .applied
        )
        return DatabasePersistenceFixture(
            database: database,
            eventID: eventID,
            start: start,
            day: day,
            utcOffsetSeconds: utcOffsetSeconds,
            qualification: qualification,
            skip: skip,
            slices: slices
        )
    }

    private func assertDatabasePersistenceQueries(_ fixture: DatabasePersistenceFixture) throws {
        let database = fixture.database
        let summary = try database.listeningStatisticsSummary(year: 2024)
        XCTAssertEqual(summary.qualifiedPlayCount, 1)
        XCTAssertEqual(summary.listenedSeconds, 12)
        XCTAssertEqual(summary.uniqueSongCount, 1)
        XCTAssertEqual(summary.uniqueArtistCount, 2)
        XCTAssertEqual(summary.skipCount, 1)
        XCTAssertEqual(try database.listeningStatisticsSummary(day: fixture.day), summary)
        XCTAssertEqual(
            try database.listeningRankings(dimension: .artist, year: 2024).map(\.displayName),
            ["Artist A", "Artist B"]
        )
        XCTAssertEqual(
            try database.listeningRankings(dimension: .genre, year: 2024).map(\.displayName),
            ["Pop", "Rock"]
        )
        XCTAssertEqual(try database.listeningSkippedSongs(year: 2024).first?.skipCount, 1)
        XCTAssertEqual(try database.listeningHeatmap(year: 2024).count, 366)
        XCTAssertEqual(try database.availableListeningYears(), [2024])
        let page = try database.qualifiedPlayTimeline(day: fixture.day)
        XCTAssertEqual(page.entries.map(\.eventID), [fixture.eventID])
        XCTAssertNil(page.nextCursor)
        let stored = try XCTUnwrap(database.listeningEvent(id: fixture.eventID))
        XCTAssertEqual(stored.endReason, .next)
        XCTAssertEqual(stored.daySlices.first?.actualListenedSeconds, 12)
    }
    private struct CheckpointFixture {
        let database: LibraryDatabase
        let generation: Int64
        let eventID: UUID
        let start: Date
        let slices: [ListeningDaySlice]
        let invalidQualification: ListeningEventOccurrence
    }

     private func makeDatabasePersistenceSnapshot(in database: LibraryDatabase) throws -> ListeningMediaSnapshot {
         var track = Track(
             path: "/music/song.flac",
             title: "Song",
             artistDisplay: "Artist A; Artist B",
             albumTitle: "Album",
             albumArtist: nil,
             genreDisplay: "Rock; Pop",
             duration: 90,
             format: "flac"
         )
         let rootID = try database.addRoot(path: "/music")
         track.id = try database.save(track: track, rootID: rootID)
         let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
         let first = try database.createOrReuseListeningSnapshot(
             track: track,
             openedDuration: 20,
             openedFormat: "flac",
             createdAtUTC: createdAt,
             expectedGeneration: 0
         )
         let reused = try database.createOrReuseListeningSnapshot(
             track: track,
             openedDuration: 20,
             openedFormat: "flac",
             createdAtUTC: createdAt.addingTimeInterval(10),
             expectedGeneration: 0
         )
         XCTAssertEqual(first, reused)
         return first
     }
    private func makeCheckpointFixture() throws -> CheckpointFixture {
        let database = try LibraryDatabase(inMemory: true)
        let storedSnapshot = try makeDatabaseSnapshot(in: database)
        let state = try database.listeningHistoryState()
        let eventID = UUID()
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(
            try database.beginListeningEvent(
                eventID: eventID,
                expectedGeneration: state.generation,
                snapshotID: try XCTUnwrap(storedSnapshot.id),
                startedAtUTC: start
            ),
            .applied
        )
        let day = try XCTUnwrap(ListeningLocalDay("1970-01-01"))
        let slices = [
            ListeningDaySlice(
                eventID: eventID,
                localDay: day,
                utcOffsetSeconds: 0,
                actualListenedSeconds: 4
            )
        ]
        let invalidQualification = try XCTUnwrap(
            ListeningEventOccurrence(
                timestampUTC: start.addingTimeInterval(4),
                localDay: day,
                utcOffsetSeconds: 0
            )
        )
        return CheckpointFixture(
            database: database,
            generation: state.generation,
            eventID: eventID,
            start: start,
            slices: slices,
            invalidQualification: invalidQualification
        )
    }

    private func assertInvalidCheckpoint(_ fixture: CheckpointFixture) throws {
        XCTAssertThrowsError(
            try fixture.database.finishListeningEvent(
                request: .init(
                    eventID: fixture.eventID,
                    expectedGeneration: fixture.generation,
                    endedAtUTC: fixture.start.addingTimeInterval(4),
                    endReason: .naturalCompletion,
                    details: .init(
                        endedUTCOffsetSeconds: 0,
                        endPosition: 4,
                        daySlices: fixture.slices,
                        qualification: fixture.invalidQualification
                    )
                )
            )
        )
        XCTAssertTrue(try XCTUnwrap(fixture.database.listeningEvent(id: fixture.eventID)).daySlices.isEmpty)
        XCTAssertEqual(
            try fixture.database.checkpointListeningEvent(
                eventID: fixture.eventID,
                expectedGeneration: fixture.generation,
                checkpointAtUTC: fixture.start.addingTimeInterval(4),
                renderedPosition: 4,
                daySlices: fixture.slices
            ),
            .applied
        )
    }

    private func assertRepeatedCheckpoint(_ fixture: CheckpointFixture) throws {
        let day = try XCTUnwrap(ListeningLocalDay("1970-01-01"))
        let slices = [
            ListeningDaySlice(
                eventID: fixture.eventID,
                localDay: day,
                utcOffsetSeconds: 0,
                actualListenedSeconds: 5
            )
        ]
        for _ in 0..<2 {
            XCTAssertEqual(
                try fixture.database.checkpointListeningEvent(
                    eventID: fixture.eventID,
                    expectedGeneration: fixture.generation,
                    checkpointAtUTC: fixture.start.addingTimeInterval(3),
                    renderedPosition: 5,
                    daySlices: slices,
                    checkpointSequence: 1
                ),
                .applied
            )
        }
    }

    private func assertSeekCheckpointAndRecovery(_ fixture: CheckpointFixture) throws {
        let day = try XCTUnwrap(ListeningLocalDay("1970-01-01"))
        let slices = [
            ListeningDaySlice(
                eventID: fixture.eventID,
                localDay: day,
                utcOffsetSeconds: 0,
                actualListenedSeconds: 5
            )
        ]
        XCTAssertEqual(
            try fixture.database.checkpointListeningEvent(
                eventID: fixture.eventID,
                expectedGeneration: fixture.generation,
                checkpointAtUTC: fixture.start.addingTimeInterval(2),
                renderedPosition: 1,
                daySlices: slices,
                qualification: nil,
                checkpointUTCOffsetSeconds: 0,
                forceRebase: true,
                checkpointSequence: 2
            ),
            .applied
        )
        XCTAssertEqual(
            try fixture.database.checkpointListeningEvent(
                eventID: fixture.eventID,
                expectedGeneration: fixture.generation,
                checkpointAtUTC: fixture.start.addingTimeInterval(2),
                renderedPosition: 1,
                daySlices: slices,
                qualification: nil,
                checkpointUTCOffsetSeconds: 0,
                forceRebase: true,
                checkpointSequence: 2
            ),
            .staleCheckpointSequence
        )
        let recovered = try fixture.database.recoverAbandonedListeningEvents()
        XCTAssertEqual(recovered, .finalized(1))
        XCTAssertEqual(try fixture.database.recoverAbandonedListeningEvents(), .finalized(0))
        let event = try XCTUnwrap(fixture.database.listeningEvent(id: fixture.eventID))
        XCTAssertEqual(event.endReason, .abandoned)
        XCTAssertEqual(event.endedAtUTC, fixture.start.addingTimeInterval(2))
        XCTAssertEqual(event.daySlices.first?.actualListenedSeconds, 5)
        XCTAssertEqual(event.endPosition, 1)
    }
}
