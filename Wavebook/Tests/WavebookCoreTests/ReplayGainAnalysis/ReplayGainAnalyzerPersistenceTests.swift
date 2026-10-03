import AudioToolbox
@preconcurrency import AVFoundation
import Foundation
@testable import WavebookCore
import XCTest

extension ReplayGainAnalyzerTests {
    func testClaimedPendingItemCommitsMeasuredValues() async throws {
        let root = try makeRoot()
        let url = try makeSineWAV(in: root, amplitude: 0.5)
        let database = try makeDatabase(root: root, url: url)
        let outcome = try await ReplayGainAnalyzer(chunkFrameCapacity: 1_024).analyzeNextPendingItem(in: database)

        guard case let .committed(trackID, values) = outcome else {
            return XCTFail("Expected committed outcome, got \(outcome)")
        }
        let stored = try XCTUnwrap(database.replayGainData(trackID: trackID))
        XCTAssertEqual(stored.state, .ready)
        XCTAssertEqual(stored.track, values)
        XCTAssertEqual(values.gain?.source, .measured)
        XCTAssertEqual(values.samplePeak ?? 0, 0.5, accuracy: 0.0001)
        let nextOutcome = try await ReplayGainAnalyzer().analyzeNextPendingItem(in: database)
        XCTAssertEqual(nextOutcome, .noPendingItem)
    }

    func testClaimedTaggedItemCommitsAuthoritativeReplayGainValues() async throws {
        let root = try makeRoot()
        let source = try fixtureURL(fileExtension: "flac")
        let url = root.appending(path: "tagged.flac")
        try FileManager.default.copyItem(at: source, to: url)
        let database = try makeDatabase(root: root, url: url)

        let outcome = try await ReplayGainAnalyzer().analyzeNextPendingItem(in: database)

        guard case let .committed(trackID, values) = outcome else {
            return XCTFail("Expected committed outcome, got \(outcome)")
        }
        XCTAssertEqual(values.gain, ReplayGainGain(decibels: -7.25, source: .replayGain))
        XCTAssertEqual(values.samplePeak, 0.987654)
        XCTAssertEqual(try database.replayGainData(trackID: trackID)?.track, values)
    }

    func testChangedFileIsRequeuedWithCurrentFingerprintInsteadOfLoopingOnStaleClaim() async throws {
        let root = try makeRoot()
        let url = try makeSineWAV(in: root, amplitude: 0.5)
        let database = try makeDatabase(root: root, url: url)
        let trackID = try XCTUnwrap(database.replayGainData(path: url.path)?.trackID)
        XCTAssertEqual(
            try XCTUnwrap(database.replayGainData(path: url.path)?.fingerprint.modificationDate).timeIntervalSince1970,
             try XCTUnwrap(
                 url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
             ).timeIntervalSince1970
        )
        var changedData = try Data(contentsOf: url)
        changedData.append(0)
        try changedData.write(to: url)

        let staleOutcome = try await ReplayGainAnalyzer().analyzeNextPendingItem(in: database)
        XCTAssertEqual(staleOutcome, .discardedStale(trackID: trackID))
        let refreshed = try XCTUnwrap(database.replayGainData(path: url.path))
        XCTAssertEqual(refreshed.state, .pending)
        XCTAssertEqual(refreshed.fingerprint.fileSize, Int64(try Data(contentsOf: url).count))

        let committedOutcome = try await ReplayGainAnalyzer().analyzeNextPendingItem(in: database)
        guard case .committed = committedOutcome else {
            return XCTFail("Expected refreshed claim to commit, got \(committedOutcome)")
        }
    }

    func testClaimCommitRechecksFilesystemFingerprintBeforePublishingResult() throws {
        let root = try makeRoot()
        let url = try makeSineWAV(in: root, amplitude: 0.5)
        let database = try makeDatabase(root: root, url: url)
        let pending = try XCTUnwrap(database.claimNextPendingReplayGainItem())
        var changedData = try Data(contentsOf: url)
        changedData.append(0)
        try changedData.write(to: url)

        XCTAssertFalse(
            try database.commitReplayGainTrackResult(
                trackID: pending.trackID,
                fingerprint: pending.fingerprint,
                claimToken: pending.claimToken,
                values: ReplayGainScopeValues(
                    gain: ReplayGainGain(decibels: -4, source: .measured),
                    samplePeak: 0.5
                )
            )
        )
        let stored = try XCTUnwrap(database.replayGainData(trackID: pending.trackID))
        XCTAssertEqual(stored.state, .pending)
        XCTAssertNil(stored.track)
        XCTAssertEqual(stored.fingerprint.fileSize, Int64(changedData.count))
    }

}
