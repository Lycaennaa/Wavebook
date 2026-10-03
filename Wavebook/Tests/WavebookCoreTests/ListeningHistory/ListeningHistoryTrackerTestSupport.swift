import Foundation
import GRDB
@testable import WavebookCore
import XCTest

extension ListeningHistoryTrackerTests {
    func startTracker(
        _ tracker: ListeningHistoryTracker,
        database: LibraryDatabase,
        at date: Date,
        duration: TimeInterval,
        source: ListeningPlaybackSource = ListeningPlaybackSource(kind: .library)
    ) throws -> UUID {
        let result = tracker.startPlayback(
            track: try makeTrack(in: database),
            openedDuration: duration,
            openedFormat: "flac",
            source: source,
            at: date,
            utcOffsetSeconds: TimeZone.current.secondsFromGMT(for: date),
            monotonicTime: 0
        )
        guard case let .started(eventID) = result else {
            throw NSError(domain: "ListeningHistoryTrackerTests", code: 1)
        }
        return eventID
    }

    func sample(
        position: TimeInterval,
        isPlaying: Bool = true,
        at date: Date
    ) throws -> ListeningPlaybackSample {
        try XCTUnwrap(ListeningPlaybackSample(
            renderedPosition: position,
            isPlaying: isPlaying,
            observedAtUTC: date,
            utcOffsetSeconds: TimeZone.current.secondsFromGMT(for: date)
        ))
    }

    func currentLocalDate(_ components: DateComponents) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: components)
    }

    func setWriteFailure(_ enabled: Bool, in database: LibraryDatabase) throws {
        try database.writer.writeWithoutTransaction { connection in
            if enabled {
                try connection.execute(
                    sql: """
                    CREATE TRIGGER IF NOT EXISTS listeningHistoryTestBlockEventUpdate
                    BEFORE UPDATE ON listeningEvents
                    BEGIN
                        SELECT RAISE(ABORT, 'test persistence write failure');
                    END
                    """
                )
                try connection.execute(
                    sql: """
                    CREATE TRIGGER IF NOT EXISTS listeningHistoryTestBlockEventDelete
                    BEFORE DELETE ON listeningEvents
                    BEGIN
                        SELECT RAISE(ABORT, 'test persistence write failure');
                    END
                    """
                )
                try connection.execute(
                    sql: """
                    CREATE TRIGGER IF NOT EXISTS listeningHistoryTestBlockStateUpdate
                    BEFORE UPDATE ON listeningHistoryState
                    BEGIN
                        SELECT RAISE(ABORT, 'test persistence write failure');
                    END
                    """
                )
            } else {
                try connection.execute(sql: "DROP TRIGGER IF EXISTS listeningHistoryTestBlockEventUpdate")
                try connection.execute(sql: "DROP TRIGGER IF EXISTS listeningHistoryTestBlockEventDelete")
                try connection.execute(sql: "DROP TRIGGER IF EXISTS listeningHistoryTestBlockStateUpdate")
            }
        }
    }

    func setQueryOnly(_ enabled: Bool, in database: LibraryDatabase) throws {
        try setWriteFailure(enabled, in: database)
    }

    func makeTrack(in database: LibraryDatabase) throws -> Track {
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
