import AVFoundation
@testable import WavebookCore
import XCTest

final class AudioPlaybackPlannerTests: XCTestCase {
    func testPlansMultipleUserSegmentsInSourceTime() throws {
        let url = try makeTestWAV(for: self, samples: Array(repeating: Int16(10_000), count: 10_000), sampleRate: 1_000)
        let file = try AVAudioFile(forReading: url)
        let plan = AudioPlaybackPlanner().plan(
            for: file,
            requestedStartTime: 0,
            skipSilentSegments: false,
            options: AudioPlaybackPlanner.Options(
                skipSegments: [
                    AudioSkipSegment(startTime: 2, endTime: 3),
                    AudioSkipSegment(startTime: 5, endTime: 6)
                ]
            )
        )

        XCTAssertEqual(plan.ranges.map(\.startTime), [0, 3, 6])
        XCTAssertEqual(plan.ranges.map(\.endTime), [2, 5, 10])
        XCTAssertEqual(plan.startTime, 0)
    }

    func testSeekInsideUserSegmentStartsAtItsEnd() throws {
        let url = try makeTestWAV(for: self, samples: Array(repeating: Int16(10_000), count: 10_000), sampleRate: 1_000)
        let file = try AVAudioFile(forReading: url)
        let plan = AudioPlaybackPlanner().plan(
            for: file,
            requestedStartTime: 2.5,
            skipSilentSegments: false,
            options: AudioPlaybackPlanner.Options(
                skipSegments: [AudioSkipSegment(startTime: 2, endTime: 3)]
            )
        )

        XCTAssertEqual(plan.startTime, 3, accuracy: 0.001)
        XCTAssertEqual(plan.ranges.map(\.startTime), [3])
        XCTAssertEqual(plan.ranges.map(\.endTime), [10])
    }

    func testOverlappingAndAdjacentSegmentsBecomeOneGap() throws {
        let url = try makeTestWAV(for: self, samples: Array(repeating: Int16(10_000), count: 10_000), sampleRate: 1_000)
        let file = try AVAudioFile(forReading: url)
        let plan = AudioPlaybackPlanner().plan(
            for: file,
            requestedStartTime: 0,
            skipSilentSegments: false,
            options: AudioPlaybackPlanner.Options(
                skipSegments: [
                    AudioSkipSegment(startTime: 2, endTime: 5),
                    AudioSkipSegment(startTime: 4, endTime: 7),
                    AudioSkipSegment(startTime: 7, endTime: 8),
                    AudioSkipSegment(startTime: .nan, endTime: 9)
                ]
            )
        )

        XCTAssertEqual(plan.ranges.map(\.startTime), [0, 8])
        XCTAssertEqual(plan.ranges.map(\.endTime), [2, 10])
    }

    func testFullTrackSegmentCompletesWithoutPlayableRanges() throws {
        let url = try makeTestWAV(for: self, samples: Array(repeating: Int16(10_000), count: 10_000), sampleRate: 1_000)
        let file = try AVAudioFile(forReading: url)
        let plan = AudioPlaybackPlanner().plan(
            for: file,
            requestedStartTime: 0,
            skipSilentSegments: false,
            options: AudioPlaybackPlanner.Options(
                skipSegments: [AudioSkipSegment(startTime: 0, endTime: 10)]
            )
        )

        XCTAssertTrue(plan.ranges.isEmpty)
        XCTAssertEqual(plan.startTime, 10, accuracy: 0.001)
    }
}
