import AudioToolbox
@preconcurrency import AVFoundation
import Foundation
@testable import WavebookCore
import XCTest

extension ReplayGainAnalyzerTests {
    func testSingleTrackResourceLimitsKeepExactBoundaryValid() throws {
        let analyzer = ReplayGainAnalyzer()
        let frameCount = ReplayGainAnalyzer.maximumTrackDecodedByteCount / 8

        XCTAssertNoThrow(
            try analyzer.validateTrackBounds(
                frameCount: frameCount,
                sampleRate: 48_000,
                channelCount: 2
            )
        )
    }

    func testSingleTrackResourceLimitsRejectDurationFrameAndDecodedByteOverflow() throws {
        let analyzer = ReplayGainAnalyzer()
        let durationFrameCount = Int64(ReplayGainAnalyzer.maximumTrackDuration * 48_000) + 1
        let decodedByteFrameCount = ReplayGainAnalyzer.maximumTrackDecodedByteCount / 8 + 1

        XCTAssertThrowsError(
            try analyzer.validateTrackBounds(
                frameCount: durationFrameCount,
                sampleRate: 48_000,
                channelCount: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? ReplayGainAnalysisLimitError,
                .durationExceeded(Double(durationFrameCount) / 48_000)
            )
        }

        XCTAssertThrowsError(
            try analyzer.validateTrackBounds(
                frameCount: ReplayGainAnalyzer.maximumTrackFrameCount + 1,
                sampleRate: 192_000,
                channelCount: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? ReplayGainAnalysisLimitError,
                .frameCountExceeded(ReplayGainAnalyzer.maximumTrackFrameCount + 1)
            )
        }

        XCTAssertThrowsError(
            try analyzer.validateTrackBounds(
                frameCount: decodedByteFrameCount,
                sampleRate: 48_000,
                channelCount: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? ReplayGainAnalysisLimitError,
                .decodedByteCountExceeded(decodedByteFrameCount * 8)
            )
        }
    }

    func testSparseTrackWithExcessiveDeclaredFrameCountIsRejectedBeforeDecoding() throws {
        let frameCount = try XCTUnwrap(UInt32(exactly: ReplayGainAnalyzer.maximumTrackFrameCount + 1))
        let url = try makeSparseWAV(frameCount: frameCount, channelCount: 1)

        XCTAssertThrowsError(try ReplayGainAnalyzer().measure(url: url)) { error in
            XCTAssertEqual(
                error as? ReplayGainAnalysisLimitError,
                .frameCountExceeded(Int64(frameCount))
            )
        }
    }
    func testAlbumMeasurementURLsRespectTrackLimit() async throws {
        let urls = Array(
            repeating: URL(fileURLWithPath: "/unused"),
            count: ReplayGainAnalyzer.maximumAlbumTrackCount + 1
        )

        do {
            _ = try await ReplayGainAnalyzer().albumValues(
                tagURLs: [],
                measurementURLs: urls
            )
            XCTFail("Expected album track limit error")
        } catch let error as ReplayGainAnalyzerError {
            XCTAssertEqual(
                error,
                .albumTrackLimitExceeded(ReplayGainAnalyzer.maximumAlbumTrackCount + 1)
            )
        }
    }

    func testExplicitNonStereoTwoChannelLayoutIsRejected() {
        XCTAssertThrowsError(
            try ReplayGainAnalyzer().validateChannelLayout(
                channelCount: 2,
                layoutTag: kAudioChannelLayoutTag_UseChannelDescriptions
            )
        ) { error in
            XCTAssertEqual(
                error as? ReplayGainAnalyzerError,
                .unsupportedChannelLayout(kAudioChannelLayoutTag_UseChannelDescriptions)
            )
        }
    }

}
