import Foundation
@testable import WavebookCore
import XCTest

final class LibEBUR128Tests: XCTestCase {
    func testMeasuresChunkedStereoFloatPCM() throws {
        let state = try makeState(channelCount: 2)
        try addChunked(makeSineSamples(channelCount: 2, amplitude: 0.5), channelCount: 2, to: state)

        XCTAssertEqual(state.loudnessGlobal(), -6.05, accuracy: 0.1)
        for channel in 0..<2 {
            XCTAssertEqual(try state.samplePeak(channelNumber: UInt32(channel)), 0.5, accuracy: 0.0001)
        }
    }

    func testMeasuresChunkedMonoFloatPCM() throws {
        let state = try makeState(channelCount: 1)
        try addChunked(makeSineSamples(channelCount: 1, amplitude: 0.5), channelCount: 1, to: state)

        XCTAssertEqual(state.loudnessGlobal(), -9.06, accuracy: 0.1)
        XCTAssertEqual(try state.samplePeak(channelNumber: 0), 0.5, accuracy: 0.0001)
    }

    func testCombinesGlobalLoudnessSnapshots() throws {
        let loudState = try makeState(channelCount: 2)
        let quietState = try makeState(channelCount: 2)
        try addChunked(makeSineSamples(channelCount: 2, amplitude: 0.5), channelCount: 2, to: loudState)
        try addChunked(makeSineSamples(channelCount: 2, amplitude: 0.25), channelCount: 2, to: quietState)

        let loudness = LibEBUR128State.loudnessGlobalMultiple(
            snapshots: [loudState.snapshot(), quietState.snapshot()]
        )
        XCTAssertEqual(loudness, -8.087, accuracy: 0.1)
    }

    func testAcceptsMinimumSupportedSampleRate() throws {
        let state = try LibEBUR128State(channelCount: 1, sampleRate: 16)
        let samples = [Float](repeating: 0.25, count: 64)
        try samples.withUnsafeBufferPointer {
            try state.addFramesFloat($0, frameCount: samples.count)
        }

        XCTAssertEqual(try state.samplePeak(channelNumber: 0), 0.25, accuracy: 0.0001)
    }

    func testRejectsExcessiveSampleRate() {
        XCTAssertThrowsError(
            try LibEBUR128State(channelCount: 1, sampleRate: 192_001)
        )
    }

    private func makeState(channelCount: UInt32) throws -> LibEBUR128State {
        try LibEBUR128State(channelCount: channelCount, sampleRate: 48_000)
    }

    private func makeSineSamples(channelCount: Int, amplitude: Double) -> [Float] {
        let sampleRate = 48_000
        let frameCount = sampleRate * 3
        var samples = [Float](repeating: 0, count: frameCount * channelCount)
        for frame in 0..<frameCount {
            let phase = 2 * Double.pi * 1_000 * Double(frame) / Double(sampleRate)
            let sample = Float(sin(phase) * amplitude)
            for channel in 0..<channelCount {
                samples[frame * channelCount + channel] = sample
            }
        }
        return samples
    }

    private func addChunked(
        _ samples: [Float],
        channelCount: Int,
        to state: LibEBUR128State
    ) throws {
        try samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            let frameCount = samples.count / channelCount
            var offset = 0
            while offset < frameCount {
                let chunkFrames = min(16_384, frameCount - offset)
                let chunk = UnsafeBufferPointer(
                    start: baseAddress + offset * channelCount,
                    count: chunkFrames * channelCount
                )
                try state.addFramesFloat(chunk, frameCount: chunkFrames)
                offset += chunkFrames
            }
        }
    }
}
