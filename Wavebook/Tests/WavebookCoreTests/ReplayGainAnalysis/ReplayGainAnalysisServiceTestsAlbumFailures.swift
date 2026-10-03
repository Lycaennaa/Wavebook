import Foundation
@testable import WavebookCore
import XCTest

extension ReplayGainAnalysisServiceTests {
    func testPartialAlbumUsesReadyMembersAndPreservesTrackFailure() async throws {
        let root = try makeRoot()
        let readyURL = try makeAudioFile(in: root, name: "ready.flac")
        let failedURL = try makeAudioFile(in: root, name: "failed.flac")
        let database = try makeDatabase(root: root, urls: [readyURL, failedURL])
        let trackValues = readyTrackValues
        let albumValues = readyAlbumValues
        let availablePaths = PathProbe()
        let allPaths = PathProbe()
        let service = ReplayGainAnalysisService(
            database: database,
            analyzeTrack: { item, database in
                if item.path == failedURL.path {
                    _ = try database.recordReplayGainFailure(
                        trackID: item.trackID,
                        fingerprint: item.fingerprint,
                        claimToken: item.claimToken,
                        reason: "decode failed"
                    )
                    return .failed(trackID: item.trackID, reason: "decode failed")
                }
                _ = try database.commitReplayGainTrackResult(
                    trackID: item.trackID,
                    fingerprint: item.fingerprint,
                    claimToken: item.claimToken,
                    values: trackValues
                )
                return .committed(trackID: item.trackID, values: trackValues)
            },
            analyzeAlbum: { item, _ in
                availablePaths.set(item.availablePaths)
                allPaths.set(item.allPaths)
                return albumValues
            }
        )

        await service.start()
        await service.waitUntilIdle()

        XCTAssertEqual(availablePaths.value, [readyURL.path])
        XCTAssertEqual(Set(allPaths.value), Set([readyURL.path, failedURL.path]))
        let readyData = try XCTUnwrap(database.replayGainData(path: readyURL.path))
        let failedData = try XCTUnwrap(database.replayGainData(path: failedURL.path))
        XCTAssertEqual(readyData.state, .ready)
        XCTAssertEqual(failedData.state, .failed)
        XCTAssertEqual(readyData.album, albumValues)
        XCTAssertEqual(failedData.album, albumValues)
        XCTAssertEqual(failedData.errorReason, "decode failed")
    }

    func testAlbumTagsCommitWhenEveryTrackAnalysisFailed() async throws {
        let root = try makeRoot()
        let source = try fixtureURL(fileExtension: "flac")
        let url = root.appending(path: "tagged.flac")
        try FileManager.default.copyItem(at: source, to: url)
        let database = try makeDatabase(root: root, urls: [url])
        let analyzer = ReplayGainAnalyzer()
        let service = ReplayGainAnalysisService(
            database: database,
            analyzeTrack: { item, database in
                _ = try database.recordReplayGainFailure(
                    trackID: item.trackID,
                    fingerprint: item.fingerprint,
                    claimToken: item.claimToken,
                    reason: "track failed"
                )
                return .failed(trackID: item.trackID, reason: "track failed")
            },
            analyzeAlbum: { item, _ in
                try await analyzer.albumValues(
                    tagURLs: item.allPaths.map { URL(fileURLWithPath: $0) },
                    measurementURLs: item.availablePaths.map { URL(fileURLWithPath: $0) }
                )
            }
        )

        await service.start()
        await service.waitUntilIdle()

        let data = try XCTUnwrap(database.replayGainData(path: url.path))
        XCTAssertEqual(data.state, .failed)
        XCTAssertNil(data.track)
        XCTAssertEqual(data.album?.gain, ReplayGainGain(decibels: -6.5, source: .replayGain))
        XCTAssertEqual(data.album?.samplePeak, 1.012345)
        XCTAssertEqual(data.errorReason, "track failed")
    }

