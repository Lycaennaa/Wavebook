@testable import WavebookCore
import XCTest

final class ReplayGainAnalyzerErrorTests: XCTestCase {
    func testErrorDescriptionsRemainStableAcrossAnalyzerBoundaries() {
        let cases: [(ReplayGainAnalyzerError, String)] = [
            (.invalidSampleRate(0), "Invalid sample rate: 0.0"),
            (.unsupportedChannelCount(3), "Unsupported channel count: 3"),
            (.unsupportedChannelLayout(4), "Unsupported channel layout: 4"),
            (.emptyAudio, "Audio file contains no decoded frames"),
            (.decodedFrameCountMismatch(expected: 2, actual: 1), "Decoded frame count mismatch: expected 2, got 1"),
            (.invalidPCMBuffer, "Could not access decoded PCM samples"),
            (.libEBUR128InitializationFailed, "libebur128 could not initialize"),
             (
                 .libEBUR128CallFailed(operation: "add_frames_float", code: 2),
                 "libebur128 add_frames_float failed with code 2"
             ),
            (.undefinedLoudness, "Integrated loudness is undefined"),
            (.invalidSamplePeak, "Sample peak is undefined"),
            (.albumTrackLimitExceeded(501), "Album group exceeds 500 tracks: 501"),
            (.albumDurationLimitExceeded(172_801), "Album group exceeds 48 hours: 172801.0 seconds"),
            (.conflictingAlbumGainValues, "Album group contains conflicting gain tags"),
            (.conflictingAlbumPeakValues, "Album group contains conflicting peak tags")
        ]

        for (error, expectedDescription) in cases {
            XCTAssertEqual(error.errorDescription, expectedDescription)
        }
    }
}
