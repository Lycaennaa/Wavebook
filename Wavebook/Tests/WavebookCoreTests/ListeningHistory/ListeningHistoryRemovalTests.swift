import Foundation
@testable import WavebookCore
import XCTest

private struct QualifiedHistoryRemovalFixture {
    let database: LibraryDatabase
    let day: ListeningLocalDay
    let dayDate: Date
    let snapshotID: Int64
    let firstID: UUID
    let secondID: UUID
}

private struct ActiveQualifiedHistoryFixture {
    let database: LibraryDatabase
    let day: ListeningLocalDay
    let activeID: UUID
    let finishedID: UUID
}

extension ListeningHistoryTests {
    func testQualifiedHistoryRemovalAndUndoRestoreMetrics() throws {
        let fixture = try makeQualifiedHistoryRemovalFixture()
        let database = fixture.database
        let first = try XCTUnwrap(database.listeningEvent(id: fixture.firstID))
        let summary = try database.listeningStatisticsSummary()

        let deletion = try database.deleteQualifiedListeningHistory(on: fixture.day, eventIDs: [fixture.firstID])
        XCTAssertNil(try database.listeningEvent(id: fixture.firstID))
        XCTAssertNotNil(try database.listeningSnapshot(id: fixture.snapshotID))
        XCTAssertEqual(try database.listeningHistoryHealth().eventCount, 1)
        let remaining = try database.listeningStatisticsSummary()
        XCTAssertEqual(remaining.qualifiedPlayCount, 1)
        XCTAssertEqual(remaining.listenedSeconds, 40)
        XCTAssertEqual(remaining.skipCount, 0)
        XCTAssertEqual(
            try database.qualifiedPlayTimeline(day: fixture.day).entries.map(\.eventID),
            [fixture.secondID]
        )
        XCTAssertTrue(try database.listeningSkippedSongs().isEmpty)

        try database.restoreListeningHistory(deletion)
        XCTAssertEqual(try database.listeningEvent(id: fixture.firstID), first)
        XCTAssertEqual(try database.listeningStatisticsSummary(), summary)
        XCTAssertEqual(
            try database.qualifiedPlayTimeline(day: fixture.day).entries.map(\.eventID),
            [fixture.firstID, fixture.secondID]
        )
    }

    func testQualifiedHistoryRemovalIsBoundToSelectedDay() throws {
        let fixture = try makeQualifiedHistoryRemovalFixture()
        let otherDay = try XCTUnwrap(
            ListeningLocalDay(date: fixture.dayDate.addingTimeInterval(172_800), timeZone: .current)
        )

        XCTAssertThrowsError(
            try fixture.database.deleteQualifiedListeningHistory(on: otherDay, eventIDs: [fixture.firstID])
        )
        XCTAssertNotNil(try fixture.database.listeningEvent(id: fixture.firstID))
        XCTAssertEqual(try fixture.database.listeningStatisticsSummary().qualifiedPlayCount, 2)
    }