    func testAllFailedUntaggedAlbumRecordsOneAlbumFailureAndStops() async throws {
        let root = try makeRoot()
        let url = try makeAudioFile(in: root, name: "failed.flac")
        let database = try makeDatabase(root: root, urls: [url])
        let analyzer = ReplayGainAnalyzer()
        let service = ReplayGainAnalysisService(
            database: database,
            analyzeTrack: { item, database in
                _ = try database.recordReplayGainFailure(
                    trackID: item.trackID,
                    fingerprint: item.fingerprint,
                    claimToken: item.claimToken,
                    reason: "track failed"
                )
                return .failed(trackID: item.trackID, reason: "track failed")
            },
            analyzeAlbum: { item, _ in
                try await analyzer.albumValues(
                    tagURLs: item.allPaths.map { URL(fileURLWithPath: $0) },
                    measurementURLs: item.availablePaths.map { URL(fileURLWithPath: $0) }
                )
            }
        )

        await service.start()
        await service.waitUntilIdle()

        let data = try XCTUnwrap(database.replayGainData(path: url.path))
        XCTAssertEqual(data.state, .failed)
        XCTAssertNil(data.track)
        XCTAssertNil(data.album)
        XCTAssertEqual(data.errorReason, "[Album] Audio file contains no decoded frames\ntrack failed")
    }

    func testAlbumRetryIncludesMembersRetainingTrackValuesAfterAlbumFailure() async throws {
        let root = try makeRoot()
        let urls = try (0..<2).map { try makeAudioFile(in: root, name: "\($0).flac") }
        let database = try makeDatabase(root: root, urls: urls)
        let firstID = try XCTUnwrap(database.replayGainData(path: urls[0].path)?.trackID)
        let trackValues = readyTrackValues
        let albumProbe = FailingAlbumProbe(successValues: readyAlbumValues)
        let service = ReplayGainAnalysisService(
            database: database,
            analyzeTrack: { item, database in
                _ = try database.commitReplayGainTrackResult(
                    trackID: item.trackID,
                    fingerprint: item.fingerprint,
                    claimToken: item.claimToken,
                    values: trackValues
                )
                return .committed(trackID: item.trackID, values: trackValues)
            },
            analyzeAlbum: { item, _ in try albumProbe.analyze(item) }
        )

        await service.start()
        await service.waitUntilIdle()
        XCTAssertEqual((try XCTUnwrap(database.replayGainData(path: urls[0].path))).state, .failed)
        XCTAssertEqual((try XCTUnwrap(database.replayGainData(path: urls[1].path))).state, .failed)

        try await service.rescan(trackIDs: [firstID])
        await service.waitUntilIdle()

        XCTAssertEqual(Set(albumProbe.successfulPaths), Set(urls.map(\.path)))
        for url in urls {
            let data = try XCTUnwrap(database.replayGainData(path: url.path))
            XCTAssertEqual(data.state, .ready)
            XCTAssertEqual(data.album, readyAlbumValues)
            XCTAssertNil(data.errorReason)
            XCTAssertNil(data.errorAt)
        }
    }
    func testFileChangeDuringAlbumMeasurementRequeuesAndDrainsTracks() async throws {
        let root = try makeRoot()
        let urls = try (0..<2).map { try makeAudioFile(in: root, name: "\($0).flac") }
        let database = try makeDatabase(root: root, urls: urls)
        let trackValues = readyTrackValues
        let albumValues = readyAlbumValues
        let trackProbe = AnalysisConcurrencyProbe()
        let albumProbe = FileChangeDuringAlbumProbe(url: urls[0], values: albumValues)
        let service = ReplayGainAnalysisService(
            database: database,
            analyzeTrack: { item, database in
                trackProbe.enter()
                defer { trackProbe.leave() }
                _ = try database.commitReplayGainTrackResult(
                    trackID: item.trackID,
                    fingerprint: item.fingerprint,
                    claimToken: item.claimToken,
                    values: trackValues
                )
                return .committed(trackID: item.trackID, values: trackValues)
            },
            analyzeAlbum: { item, _ in
                try albumProbe.analyze(item)
            }
        )

        await service.start()
        await service.waitUntilIdle()

        XCTAssertEqual(trackProbe.callCount, 4)
        XCTAssertEqual(albumProbe.callCount, 2)
        let status = try await service.status()
        XCTAssertEqual(status.counts, ReplayGainAnalysisStatusCounts(ready: urls.count))
        XCTAssertFalse(status.isRunning)
        for url in urls {
            let data = try XCTUnwrap(database.replayGainData(path: url.path))
            XCTAssertEqual(data.album, albumValues)
        }
    }

