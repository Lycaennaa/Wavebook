import AVFoundation
import Foundation
@testable import WavebookCore
import XCTest

final class AudioSilenceDetectorTests: XCTestCase {
    func testDetectsLeadingAndTrailingSilence() throws {
        let leadingSilence = 3_200
        let signal = 8_000
        let trailingSilence = 2_400
        let url = try makeTestWAV(for: self, samples: Array(repeating: 0, count: leadingSilence)
            + Array(repeating: 10_000, count: signal)
            + Array(repeating: 0, count: trailingSilence))

        let boundaries = try AudioSilenceDetector().boundaries(for: AVAudioFile(forReading: url))

        XCTAssertEqual(boundaries.startFrame, AVAudioFramePosition(leadingSilence))
        XCTAssertEqual(boundaries.endFrame, AVAudioFramePosition(leadingSilence + signal))
    }

    func testDoesNotSkipShortSilence() throws {
        let samples: [Int16] = Array(repeating: 0, count: 1_000)
            + Array(repeating: 10_000, count: 8_000)
            + Array(repeating: 0, count: 1_000)
        let url = try makeTestWAV(for: self, samples: samples)

        let boundaries = try AudioSilenceDetector().boundaries(for: AVAudioFile(forReading: url))

        XCTAssertEqual(boundaries, AudioSilenceBoundaries(startFrame: 0, endFrame: AVAudioFramePosition(samples.count)))
    }

    func testDoesNotSkipCompletelySilentAudio() throws {
        let samples = Array(repeating: Int16(0), count: 10_000)
        let url = try makeTestWAV(for: self, samples: samples)

        let boundaries = try AudioSilenceDetector().boundaries(for: AVAudioFile(forReading: url))

        XCTAssertEqual(boundaries, AudioSilenceBoundaries(startFrame: 0, endFrame: AVAudioFramePosition(samples.count)))
    }

    func testFormatsSilentSkipMessages() {
        XCTAssertEqual(
            AudioPlaybackSkipMessage.detected(leadingDuration: 0.4, trailingDuration: 2),
            "Silence detected: 0.4s at start and 2.0s at end"
        )
        XCTAssertEqual(
            AudioPlaybackSkipMessage.detected(leadingDuration: 0.4, trailingDuration: 0),
            "Silence detected: 0.4s at start"
        )
        XCTAssertEqual(
            AudioPlaybackSkipMessage.detected(leadingDuration: 0, trailingDuration: 2),
            "Silence detected: 2.0s at end"
        )
        XCTAssertEqual(
            AudioPlaybackSkipMessage.completed(trailingDuration: 2),
            "Skipped 2.0s of trailing silence"
        )
        XCTAssertNil(AudioPlaybackSkipMessage.detected(leadingDuration: 0, trailingDuration: 0))
    }

}
