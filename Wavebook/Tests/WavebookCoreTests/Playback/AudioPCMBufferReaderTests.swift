import AVFoundation
@testable import WavebookCore
import XCTest

final class AudioPCMBufferReaderTests: XCTestCase {
    func testReadsInterleavedStereoPeaksByFrame() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 8_000,
            channels: 2,
            interleaved: true
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        buffer.frameLength = 3
        let samples: [Float] = [0.25, 0, 0.1, -0.75, 1.2, 0.2]
         let channelData = try XCTUnwrap(buffer.floatChannelData)
        for (index, sample) in samples.enumerated() {
             channelData[0][index] = sample
        }

        let reader = try XCTUnwrap(AudioPCMBufferReader(buffer: buffer))

        XCTAssertEqual(reader.peak(at: 0), 0.25, accuracy: 0.0001)
        XCTAssertEqual(reader.peak(at: 1), 0.75, accuracy: 0.0001)
        XCTAssertEqual(reader.peak(at: 2), 1, accuracy: 0.0001)
    }

    func testReadsNonInterleavedStereoPeaksByFrame() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 8_000,
            channels: 2,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        buffer.frameLength = 3
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        let left: [Float] = [0, -0.5, 0.1]
        let right: [Float] = [0.2, 0.25, 0]
        for frame in 0..<3 {
            channelData[0][frame] = left[frame]
            channelData[1][frame] = right[frame]
        }

        let reader = try XCTUnwrap(AudioPCMBufferReader(buffer: buffer))

        XCTAssertEqual(reader.peak(at: 0), 0.2, accuracy: 0.0001)
        XCTAssertEqual(reader.peak(at: 1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(reader.peak(at: 2), 0.1, accuracy: 0.0001)
    }

    func testAccumulatesWaveformPeaksAcrossChunkBoundaries() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 8_000,
            channels: 2,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 5))
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        let reader = try XCTUnwrap(AudioPCMBufferReader(buffer: buffer))
        var peaks = [Float](repeating: 0, count: 3)

        buffer.frameLength = 2
        channelData[0][0] = 0.1
        channelData[0][1] = 0.7
        channelData[1][0] = 0
        channelData[1][1] = 0.2
        reader.accumulatePeaks(into: &peaks, startingAt: 0, totalFrameCount: 5)

        buffer.frameLength = 3
        channelData[0][0] = 0.2
        channelData[0][1] = 0.3
        channelData[0][2] = 0.4
        channelData[1][0] = 0
        channelData[1][1] = 0
        channelData[1][2] = 0
        reader.accumulatePeaks(into: &peaks, startingAt: 2, totalFrameCount: 5)

        XCTAssertEqual(peaks, [0.7, 0.3, 0.4])
    }

}