    func testTrackFailureWithCachedValuesCannotBeResurrectedByAlbumCommit() async throws {
        let root = try makeRoot()
        let initialURLs = try (0..<2).map { try makeAudioFile(in: root, name: "\($0).flac") }
        let database = try makeDatabase(root: root, urls: initialURLs)
        let trackValues = readyTrackValues
        let albumValues = readyAlbumValues
        let initialService = makeCommittingService(
            database: database,
            trackValues: trackValues,
            albumValues: albumValues
        )
        await initialService.start()
        await initialService.waitUntilIdle()

        let addedURL = try makeAudioFile(in: root, name: "added.flac")
        let rootID = try database.addRoot(path: root.path)
        _ = try database.save(
            track: Track(
                path: addedURL.path,
                title: "Added",
                artistDisplay: "Artist",
                albumTitle: "Album",
                albumArtist: "Artist",
                genreDisplay: "",
                duration: 1,
                format: "flac"
            ),
            rootID: rootID
        )
        let failedItem = try XCTUnwrap(database.claimNextPendingReplayGainItem())
        XCTAssertEqual(failedItem.cachedTrackValues, trackValues)
        _ = try database.recordReplayGainFailure(
            trackID: failedItem.trackID,
            fingerprint: failedItem.fingerprint,
            claimToken: failedItem.claimToken,
            reason: "metadata failed"
        )

        let retryService = makeCommittingService(
            database: database,
            trackValues: trackValues,
            albumValues: albumValues
        )
        await retryService.start()
        await retryService.waitUntilIdle()

        let failed = try XCTUnwrap(database.replayGainData(trackID: failedItem.trackID))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertNil(failed.track)
        XCTAssertEqual(failed.album, albumValues)
        XCTAssertEqual(failed.errorReason, "metadata failed")
    }

    func testOversizedAlbumCountsFailedMembersBeforeAnalyzingAvailableSubset() async throws {
        let root = try makeRoot()
        let urls = try (0...ReplayGainAnalyzer.maximumAlbumTrackCount).map {
            try makeAudioFile(in: root, name: "\($0).flac")
        }
        let database = try makeDatabase(root: root, urls: urls)
        let failedPath = urls.last?.path
        let trackValues = readyTrackValues
        let albumValues = readyAlbumValues
        let albumProbe = AnalysisConcurrencyProbe()
        let service = ReplayGainAnalysisService(
            database: database,
            analyzeTrack: { item, database in
                if item.path == failedPath {
                    _ = try database.recordReplayGainFailure(
                        trackID: item.trackID,
                        fingerprint: item.fingerprint,
                        claimToken: item.claimToken,
                        reason: "decode failed"
                    )
                    return .failed(trackID: item.trackID, reason: "decode failed")
                }
                _ = try database.commitReplayGainTrackResult(
                    trackID: item.trackID,
                    fingerprint: item.fingerprint,
                    claimToken: item.claimToken,
                    values: trackValues
                )
                return .committed(trackID: item.trackID, values: trackValues)
            },
            analyzeAlbum: { _, _ in
                albumProbe.enter()
                albumProbe.leave()
                return albumValues
            }
        )

        await service.start()
        await service.waitUntilIdle()

        XCTAssertEqual(albumProbe.callCount, 0)
        let status = try await service.status()
        XCTAssertEqual(status.counts, ReplayGainAnalysisStatusCounts(failed: urls.count))
        let data = try XCTUnwrap(database.replayGainData(path: urls[0].path))
        XCTAssertEqual(data.track, trackValues)
        XCTAssertNil(data.album)
        XCTAssertEqual(data.errorReason, "[Album] Album group exceeds 500 tracks: 501")
    }
}