    func testQualifiedHistoryRemovalUsesTimeZoneThatProducedTimeline() throws {
        let database = try LibraryDatabase(inMemory: true)
        let snapshotID = try XCTUnwrap(makeDatabaseSnapshot(in: database).id)
        let start = Date(timeIntervalSince1970: 1_704_067_200)
        let qualifiedAt = start.addingTimeInterval(1)
        let storedTimeZone = TimeZone.current
        let storedDay = try XCTUnwrap(ListeningLocalDay(date: qualifiedAt, timeZone: storedTimeZone))
        let timelineTimeZone = try XCTUnwrap(
            [
                TimeZone(secondsFromGMT: -12 * 60 * 60),
                TimeZone(secondsFromGMT: 14 * 60 * 60)
            ]
            .compactMap(\.self)
            .first { ListeningLocalDay(date: qualifiedAt, timeZone: $0) != storedDay }
        )
        let timelineDay = try XCTUnwrap(ListeningLocalDay(date: qualifiedAt, timeZone: timelineTimeZone))
        XCTAssertNotEqual(storedDay, timelineDay)
        try recordFinishedEvent(
            in: database,
            snapshotID: snapshotID,
            startAtUTC: start,
            day: storedDay,
            listenedSeconds: 60,
            timeZone: storedTimeZone
        )

        let entry = try XCTUnwrap(
            database.qualifiedPlayTimeline(day: timelineDay, timeZone: timelineTimeZone).entries.first
        )
        XCTAssertEqual(entry.localDay, timelineDay)
        let deletion = try database.deleteQualifiedListeningHistory(
            on: timelineDay,
            eventIDs: [entry.eventID],
            timeZone: timelineTimeZone
        )
        XCTAssertNil(try database.listeningEvent(id: entry.eventID))

        try database.restoreListeningHistory(deletion)
        XCTAssertEqual(
            try database.listeningEvent(id: entry.eventID)?.qualification?.localDay,
            storedDay
        )
    }

    func testQualifiedHistoryBatchRemovalPrunesAndRestoresSharedSnapshot() throws {
        let fixture = try makeQualifiedHistoryRemovalFixture()
        let database = fixture.database
        let first = try XCTUnwrap(database.listeningEvent(id: fixture.firstID))
        let second = try XCTUnwrap(database.listeningEvent(id: fixture.secondID))
        let snapshot = try XCTUnwrap(database.listeningSnapshot(id: fixture.snapshotID))
        let summary = try database.listeningStatisticsSummary()

        let deletion = try database.deleteQualifiedListeningHistory(
            on: fixture.day,
            eventIDs: [fixture.firstID, fixture.secondID]
        )
        XCTAssertNil(try database.listeningEvent(id: fixture.firstID))
        XCTAssertNil(try database.listeningEvent(id: fixture.secondID))
        XCTAssertNil(try database.listeningSnapshot(id: fixture.snapshotID))
        XCTAssertEqual(try database.listeningHistoryHealth().eventCount, 0)
        XCTAssertEqual(try database.listeningHistoryHealth().snapshotCount, 0)
        XCTAssertEqual(try database.listeningStatisticsSummary(), ListeningStatisticsSummary())
        XCTAssertTrue(try database.qualifiedPlayTimeline(day: fixture.day).entries.isEmpty)
        XCTAssertTrue(try database.listeningSkippedSongs().isEmpty)

        try database.restoreListeningHistory(deletion)
        XCTAssertEqual(try database.listeningEvent(id: fixture.firstID), first)
        XCTAssertEqual(try database.listeningEvent(id: fixture.secondID), second)
        XCTAssertEqual(try database.listeningSnapshot(id: fixture.snapshotID), snapshot)
        XCTAssertEqual(try database.listeningStatisticsSummary(), summary)
        XCTAssertEqual(try database.listeningSkippedSongs().first?.skipCount, 1)
    }

    func testQualifiedHistoryRemovalRejectsAnActiveEventAtomically() throws {
        let fixture = try makeActiveQualifiedHistoryFixture()
        let entries = try fixture.database.qualifiedPlayTimeline(day: fixture.day).entries
        let activeEntry = try XCTUnwrap(entries.first { $0.eventID == fixture.activeID })
        let finishedEntry = try XCTUnwrap(entries.first { $0.eventID == fixture.finishedID })
        let summary = try fixture.database.listeningStatisticsSummary()

        XCTAssertFalse(activeEntry.isFinalized)
        XCTAssertTrue(finishedEntry.isFinalized)
        XCTAssertThrowsError(
            try fixture.database.deleteQualifiedListeningHistory(
                on: fixture.day,
                eventIDs: entries.map(\.eventID)
            )
        )
        XCTAssertNotNil(try fixture.database.listeningEvent(id: fixture.activeID))
        XCTAssertNotNil(try fixture.database.listeningEvent(id: fixture.finishedID))
        XCTAssertEqual(try fixture.database.listeningHistoryHealth().eventCount, 2)
        XCTAssertEqual(try fixture.database.listeningStatisticsSummary(), summary)
    }

