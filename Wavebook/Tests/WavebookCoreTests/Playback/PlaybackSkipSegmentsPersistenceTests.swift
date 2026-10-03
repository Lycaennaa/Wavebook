import Foundation
@testable import WavebookCore
import XCTest

final class PlaybackSkipSegmentsPersistenceTests: XCTestCase {
    func testMissingTrackStartsWithNoSegments() throws {
        let database = try LibraryDatabase(inMemory: true)

        XCTAssertEqual(try database.skipSegments(forTrackPath: "/missing/song.flac"), [])
    }

    func testSegmentsPersistInTimeOrder() throws {
        let (database, trackPath) = try makeDatabaseAndTrack()
        let later = AudioSkipSegment(startTime: 5, endTime: 7)
        let earlier = AudioSkipSegment(startTime: 1, endTime: 2)

        try database.saveSkipSegments([later, earlier], forTrackPath: trackPath)

        XCTAssertEqual(try database.skipSegments(forTrackPath: trackPath), [earlier, later])
    }

    func testInvalidReplacementLeavesExistingSegmentsIntact() throws {
        let (database, trackPath) = try makeDatabaseAndTrack()
        let existing = AudioSkipSegment(startTime: 1, endTime: 2)
        try database.saveSkipSegments([existing], forTrackPath: trackPath)

        XCTAssertThrowsError(
            try database.saveSkipSegments(
                [
                    AudioSkipSegment(startTime: 3, endTime: 5),
                    AudioSkipSegment(startTime: 4, endTime: 6)
                ],
                forTrackPath: trackPath
            )
        )
        XCTAssertEqual(try database.skipSegments(forTrackPath: trackPath), [existing])
    }

    func testSegmentsSurviveDatabaseReopen() throws {
        let root = try makeRoot()
        let databasePath = root.appendingPathComponent("Library.sqlite").path
        let trackPath = root.appendingPathComponent("song.flac").path
        let segment = AudioSkipSegment(startTime: 2, endTime: 4)

        do {
            let database = try LibraryDatabase(path: databasePath)
            let rootID = try database.addRoot(path: root.path)
            _ = try database.save(
                track: Track(
                    path: trackPath,
                    title: "Song",
                    artistDisplay: "Artist",
                    albumTitle: "Album",
                    genreDisplay: "",
                    duration: 10,
                    format: "flac"
                ),
                rootID: rootID
            )
            try database.saveSkipSegments([segment], forTrackPath: trackPath)
        }

        let reopened = try LibraryDatabase(path: databasePath)
        XCTAssertEqual(try reopened.skipSegments(forTrackPath: trackPath), [segment])
    }

    private func makeDatabaseAndTrack() throws -> (LibraryDatabase, String) {
        let root = try makeRoot()
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let trackPath = root.appendingPathComponent("song.flac").path
        _ = try database.save(
            track: Track(
                path: trackPath,
                title: "Song",
                artistDisplay: "Artist",
                albumTitle: "Album",
                genreDisplay: "",
                duration: 10,
                format: "flac"
            ),
            rootID: rootID
        )
        return (database, trackPath)
    }

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test-tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}
