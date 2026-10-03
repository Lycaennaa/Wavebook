import Foundation
@testable import WavebookCore
import XCTest

extension ReplayGainAnalysisServiceTests {
    func testSelectedAndWholeRescanCancelThenRestartWithoutDuplicateWorkers() async throws {
        let root = try makeRoot()
        let urls = try (0..<2).map { try makeAudioFile(in: root, name: "\($0).flac") }
        let database = try makeDatabase(root: root, urls: urls)
        let firstID = try XCTUnwrap(database.replayGainData(path: urls[0].path)?.trackID)
        let probe = AnalysisConcurrencyProbe()
        let trackValues = readyTrackValues
        let albumValues = readyAlbumValues
        let service = ReplayGainAnalysisService(
            database: database,
            analyzeTrack: { item, database in
                probe.enter()
                defer { probe.leave() }
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
        await service.waitUntilIdle()
        XCTAssertEqual(probe.callCount, 2)

        try await service.rescan(trackIDs: [firstID, firstID])
        await service.waitUntilIdle()
        XCTAssertEqual(probe.callCount, 4)

        try await service.rescanAll()
        await service.waitUntilIdle()
        XCTAssertEqual(probe.callCount, 6)
        XCTAssertEqual(probe.maximumActiveCount, 1)
        let status = try await service.status()
        XCTAssertEqual(status.counts, ReplayGainAnalysisStatusCounts(ready: 2))
    }

    func testUnexpectedWorkerErrorIsSurfacedAndClaimIsReleased() async throws {
        let root = try makeRoot()
        let url = try makeAudioFile(in: root, name: "one.flac")
        let database = try makeDatabase(root: root, urls: [url])
        let albumValues = readyAlbumValues
        let service = ReplayGainAnalysisService(
            database: database,
            analyzeTrack: { _, _ in throw TestServiceError.failed },
            analyzeAlbum: { _, _ in albumValues }
        )

        await service.start()
        await service.waitUntilIdle()

        let status = try await service.status()
        XCTAssertEqual(status.counts, ReplayGainAnalysisStatusCounts(pending: 1))
        XCTAssertEqual(status.serviceErrorReason, "service failed")
        XCTAssertFalse(status.isRunning)
    }
    func testRequeueDuringIdleWakesWorkerWhenStartSeesExistingWorker() async throws {
        let root = try makeRoot()
        let url = try makeAudioFile(in: root, name: "one.flac")
        let database = try makeDatabase(root: root, urls: [url])
        let trackID = try XCTUnwrap(database.replayGainData(path: url.path)?.trackID)
        let idle = AsyncStream<Void>.makeStream()
        let resume = AsyncStream<Void>.makeStream()
        let probe = AnalysisConcurrencyProbe()
        let trackValues = readyTrackValues
        let albumValues = readyAlbumValues
        let service = ReplayGainAnalysisService(
            database: database,
            analyzeTrack: { item, database in
                probe.enter()
                defer { probe.leave() }
                _ = try database.commitReplayGainTrackResult(
                    trackID: item.trackID,
                    fingerprint: item.fingerprint,
                    claimToken: item.claimToken,
                    values: trackValues
                )
                return .committed(trackID: item.trackID, values: trackValues)
            },
            analyzeAlbum: { _, _ in albumValues },
            workerIdleHandler: {
                idle.continuation.yield()
                for await _ in resume.stream { break }
            }
        )

        await service.start()
        _ = await idle.stream.first { _ in true }
        let waitingStatus = try await service.status()
        XCTAssertEqual(waitingStatus.stage, .waiting)
        XCTAssertTrue(waitingStatus.isRunning)
        idle.continuation.finish()
        try database.requeueReplayGain(trackIDs: [trackID])
        await service.start()
        resume.continuation.finish()
        await service.waitUntilIdle()

        XCTAssertEqual(probe.callCount, 2)
        let status = try await service.status()
        XCTAssertEqual(status.counts, ReplayGainAnalysisStatusCounts(ready: 1))
        XCTAssertFalse(status.isRunning)
    }

    func testClaimReleaseFailureRecoversPendingClaimForRetry() async throws {
        let root = try makeRoot()
        let url = try makeAudioFile(in: root, name: "one.flac")
        let database = try makeDatabase(root: root, urls: [url])
        let trackID = try XCTUnwrap(database.replayGainData(path: url.path)?.trackID)
        let albumValues = readyAlbumValues
        let service = ReplayGainAnalysisService(
            database: database,
            analyzeTrack: { _, _ in
                try Data([1, 2]).write(to: url)
                throw TestServiceError.failed
            },
            analyzeAlbum: { _, _ in albumValues }
        )

        await service.start()
        await service.waitUntilIdle()

        let status = try await service.status()
        XCTAssertEqual(status.counts, ReplayGainAnalysisStatusCounts(pending: 1))
        XCTAssertEqual(status.serviceErrorReason, "service failed")
        XCTAssertFalse(status.isRunning)
        let data = try XCTUnwrap(database.replayGainData(trackID: trackID))
        XCTAssertEqual(data.state, .pending)
        let retry = try XCTUnwrap(database.claimNextPendingReplayGainItem())
        XCTAssertEqual(retry.trackID, trackID)
        XCTAssertTrue(try database.releaseReplayGainClaim(
            trackID: retry.trackID,
            fingerprint: retry.fingerprint,
            claimToken: retry.claimToken
        ))
    }

    func testCancellationPreservesCancellationWhenClaimReleaseFails() async throws {
        let root = try makeRoot()
        let url = try makeAudioFile(in: root, name: "one.flac")
        let database = try makeDatabase(root: root, urls: [url])
        let albumValues = readyAlbumValues
        let service = ReplayGainAnalysisService(
            database: database,
            analyzeTrack: { _, _ in
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch is CancellationError {
                    try Data([1, 2]).write(to: url)
                    throw CancellationError()
                }
                throw TestServiceError.failed
            },
            analyzeAlbum: { _, _ in albumValues }
        )

        await service.start()
        try await waitUntil {
            let status = try await service.status()
            return status.counts.running == 1 && status.currentPath != nil
        }
        await service.cancel()

        let status = try await service.status()
        XCTAssertEqual(status.counts, ReplayGainAnalysisStatusCounts(pending: 1))
        XCTAssertNil(status.serviceErrorReason)
        XCTAssertFalse(status.isRunning)
    }
}
