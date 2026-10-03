import AVFoundation
import XCTest

@testable import WavebookCore

final class AudioPlaybackTransitionTests: XCTestCase {
    func testCrossfadeScheduleOverlapsGapAndMapsSourceTime() {
        let schedule = AudioPlaybackSchedule(
            ranges: [
                AudioPlaybackRange(startFrame: 0, endFrame: 200, endTime: 0.2),
                AudioPlaybackRange(startFrame: 500, endFrame: 1_000, endTime: 1, startTime: 0.5)
            ],
            sampleRate: 1_000
        )

        XCTAssertEqual(schedule.scheduledRanges.map(\.trailingTransitionFrameCount), [40, 0])
        XCTAssertEqual(schedule.startTime(forRangeAt: 1), 0.54, accuracy: 0.000_001)
        XCTAssertEqual(schedule.outputSegments.count, 3)
        XCTAssertEqual(schedule.outputDuration, 0.66, accuracy: 0.000_001)
        XCTAssertEqual(schedule.sourcePosition(forAudibleElapsed: 0.16), 0.16, accuracy: 0.000_001)
        XCTAssertEqual(schedule.sourcePosition(forAudibleElapsed: 0.2), 0.54, accuracy: 0.000_001)
        XCTAssertEqual(schedule.audibleElapsed(forSourcePosition: 0.54), 0.2, accuracy: 0.000_001)
    }

    func testCrossfadeScheduleClampsShortRangesAndSkipsAdjacentRanges() {
        let schedule = AudioPlaybackSchedule(
            ranges: [
                AudioPlaybackRange(startFrame: 0, endFrame: 10, endTime: 0.01),
                AudioPlaybackRange(startFrame: 20, endFrame: 30, endTime: 0.03, startTime: 0.02),
                AudioPlaybackRange(startFrame: 30, endFrame: 40, endTime: 0.04, startTime: 0.03)
            ],
            sampleRate: 1_000
        )

        XCTAssertEqual(schedule.scheduledRanges.map(\.trailingTransitionFrameCount), [5, 0, 0])
        XCTAssertEqual(schedule.outputSegments.count, 4)
    }
    func testCrossfadeDisablesForOneFrameTransitions() {
        let schedule = AudioPlaybackSchedule(
            ranges: [
                AudioPlaybackRange(startFrame: 0, endFrame: 2, endTime: 0.002),
                AudioPlaybackRange(startFrame: 4, endFrame: 6, endTime: 0.006, startTime: 0.004)
            ],
            sampleRate: 1_000
        )

        XCTAssertEqual(schedule.scheduledRanges.map(\.trailingTransitionFrameCount), [0, 0])
    }

    @MainActor
    func testCrossfadeBufferBlendsTailAndHead() throws {
        let samples = Array(repeating: Int16(10_000), count: 400)
            + Array(repeating: Int16(0), count: 400)
            + Array(repeating: Int16(-10_000), count: 400)
        let url = try makeTestWAV(for: self, samples: samples)
        let file = try AVAudioFile(forReading: url)
        let schedule = AudioPlaybackSchedule(
            ranges: [
                AudioPlaybackRange(startFrame: 0, endFrame: 400, endTime: 0.05),
                AudioPlaybackRange(startFrame: 800, endFrame: 1_200, endTime: 0.15, startTime: 0.1)
            ],
            sampleRate: file.processingFormat.sampleRate
        )
        let buffers = try AudioPlaybackTransitionBuilder.makeBuffers(
            for: schedule,
            url: url,
            format: file.processingFormat,
            outputFormat: file.processingFormat
        )
        let buffer = try XCTUnwrap(buffers[schedule.scheduledRanges[0].source])
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        let lastFrame = Int(buffer.frameLength) - 1

        XCTAssertGreaterThan(channelData[0][0], 0)
        XCTAssertLessThan(channelData[0][lastFrame], 0)
        XCTAssertLessThan(abs(channelData[0][lastFrame / 2]), 0.02)
    }
}
