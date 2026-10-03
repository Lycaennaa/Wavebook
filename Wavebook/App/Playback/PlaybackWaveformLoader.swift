@preconcurrency import AVFoundation
import Foundation
import WavebookCore

enum PlaybackWaveformLoader {
    nonisolated static let binCount = 1_200

    nonisolated private static let chunkFrameCapacity: AVAudioFrameCount = 16_384

    nonisolated static func load(from url: URL, shouldCancel: () -> Bool = { false }) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let length = file.length
        guard length > 0 else { return [] }
        guard file.processingFormat.channelCount > 0 else { return [] }

        let capacity = AVAudioFrameCount(min(Int64(Self.chunkFrameCapacity), length))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
            return []
        }
        guard let pcmReader = AudioPCMBufferReader(buffer: buffer) else { return [] }

        var peaks = [Float](repeating: 0, count: Self.binCount)
        var decodedFrameCount: AVAudioFramePosition = 0
        while decodedFrameCount < length {
            guard !shouldCancel() else { throw CancellationError() }
            let remainingFrames = length - decodedFrameCount
            let requestedFrameCount = AVAudioFrameCount(min(Int64(Self.chunkFrameCapacity), remainingFrames))
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: requestedFrameCount)
            let frameCount = AVAudioFramePosition(buffer.frameLength)
            guard frameCount > 0 else { return [] }

            pcmReader.accumulatePeaks(
                into: &peaks,
                startingAt: decodedFrameCount,
                totalFrameCount: length
            )
            decodedFrameCount += frameCount
        }
        return peaks
    }

}
