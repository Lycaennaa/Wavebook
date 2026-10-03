import Foundation
@testable import WavebookCore
import XCTest

extension ReplayGainAnalysisServiceTests {
    func testRepeatedStartsStillRunOneTrackAnalysisAtATime() async throws {
        let root = try makeRoot()
        let urls = try (0..<3).map { try makeAudioFile(in: root, name: "\($0).flac") }
        let database = try makeDatabase(root: root, urls: urls)
        let probe = AnalysisConcurrencyProbe()
        let trackValues = readyTrackValues
        let albumValues = readyAlbumValues
        let service = ReplayGainAnalysisService(
            database: database,
            analyzeTrack: { item, database in
                probe.enter()
                defer { probe.leave() }
                try await Task.sleep(for: .milliseconds(20))
                _ = try database.commitReplayGainTrackResult(
                    trackID: item.trackID,
                    fingerprint: item.fingerprint,
                    claimToken: item.claimToken,
                    values: trackValues
                )
                return .committed(trackID: item.trackID, values: trackValues)
            },
            analyzeAlbum: { _, _ in albumValues }
        )

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { await service.start() }
            }
        }
        await service.waitUntilIdle()

        XCTAssertEqual(probe.callCount, 3)
        XCTAssertEqual(probe.maximumActiveCount, 1)
        let status = try await service.status()
        XCTAssertEqual(status.counts, ReplayGainAnalysisStatusCounts(ready: 3))
    }

    func testCompletesEachAlbumBeforeStartingNextTrackBatch() async throws {
        let root = try makeRoot()
        let urls = try (0..<3).map { try makeAudioFile(in: root, name: "\($0).flac") }
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        for (index, url) in urls.enumerated() {
            _ = try database.save(
                track: Track(
                    path: url.path,
                    title: url.deletingPathExtension().lastPathComponent,
                    artistDisplay: "Artist",
                    albumTitle: index < 2 ? "Album A" : "Album B",
                    albumArtist: "Artist",
                    genreDisplay: "",
                    duration: 1,
                    format: url.pathExtension
                ),
                rootID: rootID
            )
        }
        let order = AnalysisOrderProbe()
        let trackValues = readyTrackValues
        let albumValues = readyAlbumValues
        let service = ReplayGainAnalysisService(
            database: database,
            maximumConcurrentFileCount: 2,
            analyzeTrack: { item, database in
                order.append("track:\(URL(fileURLWithPath: item.path).lastPathComponent)")
                _ = try database.commitReplayGainTrackResult(
                    trackID: item.trackID,
                    fingerprint: item.fingerprint,
                    claimToken: item.claimToken,
                    values: trackValues
                )
                return .committed(trackID: item.trackID, values: trackValues)
            },
            analyzeAlbum: { item, _ in
                order.append("album:\(item.albumKey?.title ?? "invalid")")
                return albumValues
            }
        )

        await service.start()
        await service.waitUntilIdle()

        let events = order.value
        let albumIndex = try XCTUnwrap(events.firstIndex(of: "album:Album A"))
        let nextAlbumTrackIndex = try XCTUnwrap(events.firstIndex(of: "track:2.flac"))
        XCTAssertLessThan(albumIndex, nextAlbumTrackIndex)
        XCTAssertEqual(Set(events.prefix(albumIndex)), Set(["track:0.flac", "track:1.flac"]))
        let status = try await service.status()
        XCTAssertEqual(status.progress, ReplayGainAnalysisProgress(total: 3, trackCompleted: 3, albumCompleted: 3))
    }

    func testAlbumAnalysisReceivesConfiguredConcurrency() async throws {
        let root = try makeRoot()
        let url = try makeAudioFile(in: root, name: "one.flac")
        let database = try makeDatabase(root: root, urls: [url])
        let observedConcurrency = PathProbe()
        let trackValues = readyTrackValues
        let albumValues = readyAlbumValues
        let service = ReplayGainAnalysisService(
            database: database,
            maximumConcurrentFileCount: 3,
            analyzeTrack: { item, database in
                _ = try database.commitReplayGainTrackResult(
                    trackID: item.trackID,
                    fingerprint: item.fingerprint,
                    claimToken: item.claimToken,
                    values: trackValues
                )
                return .committed(trackID: item.trackID, values: trackValues)
            },
            analyzeAlbum: { _, maximumConcurrentDecoding in
                observedConcurrency.set([String(maximumConcurrentDecoding())])
                return albumValues
            }
        )

        await service.start()
        await service.waitUntilIdle()

        XCTAssertEqual(observedConcurrency.value, ["3"])
    }

    func testAlbumAnalysisReadsUpdatedConcurrencyWhileRunning() async throws {
        let root = try makeRoot()
        let url = try makeAudioFile(in: root, name: "one.flac")
        let database = try makeDatabase(root: root, urls: [url])
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let observedConcurrency = PathProbe()
        let trackValues = readyTrackValues
        let albumValues = readyAlbumValues
        let service = ReplayGainAnalysisService(
            database: database,
            maximumConcurrentFileCount: 1,
            analyzeTrack: { item, database in
                _ = try database.commitReplayGainTrackResult(
                    trackID: item.trackID,
                    fingerprint: item.fingerprint,
                    claimToken: item.claimToken,
                    values: trackValues
                )
                return .committed(trackID: item.trackID, values: trackValues)
            },
            analyzeAlbum: { _, maximumConcurrentDecoding in
                observedConcurrency.set([String(maximumConcurrentDecoding())])
                entered.continuation.yield()
                for await _ in release.stream {
                    break
                }
                observedConcurrency.set(observedConcurrency.value + [String(maximumConcurrentDecoding())])
                return albumValues
            }
        )

        await service.start()
        _ = await entered.stream.first { _ in true }
        let active = try await service.status()
        XCTAssertEqual(active.stage, .albums)
        XCTAssertEqual(active.progress, ReplayGainAnalysisProgress(total: 1, trackCompleted: 1, albumCompleted: 0))
        await service.setMaximumConcurrentFileCount(3)
        release.continuation.yield()
        await service.waitUntilIdle()

        XCTAssertEqual(observedConcurrency.value, ["1", "3"])
    }

    func testChangingConcurrencyUsesLatestRevisionAndClampsAtFifteenFiles() async throws {
        let root = try makeRoot()
        let urls = try (0..<20).map { try makeAudioFile(in: root, name: "\($0).flac") }
        let database = try makeDatabase(root: root, urls: urls)
        let probe = AnalysisConcurrencyProbe()
        let trackValues = readyTrackValues
        let albumValues = readyAlbumValues
        let service = ReplayGainAnalysisService(
            database: database,
            analyzeTrack: { item, database in
                probe.enter()
                defer { probe.leave() }
                try await Task.sleep(for: .milliseconds(40))
                _ = try database.commitReplayGainTrackResult(
                    trackID: item.trackID,
                    fingerprint: item.fingerprint,
                    claimToken: item.claimToken,
                    values: trackValues
                )
                return .committed(trackID: item.trackID, values: trackValues)
            },
            analyzeAlbum: { _, _ in albumValues }
        )

        await service.start()
        try await waitUntil {
            (try await service.status()).counts.running == 1
        }
        await service.setMaximumConcurrentFileCount(99, revision: 2)
        await service.setMaximumConcurrentFileCount(2, revision: 1)
        await service.waitUntilIdle()

        XCTAssertEqual(probe.maximumActiveCount, 15)
        let status = try await service.status()
        XCTAssertEqual(status.maximumConcurrentFileCount, 15)
        XCTAssertEqual(status.counts, ReplayGainAnalysisStatusCounts(ready: urls.count))
        XCTAssertTrue(status.currentPaths.isEmpty)
    }

    func testCancelReleasesCurrentClaimAndStopsQueueConsumption() async throws {
        let root = try makeRoot()
        let urls = try (0..<2).map { try makeAudioFile(in: root, name: "\($0).flac") }
        let database = try makeDatabase(root: root, urls: urls)
        let albumValues = readyAlbumValues
        let service = ReplayGainAnalysisService(
            database: database,
            analyzeTrack: { _, _ in
                try await Task.sleep(for: .seconds(30))
                throw CancellationError()
            },
            analyzeAlbum: { _, _ in albumValues }
        )

        await service.start()
        try await waitUntil {
            let status = try await service.status()
            return status.counts.running == 1 && status.currentPath != nil
        }
        let active = try await service.status()
        XCTAssertNotNil(active.currentPath)
        XCTAssertTrue(active.isRunning)

        await service.cancel()

        let cancelled = try await service.status()
        XCTAssertEqual(cancelled.counts, ReplayGainAnalysisStatusCounts(pending: 2))
        XCTAssertNil(cancelled.currentPath)
        XCTAssertFalse(cancelled.isRunning)
    }
}
