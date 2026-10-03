import AVFoundation

/// Reads bounded peaks from PCM buffers.
public struct AudioPCMBufferReader {
    private let buffer: AVAudioPCMBuffer
    private let channelCount: Int
    private let stride: Int
    private let isInterleaved: Bool

    /// Number of frames in the buffer.
    public var frameCount: Int {
        Int(buffer.frameLength)
    }

    /// Creates a reader when channel data is available.
    public init?(buffer: AVAudioPCMBuffer) {
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0, buffer.floatChannelData != nil else { return nil }
        self.buffer = buffer
        self.channelCount = channelCount
        stride = max(buffer.stride, 1)
        isInterleaved = buffer.format.isInterleaved
    }
    /// Returns the bounded absolute peak at a frame.
    public func peak(at frame: Int) -> Float {
        guard frame >= 0, frame < frameCount, let channelData = buffer.floatChannelData else { return 0 }
        return peak(from: channelData, sampleOffset: frame * stride)
    }

    /// Accumulates bounded peaks into bins for the complete stream.
    /// - Parameters:
    ///   - peaks: Existing bin maxima, updated in place.
    ///   - startingAt: Absolute stream frame of the buffer's first frame.
    ///   - totalFrameCount: Total stream length used to map frames to bins.
    public func accumulatePeaks(
        into peaks: inout [Float],
        startingAt startFrame: Int64,
        totalFrameCount: Int64
    ) {
        guard startFrame >= 0, totalFrameCount > startFrame, !peaks.isEmpty,
              let channelData = buffer.floatChannelData else {
            return
        }
        let frameCount = min(Int64(buffer.frameLength), totalFrameCount - startFrame)
        guard frameCount > 0 else { return }

        peaks.withUnsafeMutableBufferPointer { peakData in
            let binDivisor = Int64(peakData.count)
            let framesPerBin = totalFrameCount / binDivisor
            let frameRemainder = totalFrameCount % binDivisor
            var bin = 0
            var nextBinFrame = Self.frameBoundary(
                for: 1,
                framesPerBin: framesPerBin,
                frameRemainder: frameRemainder,
                binDivisor: binDivisor
            )
            while bin + 1 < peakData.count, startFrame >= nextBinFrame {
                bin += 1
                nextBinFrame = Self.frameBoundary(
                    for: bin + 1,
                    framesPerBin: framesPerBin,
                    frameRemainder: frameRemainder,
                    binDivisor: binDivisor
                )
            }

            for offset in 0..<Int(frameCount) {
                let frame = startFrame + Int64(offset)
                while bin + 1 < peakData.count, frame >= nextBinFrame {
                    bin += 1
                    nextBinFrame = Self.frameBoundary(
                        for: bin + 1,
                        framesPerBin: framesPerBin,
                        frameRemainder: frameRemainder,
                        binDivisor: binDivisor
                    )
                }
                peakData[bin] = max(peakData[bin], peak(from: channelData, sampleOffset: offset * stride))
            }
        }
    }

    private func peak(
        from channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        sampleOffset: Int
    ) -> Float {
        var peak: Float = 0
        if isInterleaved {
            for channel in 0..<channelCount {
                let sample = channelData[0][sampleOffset + channel]
                guard sample.isFinite else { continue }
                peak = max(peak, min(abs(sample), 1))
            }
        } else {
            for channel in 0..<channelCount {
                let sample = channelData[channel][sampleOffset]
                guard sample.isFinite else { continue }
                peak = max(peak, min(abs(sample), 1))
            }
        }
        return peak
    }

    private static func frameBoundary(
        for binIndex: Int,
        framesPerBin: Int64,
        frameRemainder: Int64,
        binDivisor: Int64
    ) -> Int64 {
        let index = Int64(binIndex)
        return framesPerBin * index + (frameRemainder * index + binDivisor - 1) / binDivisor
    }
}
