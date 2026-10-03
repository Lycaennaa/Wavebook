@testable import WavebookCore
import XCTest

extension ReplayGainAnalysisServiceTests {
    func testFailedClaimCleanupRetriesAndRestartRecoversClaim() async throws {
        let root = try makeRoot()
        let url = try makeAudioFile(in: root, name: "one.flac")
        let database = try makeDatabase(root: root, urls: [url])
        let claimProbe = ReplayGainClaimFailureProbe(database: database, releaseFailures: 10, recoveryFailures: 10)
        let trackValues = readyTrackValues
        let albumValues = readyAlbumValues
        let service = ReplayGainAnalysisService(
            database: database,
            analyzeTrack: { item, database in
                if claimProbe.nextAnalysisAttempt() == 1 {
                    throw TestServiceError.failed
                }
                _ = try database.commitReplayGainTrackResult(
                    trackID: item.trackID,
                    fingerprint: item.fingerprint,
                    claimToken: item.claimToken,
                    values: trackValues
                )
                return .committed(trackID: item.trackID, values: trackValues)
            },
            analyzeAlbum: { _, _ in albumValues },
            releaseClaim: { item in try claimProbe.release(item) },
            recoverClaim: { item in try claimProbe.recover(item) }
        )

        await service.start()
        await service.waitUntilIdle()

        let failedStatus = try await service.status()
        XCTAssertEqual(failedStatus.counts, ReplayGainAnalysisStatusCounts(running: 1))
        XCTAssertEqual(failedStatus.serviceErrorReason, "ReplayGain claim recovery failed")
        XCTAssertEqual(claimProbe.releaseCallCount, 3)
        XCTAssertEqual(claimProbe.recoveryCallCount, 3)

        claimProbe.allowCleanup()
        await service.start()
        await service.waitUntilIdle()

        let recovered = try XCTUnwrap(database.replayGainData(path: url.path))
        XCTAssertEqual(recovered.state, .ready)
        let recoveredStatus = try await service.status()
        XCTAssertEqual(recoveredStatus.counts, ReplayGainAnalysisStatusCounts(ready: 1))
        XCTAssertNil(recoveredStatus.serviceErrorReason)
    }

    func testFailedClaimCleanupDoesNotHideOtherPendingClaim() async throws {
        let root = try makeRoot()
        let urls = try (0..<2).map { try makeAudioFile(in: root, name: "\($0).flac") }
        let database = try makeDatabase(root: root, urls: urls)
        let secondID = try XCTUnwrap(database.replayGainData(path: urls[1].path)?.trackID)
        let claimProbe = ReplayGainClaimFailureProbe(database: database, releaseFailures: 10, recoveryFailures: 10)
        let albumValues = readyAlbumValues
        let service = ReplayGainAnalysisService(
            database: database,
            analyzeTrack: { _, _ in throw TestServiceError.failed },
            analyzeAlbum: { _, _ in albumValues },
            releaseClaim: { item in try claimProbe.release(item) },
            recoverClaim: { item in try claimProbe.recover(item) }
        )

        await service.start()
        await service.waitUntilIdle()

        let status = try await service.status()
        XCTAssertEqual(status.counts, ReplayGainAnalysisStatusCounts(pending: 1, running: 1))
        XCTAssertEqual(status.serviceErrorReason, "ReplayGain claim recovery failed")
        let available = try XCTUnwrap(database.claimNextPendingReplayGainItem())
        XCTAssertEqual(available.trackID, secondID)
        XCTAssertTrue(try database.releaseReplayGainClaim(
            trackID: available.trackID,
            fingerprint: available.fingerprint,
            claimToken: available.claimToken
        ))
    }

