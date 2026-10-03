import AudioToolbox
@preconcurrency import AVFoundation
import Foundation
@testable import WavebookCore
import XCTest

extension ReplayGainAnalyzerTests {
    func testAlbumAnalysisHonorsCancellationBeforeReturningTags() async throws {
        let cancellation = CancellationProbe(cancelAt: 1)
        let analyzer = ReplayGainAnalyzer(
            chunkFrameCapacity: 1_024,
            cancellationCheck: cancellation.check
        )

        do {
            _ = try await analyzer.albumValues(
                tagURLs: [try fixtureURL(fileExtension: "flac")],
                measurementURLs: []
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
    }

    func testConcurrentAlbumMeasurementHonorsCancellationDuringDecode() async throws {
        let loud = try makeSineWAV(duration: 10, amplitude: 0.5)
        let quiet = try makeSineWAV(duration: 10, amplitude: 0.25)
        let cancellation = CancellationProbe(cancelAt: 5)
        let analyzer = ReplayGainAnalyzer(
            chunkFrameCapacity: 1_024,
            cancellationCheck: cancellation.check
        )

        do {
            _ = try await analyzer.albumValues(
                tagURLs: [],
                measurementURLs: [loud, quiet]
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
    }

    func testConcurrentAlbumMeasurementStopsSchedulingAfterDecodeFailure() async throws {
        let measurement = try makeDecoderMeasurement()
        let probe = AnalysisConcurrencyProbe()
        let urls = (0..<5).map { URL(fileURLWithPath: "/virtual/\($0)") }
        let decoder = ReplayGainAlbumDecoder(
            concurrency: 2,
            cancellationCheck: {},
            decode: { url in
                probe.enter()
                defer { probe.leave() }
                if url.lastPathComponent == "0" {
                    throw ReplayGainAnalyzerError.invalidSamplePeak
                }
                try await Task.sleep(for: .milliseconds(100))
                return measurement
            }
        )

        do {
            _ = try await decoder.measure(urls: urls)
            XCTFail("Expected invalid sample peak error")
        } catch let error as ReplayGainAnalyzerError {
            XCTAssertEqual(error, .invalidSamplePeak)
        }

        XCTAssertEqual(probe.callCount, 2)
        XCTAssertLessThanOrEqual(probe.maximumActiveCount, 2)
    }

    func testSilenceFailsWithoutAUsableResult() throws {
        let url = try makeSineWAV(amplitude: 0)

        XCTAssertThrowsError(try ReplayGainAnalyzer().measure(url: url)) { error in
            XCTAssertEqual(error as? ReplayGainAnalyzerError, .invalidSamplePeak)
        }
    }

    func testFileChangeDuringDecodeRequeuesInsteadOfRecordingFailure() async throws {
        let root = try makeRoot()
        let url = try makeSineWAV(in: root, duration: 10, amplitude: 0.5)
        let database = try makeDatabase(root: root, url: url)
        let trackID = try XCTUnwrap(database.replayGainData(path: url.path)?.trackID)
        let mutation = FileMutationProbe(url: url, mutateAt: 3)
        let analyzer = ReplayGainAnalyzer(chunkFrameCapacity: 1_024, cancellationCheck: mutation.check)

        let outcome = try await analyzer.analyzeNextPendingItem(in: database)

        XCTAssertEqual(outcome, .discardedStale(trackID: trackID))
        XCTAssertEqual(try database.replayGainData(path: url.path)?.state, .pending)
        XCTAssertTrue(try database.replayGainFailures().isEmpty)
    }

    func testDecodeFailureIsRecordedAndNotAutomaticallyRetried() async throws {
        let root = try makeRoot()
        let url = root.appending(path: "corrupt.flac")
        try Data("not audio".utf8).write(to: url)
        let database = try makeDatabase(root: root, url: url)

        let outcome = try await ReplayGainAnalyzer().analyzeNextPendingItem(in: database)

        guard case let .failed(trackID, reason) = outcome else {
            return XCTFail("Expected failed outcome, got \(outcome)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(try database.replayGainData(trackID: trackID)?.state, .failed)
        XCTAssertEqual(try database.replayGainFailures().count, 1)
        let nextOutcome = try await ReplayGainAnalyzer().analyzeNextPendingItem(in: database)
        XCTAssertEqual(nextOutcome, .noPendingItem)
    }

    func testCancellationMidFileReleasesClaimWithoutPartialResult() async throws {
        let root = try makeRoot()
        let url = try makeSineWAV(in: root, duration: 10, amplitude: 0.5)
        let database = try makeDatabase(root: root, url: url)
        let cancellation = CancellationProbe(cancelAt: 5)
        let analyzer = ReplayGainAnalyzer(chunkFrameCapacity: 1_024, cancellationCheck: cancellation.check)

        do {
            let outcome = try await analyzer.analyzeNextPendingItem(in: database)
            XCTFail("Expected cancellation, got \(outcome)")
        } catch is CancellationError {
        }

        let pending = try XCTUnwrap(database.replayGainData(path: url.path))
        XCTAssertEqual(pending.state, .pending)
        XCTAssertNil(pending.track)
        XCTAssertNotNil(try database.claimNextPendingReplayGainItem())
    }

}
