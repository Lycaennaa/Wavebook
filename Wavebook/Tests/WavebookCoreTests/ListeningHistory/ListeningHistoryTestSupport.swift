import Foundation
@testable import WavebookCore
import XCTest

final class ListeningHistoryTests: XCTestCase {
    func recordFinishedEvent(
        in database: LibraryDatabase,
        snapshotID: Int64,
        startAtUTC: Date,
        day: ListeningLocalDay,
        listenedSeconds: TimeInterval,
        includeSkip: Bool = false
    ) throws {
        let state = try database.listeningHistoryState()
        let eventID = UUID()
        let startedOffset = TimeZone.current.secondsFromGMT(for: startAtUTC)
        let qualificationAtUTC = startAtUTC.addingTimeInterval(1)
        let qualificationOffset = TimeZone.current.secondsFromGMT(for: qualificationAtUTC)
        let skipAtUTC = startAtUTC.addingTimeInterval(2)
        let skipOffset = TimeZone.current.secondsFromGMT(for: skipAtUTC)
        let endedAtUTC = startAtUTC.addingTimeInterval(max(listenedSeconds, 5))
        let endedOffset = TimeZone.current.secondsFromGMT(for: endedAtUTC)
        XCTAssertEqual(
            try database.beginListeningEvent(
                eventID: eventID,
                expectedGeneration: state.generation,
                snapshotID: snapshotID,
                startedAtUTC: startAtUTC,
                startedUTCOffsetSeconds: startedOffset
            ),
            .applied
        )
        let qualification = try XCTUnwrap(ListeningEventOccurrence(
            timestampUTC: qualificationAtUTC,
            localDay: day,
            utcOffsetSeconds: qualificationOffset
        ))
        let skip: ListeningEventOccurrence? = includeSkip
            ? try XCTUnwrap(ListeningEventOccurrence(
                timestampUTC: skipAtUTC,
                localDay: day,
                utcOffsetSeconds: skipOffset
            ))
            : nil
        XCTAssertEqual(
            try database.finishListeningEvent(
                request: .init(
                    eventID: eventID,
                    expectedGeneration: state.generation,
                    endedAtUTC: endedAtUTC,
                    endReason: includeSkip ? .next : .stop,
                    details: .init(
                        endedUTCOffsetSeconds: endedOffset,
                        endPosition: listenedSeconds,
                        daySlices: [ListeningDaySlice(
                            eventID: eventID,
                            localDay: day,
                            utcOffsetSeconds: startedOffset,
                            actualListenedSeconds: listenedSeconds
                        )],
                        qualification: qualification,
                        skip: skip
                    )
                )
            ),
            .applied
        )
    }

    func makeDatabaseSnapshot(in database: LibraryDatabase) throws -> ListeningMediaSnapshot {
         let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
             .appending(path: ".tmp/listening-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let rootID = try database.addRoot(path: root.path)
        var track = Track(
            path: root.appending(path: "song.flac").path,
            title: "Song",
            artistDisplay: "Artist",
            albumTitle: "",
            genreDisplay: "",
            duration: 60,
            format: "flac"
        )
        track.id = try database.save(track: track, rootID: rootID)
        let generation = try database.listeningHistoryState().generation
        return try database.createOrReuseListeningSnapshot(
            track: track,
            openedDuration: 60,
            openedFormat: "flac",
            expectedGeneration: generation
        )
    }

}