    func testRecoveryFailureStopsNewClaimsOnRestart() async throws {
        let root = try makeRoot()
        let urls = try (0..<2).map { try makeAudioFile(in: root, name: "\($0).flac") }
        let database = try makeDatabase(root: root, urls: urls)
        let claimProbe = ReplayGainClaimFailureProbe(database: database, releaseFailures: 100, recoveryFailures: 100)
        let albumValues = readyAlbumValues
        let service = ReplayGainAnalysisService(
            database: database,
            analyzeTrack: { _, _ in throw TestServiceError.failed },
            analyzeAlbum: { _, _ in albumValues },
            releaseClaim: { item in try claimProbe.release(item) },
            recoverClaim: { item in try claimProbe.recover(item) }
        )

        await service.start()
        await service.waitUntilIdle()
        let firstStatus = try await service.status()
        XCTAssertEqual(firstStatus.counts, ReplayGainAnalysisStatusCounts(pending: 1, running: 1))

        await service.start()
        await service.waitUntilIdle()
        let secondStatus = try await service.status()
        XCTAssertEqual(secondStatus.counts, firstStatus.counts)
    }

    func testDatabaseRestartRequeuesInterruptedClaimForAvailability() throws {
        let root = try makeRoot()
        let url = try makeAudioFile(in: root, name: "one.flac")
        let databaseURL = root.appending(path: "Library.sqlite")
        var trackID: Int64 = 0

        do {
            let database = try LibraryDatabase(path: databaseURL.path)
            let rootID = try database.addRoot(path: root.path)
            trackID = try database.save(track: Track(
                path: url.path,
                title: "one",
                artistDisplay: "Artist",
                albumTitle: "Album",
                albumArtist: "Artist",
                genreDisplay: "",
                duration: 1,
                format: "flac"
            ), rootID: rootID)
            let claim = try XCTUnwrap(database.claimNextPendingReplayGainItem())
            XCTAssertEqual(claim.trackID, trackID)
            XCTAssertEqual(try database.replayGainData(trackID: trackID)?.state, .running)
        }

        let restarted = try LibraryDatabase(path: databaseURL.path)
        XCTAssertEqual(try restarted.replayGainData(trackID: trackID)?.state, .pending)
        let available = try XCTUnwrap(restarted.claimNextPendingReplayGainItem())
        XCTAssertEqual(available.trackID, trackID)
        XCTAssertTrue(try restarted.releaseReplayGainClaim(
            trackID: available.trackID,
            fingerprint: available.fingerprint,
            claimToken: available.claimToken
        ))
    }
}

private final class ReplayGainClaimFailureProbe: @unchecked Sendable {
    private let database: LibraryDatabase
    private let lock = NSLock()
    private var releaseFailures: Int
    private var recoveryFailures: Int
    private var releaseCalls = 0
    private var recoveryCalls = 0
    private var analysisAttempts = 0

    init(database: LibraryDatabase, releaseFailures: Int, recoveryFailures: Int) {
        self.database = database
        self.releaseFailures = releaseFailures
        self.recoveryFailures = recoveryFailures
    }

    var releaseCallCount: Int {
        lock.withLock { releaseCalls }
    }

    var recoveryCallCount: Int {
        lock.withLock { recoveryCalls }
    }

    func nextAnalysisAttempt() -> Int {
        lock.withLock {
            analysisAttempts += 1
            return analysisAttempts
        }
    }

    func allowCleanup() {
        lock.withLock {
            releaseFailures = 0
            recoveryFailures = 0
        }
    }

    func release(_ item: ReplayGainPendingItem) throws -> Bool {
        let shouldFail = lock.withLock {
            releaseCalls += 1
            guard releaseFailures > 0 else { return false }
            releaseFailures -= 1
            return true
        }
        if shouldFail {
            throw ReplayGainClaimCleanupTestError.release
        }
        return try database.releaseReplayGainClaim(
            trackID: item.trackID,
            fingerprint: item.fingerprint,
            claimToken: item.claimToken
        )
    }

    func recover(_ item: ReplayGainPendingItem) throws -> Bool {
        let shouldFail = lock.withLock {
            recoveryCalls += 1
            guard recoveryFailures > 0 else { return false }
            recoveryFailures -= 1
            return true
        }
        if shouldFail {
            throw ReplayGainClaimCleanupTestError.recovery
        }
        return try database.recoverReplayGainClaim(trackID: item.trackID, claimToken: item.claimToken)
    }
}

private enum ReplayGainClaimCleanupTestError: Error, LocalizedError {
    case release
    case recovery

    var errorDescription: String? {
        switch self {
        case .release: "ReplayGain claim release failed"
        case .recovery: "ReplayGain claim recovery failed"
        }
    }
}
