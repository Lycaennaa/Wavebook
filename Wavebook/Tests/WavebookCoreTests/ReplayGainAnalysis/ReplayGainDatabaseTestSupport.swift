import Foundation
import GRDB
@testable import WavebookCore
import XCTest

final class ReplayGainAlbumQueryCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [LibraryDatabase.ReplayGainAlbumQueryEvent] = []

    func append(_ event: LibraryDatabase.ReplayGainAlbumQueryEvent) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }

    func events(for stage: LibraryDatabase.ReplayGainAlbumQueryStage) -> [LibraryDatabase.ReplayGainAlbumQueryEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents.filter { $0.stage == stage }
    }
}

final class ReplayGainAlbumCancellationProbe: @unchecked Sendable {
    let token: LibraryDatabaseCancellationToken
    private let lock = NSLock()
    private let stage: LibraryDatabase.ReplayGainAlbumQueryStage
    private let cancellationCheckpoint: Int
    private var checkpointCount = 0

     init(
         token: LibraryDatabaseCancellationToken,
         stage: LibraryDatabase.ReplayGainAlbumQueryStage,
         cancellationCheckpoint: Int
     ) {
        self.token = token
        self.stage = stage
        self.cancellationCheckpoint = cancellationCheckpoint
    }

    func observe(_ event: LibraryDatabase.ReplayGainAlbumQueryEvent) {
        let shouldCancel = lock.withLock {
            guard event.stage == stage else { return false }
            checkpointCount += 1
            return checkpointCount == cancellationCheckpoint
        }
        if shouldCancel {
            token.cancel()
        }
    }
}

final class ReplayGainDatabaseTests: XCTestCase {
    var readyTrackValues: ReplayGainScopeValues {
        ReplayGainScopeValues(gain: ReplayGainGain(decibels: -4, source: .measured), samplePeak: 0.8)
    }

    var readyAlbumValues: ReplayGainScopeValues {
        ReplayGainScopeValues(gain: ReplayGainGain(decibels: -3, source: .measured), samplePeak: 0.9)
    }

    func commitAllPendingTracks(in database: LibraryDatabase) throws {
        while let pending = try database.claimNextPendingReplayGainItem() {
             XCTAssertTrue(
                 try database.commitReplayGainTrackResult(
                     trackID: pending.trackID,
                     fingerprint: pending.fingerprint,
                     claimToken: pending.claimToken,
                     values: pending.cachedTrackValues ?? readyTrackValues
                 )
             )
        }
    }
    func insertReadyAlbumTracks(count: Int, rootID: Int64, database: LibraryDatabase) throws {
         try database.writer.write { database in
             try database.execute(sql: """
                WITH RECURSIVE numbers(id) AS (
                    SELECT 1
                    UNION ALL
                    SELECT id + 1 FROM numbers WHERE id < ?
                )
                INSERT INTO tracks (
                    rootId, path, title, artistDisplay, albumTitle, albumArtist,
                    genreDisplay, duration, format, searchText, mtime, fileSize, lyricsKey
                )
                SELECT ?, 'album-' || id || '.flac', 'Track ' || id, 'Artist', 'Album', 'Artist',
                       '', 1, 'flac', 'track artist album', NULL, NULL, ''
                FROM numbers
                """, arguments: [count, rootID])
             try database.execute(sql: """
                INSERT INTO replayGainAnalysis (
                    trackId, trackGainDB, trackPeak, trackGainSource, analysisState,
                    sourceMtime, sourceFileSize, analyzerVersion, tagSchemaVersion
                )
                SELECT id, -4, 0.8, 'measured', ?, mtime, fileSize, ?, ?
                FROM tracks
                WHERE rootId = ? AND albumTitle = 'Album' AND albumArtist = 'Artist'
                """, arguments: [
                    ReplayGainAnalysisState.ready.rawValue,
                    ReplayGain.analyzerVersion,
                    ReplayGain.tagSchemaVersion,
                    rootID
                ])
        }
    }

    @discardableResult
    func insertReadyAlbumMembers(count: Int, rootID: Int64, database: LibraryDatabase) throws -> [Int64] {
         try database.writer.write { database in
            var trackIDs: [Int64] = []
            trackIDs.reserveCapacity(count)
            for index in 0..<count {
                 try database.execute(sql: """
                    INSERT INTO tracks (
                        rootId, path, title, artistDisplay, albumTitle, albumArtist,
                        genreDisplay, duration, format, searchText, mtime, fileSize, lyricsKey
                    ) VALUES (?, ?, ?, 'Artist', 'Album', 'Artist', '', 1, 'flac', 'track artist album', NULL, NULL, '')
                    """, arguments: [rootID, "grown-\(index).flac", "Grown \(index)"])
                 let trackID = database.lastInsertedRowID
                 try database.execute(sql: """
                    INSERT INTO replayGainAnalysis (
                        trackId, trackGainDB, trackPeak, trackGainSource, analysisState,
                        sourceMtime, sourceFileSize, analyzerVersion, tagSchemaVersion
                    ) VALUES (?, -4, 0.8, 'measured', ?, NULL, NULL, ?, ?)
                    """, arguments: [
                        trackID,
                        ReplayGainAnalysisState.ready.rawValue,
                        ReplayGain.analyzerVersion,
                        ReplayGain.tagSchemaVersion
                    ])
                trackIDs.append(trackID)
            }
            return trackIDs
        }
    }

    func albumMembers(trackIDs: [Int64], database: LibraryDatabase) throws -> [ReplayGainAlbumMember] {
        try trackIDs.map { trackID in
            let data = try XCTUnwrap(database.replayGainData(trackID: trackID))
             return ReplayGainAlbumMember(
                 trackID: trackID,
                 fingerprint: data.fingerprint,
                 trackRevision: data.trackRevision
             )
        }
    }

    func track(for url: URL, title: String = "One", albumTitle: String = "", albumArtist: String? = nil) -> Track {
         Track(
             path: url.path,
             title: title,
             artistDisplay: "Artist",
             albumTitle: albumTitle,
             albumArtist: albumArtist,
             genreDisplay: "",
             duration: 1,
             format: "flac"
         )
    }

    func makeRoot() throws -> URL {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: ".test-tmp")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func makeAudioFile(in root: URL, name: String) throws -> URL {
        let url = root.appending(path: name)
        try Data([1, 2, 3]).write(to: url)
        return url
    }

}

extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