    private func makeQualifiedHistoryRemovalFixture() throws -> QualifiedHistoryRemovalFixture {
        let database = try LibraryDatabase(inMemory: true)
        let snapshotID = try XCTUnwrap(makeDatabaseSnapshot(in: database).id)
        let start = Date(timeIntervalSince1970: 1_704_067_200)
        let dayDate = start.addingTimeInterval(1)
        let day = try XCTUnwrap(ListeningLocalDay(date: dayDate, timeZone: .current))
        try recordFinishedEvent(
            in: database,
            snapshotID: snapshotID,
            startAtUTC: start,
            day: day,
            listenedSeconds: 60,
            includeSkip: true
        )
        try recordFinishedEvent(
            in: database,
            snapshotID: snapshotID,
            startAtUTC: start.addingTimeInterval(120),
            day: day,
            listenedSeconds: 40
        )
        let entries = try database.qualifiedPlayTimeline(day: day).entries
        guard entries.count == 2 else { throw NSError(domain: "ListeningHistoryRemovalTests", code: 1) }
        return QualifiedHistoryRemovalFixture(
            database: database,
            day: day,
            dayDate: dayDate,
            snapshotID: snapshotID,
            firstID: entries[0].eventID,
            secondID: entries[1].eventID
        )
    }

    private func makeActiveQualifiedHistoryFixture() throws -> ActiveQualifiedHistoryFixture {
        let database = try LibraryDatabase(inMemory: true)
        let snapshotID = try XCTUnwrap(makeDatabaseSnapshot(in: database).id)
        let start = Date(timeIntervalSince1970: 1_704_067_200)
        let day = try XCTUnwrap(ListeningLocalDay(date: start.addingTimeInterval(1), timeZone: .current))
        try recordFinishedEvent(
            in: database,
            snapshotID: snapshotID,
            startAtUTC: start,
            day: day,
            listenedSeconds: 60
        )
        let finishedID = try XCTUnwrap(database.qualifiedPlayTimeline(day: day).entries.first?.eventID)
        let state = try database.listeningHistoryState()
        let activeID = UUID()
        let activeStart = start.addingTimeInterval(120)
        let startedOffset = TimeZone.current.secondsFromGMT(for: activeStart)
        guard try database.beginListeningEvent(
            eventID: activeID,
            expectedGeneration: state.generation,
            snapshotID: snapshotID,
            startedAtUTC: activeStart,
            startedUTCOffsetSeconds: startedOffset
        ) == .applied else {
            throw NSError(domain: "ListeningHistoryRemovalTests", code: 2)
        }
        let qualifiedAt = activeStart.addingTimeInterval(30)
        let qualifiedOffset = TimeZone.current.secondsFromGMT(for: qualifiedAt)
        let qualification = try XCTUnwrap(ListeningEventOccurrence(
            timestampUTC: qualifiedAt,
            localDay: day,
            utcOffsetSeconds: qualifiedOffset
        ))
        guard try database.checkpointListeningEvent(
            eventID: activeID,
            expectedGeneration: state.generation,
            checkpointAtUTC: qualifiedAt,
            renderedPosition: 30,
            daySlices: [ListeningDaySlice(
                eventID: activeID,
                localDay: day,
                utcOffsetSeconds: qualifiedOffset,
                actualListenedSeconds: 30
            )],
            qualification: qualification,
            checkpointUTCOffsetSeconds: qualifiedOffset
        ) == .applied else {
            throw NSError(domain: "ListeningHistoryRemovalTests", code: 3)
        }
        return ActiveQualifiedHistoryFixture(
            database: database,
            day: day,
            activeID: activeID,
            finishedID: finishedID
        )
    }
}
