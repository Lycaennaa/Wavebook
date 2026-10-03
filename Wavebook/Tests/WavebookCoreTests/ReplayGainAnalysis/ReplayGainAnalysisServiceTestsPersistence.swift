import Foundation
@testable import WavebookCore
import XCTest

extension ReplayGainAnalysisServiceTests {
    func testServiceDrainsPersistedTrackAndAlbumTags() async throws {
        let root = try makeRoot()
        let source = try fixtureURL(fileExtension: "flac")
        let url = root.appending(path: "tagged.flac")
        try FileManager.default.copyItem(at: source, to: url)
        let database = try makeDatabase(root: root, urls: [url])
        let service = ReplayGainAnalysisService(database: database)

        await service.start()
        await service.waitUntilIdle()

        let data = try XCTUnwrap(database.replayGainData(path: url.path))
        XCTAssertEqual(data.state, .ready)
        XCTAssertEqual(data.track?.gain, ReplayGainGain(decibels: -7.25, source: .replayGain))
        XCTAssertEqual(data.track?.samplePeak, 0.987654)
        XCTAssertEqual(data.album?.gain, ReplayGainGain(decibels: -6.5, source: .replayGain))
        XCTAssertEqual(data.album?.samplePeak, 1.012345)
        XCTAssertNotNil(data.albumGeneration)
        let status = try await service.status()
        XCTAssertEqual(status.counts, ReplayGainAnalysisStatusCounts(ready: 1))
    }

    func testInterruptedAlbumPassRemainsAvailableAndResumesAfterReopen() async throws {
        let root = try makeRoot()
        let urls = try (0..<2).map { try makeAudioFile(in: root, name: "\($0).flac") }
        let databaseURL = root.appending(path: "Library.sqlite")

        do {
            let database = try LibraryDatabase(path: databaseURL.path)
            let rootID = try database.addRoot(path: root.path)
            for url in urls {
                _ = try database.save(
                    track: Track(
                        path: url.path,
                        title: url.deletingPathExtension().lastPathComponent,
                        artistDisplay: "Artist",
                        albumTitle: "Album",
                        albumArtist: "Artist",
                        genreDisplay: "",
                        duration: 1,
                        format: url.pathExtension
                    ),
                    rootID: rootID
                )
            }
            for _ in urls {
                let item = try XCTUnwrap(database.claimNextPendingReplayGainItem())
                XCTAssertTrue(
                    try database.commitReplayGainTrackResult(
                        trackID: item.trackID,
                        fingerprint: item.fingerprint,
                        claimToken: item.claimToken,
                        values: readyTrackValues
                    )
                )
            }
        }

        let reopened = try LibraryDatabase(path: databaseURL.path)
        let beforeResume = try XCTUnwrap(reopened.replayGainData(path: urls[0].path))
        XCTAssertEqual(beforeResume.track, readyTrackValues)
        XCTAssertNil(beforeResume.album)
        XCTAssertEqual(
            try reopened.replayGainAnalysisProgress(),
            ReplayGainAnalysisProgress(total: 2, trackCompleted: 2, albumCompleted: 0)
        )
        XCTAssertNotNil(try reopened.nextReplayGainAlbumAnalysisItem())

        let albumValues = readyAlbumValues
        let service = ReplayGainAnalysisService(
            database: reopened,
            analyzeTrack: { _, _ in
                XCTFail("Track pass should already be complete")
                throw TestServiceError.failed
            },
            analyzeAlbum: { _, _ in albumValues }
        )
        await service.start()
        await service.waitUntilIdle()

        for url in urls {
            XCTAssertEqual(try reopened.replayGainData(path: url.path)?.album, readyAlbumValues)
        }
    }

    func testInvalidAlbumIdentityKeepsTrackValuesAndSurfacesFailure() async throws {
        let root = try makeRoot()
        let source = try fixtureURL(fileExtension: "flac")
        let url = root.appending(path: "tagged.flac")
        try FileManager.default.copyItem(at: source, to: url)
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        _ = try database.save(
            track: Track(
                path: url.path,
                title: "Tagged",
                artistDisplay: "Artist",
                albumTitle: "",
                albumArtist: "Artist",
                genreDisplay: "",
                duration: 1,
                format: "flac"
            ),
            rootID: rootID
        )
        let service = ReplayGainAnalysisService(database: database)

        await service.start()
        await service.waitUntilIdle()

        let data = try XCTUnwrap(database.replayGainData(path: url.path))
        XCTAssertEqual(data.state, .failed)
        XCTAssertEqual(data.track?.gain, ReplayGainGain(decibels: -7.25, source: .replayGain))
        XCTAssertNil(data.album)
        XCTAssertEqual(data.errorReason, "[Album] Album title and album artist are required")
        let failures = try await service.failures()
        XCTAssertEqual(failures.count, 1)
    }
}
