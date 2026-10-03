import AVFoundation
import Foundation

struct AudioSilenceBoundaries: Equatable, Sendable {
    let startFrame: AVAudioFramePosition
    let endFrame: AVAudioFramePosition

    static func full(length: AVAudioFramePosition) -> Self {
        Self(startFrame: 0, endFrame: length)
    }
}

enum AudioSilenceDetectorError: Error, Equatable, LocalizedError {
    case invalidSampleRate(Double)
    case unsupportedChannelCount(UInt32)
    case invalidPCMBuffer
    case decodedFrameCountMismatch(expected: AVAudioFramePosition, actual: AVAudioFramePosition)

    var errorDescription: String? {
        switch self {
        case let .invalidSampleRate(sampleRate):
            "Invalid audio sample rate: \(sampleRate)"
        case let .unsupportedChannelCount(channelCount):
            "Unsupported audio channel count: \(channelCount)"
        case .invalidPCMBuffer:
            "Could not access decoded PCM samples"
        case let .decodedFrameCountMismatch(expected, actual):
            "Decoded frame count mismatch: expected \(expected), got \(actual)"
        }
    }
}

struct AudioSilenceDetector {
    static let silenceThresholdDB = -50.0
    static let minimumSilenceDuration: TimeInterval = 0.25

    private static let chunkFrameCapacity: AVAudioFrameCount = 16_384
    private static let threshold = Float(pow(10, silenceThresholdDB / 20))

    func boundaries(for file: AVAudioFile, shouldCancel: () -> Bool = { false }) throws -> AudioSilenceBoundaries {
        let length = file.length
        guard !shouldCancel() else { throw CancellationError() }
        let originalFramePosition = file.framePosition
        defer { file.framePosition = originalFramePosition }
        guard length > 0 else { return .full(length: length) }

        let format = file.processingFormat
        guard format.sampleRate.isFinite, format.sampleRate > 0 else {
            throw AudioSilenceDetectorError.invalidSampleRate(format.sampleRate)
        }
        guard format.channelCount > 0 else {
            throw AudioSilenceDetectorError.unsupportedChannelCount(format.channelCount)
        }
        let minimumSilenceFrameCount = Self.minimumSilenceDuration * format.sampleRate
        guard minimumSilenceFrameCount.isFinite, minimumSilenceFrameCount <= Double(AVAudioFramePosition.max) else {
            return .full(length: length)
        }
        let minimumSilenceFrames = max(Int64(1), Int64(ceil(minimumSilenceFrameCount)))
        let bufferCapacity = AVAudioFrameCount(min(Int64(Self.chunkFrameCapacity), length))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferCapacity) else {
            throw AudioSilenceDetectorError.invalidPCMBuffer
        }

        guard let firstNonSilentFrame = try firstNonSilentFrame(
            in: file,
            buffer: buffer,
            through: length,
            shouldCancel: shouldCancel
        ) else {
            return .full(length: length)
        }
        let startFrame = firstNonSilentFrame >= minimumSilenceFrames ? firstNonSilentFrame : 0

        guard let lastNonSilentFrame = try lastNonSilentFrame(
            in: file,
            buffer: buffer,
            startingAt: 0,
            shouldCancel: shouldCancel
        ) else {
            return .full(length: length)
        }
        let trailingSilenceFrames = length - lastNonSilentFrame - 1
        let endFrame = trailingSilenceFrames >= minimumSilenceFrames ? lastNonSilentFrame + 1 : length

        guard startFrame < endFrame else { return .full(length: length) }
        return AudioSilenceBoundaries(startFrame: startFrame, endFrame: endFrame)
    }

    private func firstNonSilentFrame(
        in file: AVAudioFile,
        buffer: AVAudioPCMBuffer,
        through endFrame: AVAudioFramePosition,
        shouldCancel: () -> Bool
    ) throws -> AVAudioFramePosition? {
        file.framePosition = 0
        var scanStartFrame: AVAudioFramePosition = 0
        while scanStartFrame < endFrame {
            guard !shouldCancel() else { throw CancellationError() }
            let requestedFrameCount = AVAudioFrameCount(min(Int64(Self.chunkFrameCapacity), endFrame - scanStartFrame))
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: requestedFrameCount)
            let frameCount = AVAudioFramePosition(buffer.frameLength)
            guard frameCount == AVAudioFramePosition(requestedFrameCount) else {
                throw AudioSilenceDetectorError.decodedFrameCountMismatch(
                    expected: AVAudioFramePosition(requestedFrameCount),
                    actual: frameCount
                )
            }
            if let frame = try nonSilentFrame(in: buffer, reversed: false) {
                return scanStartFrame + AVAudioFramePosition(frame)
            }
            scanStartFrame += frameCount
        }
        return nil
    }

    private func lastNonSilentFrame(
        in file: AVAudioFile,
        buffer: AVAudioPCMBuffer,
        startingAt startFrame: AVAudioFramePosition,
        shouldCancel: () -> Bool
    ) throws -> AVAudioFramePosition? {
        var scanEndFrame = file.length
        while scanEndFrame > startFrame {
            guard !shouldCancel() else { throw CancellationError() }
            let scanStartFrame = max(scanEndFrame - AVAudioFramePosition(Self.chunkFrameCapacity), startFrame)
            let requestedFrameCount = AVAudioFrameCount(scanEndFrame - scanStartFrame)
            file.framePosition = scanStartFrame
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: requestedFrameCount)
            let frameCount = AVAudioFramePosition(buffer.frameLength)
            guard frameCount == AVAudioFramePosition(requestedFrameCount) else {
                throw AudioSilenceDetectorError.decodedFrameCountMismatch(
                    expected: AVAudioFramePosition(requestedFrameCount),
                    actual: frameCount
                )
            }
            if let frame = try nonSilentFrame(in: buffer, reversed: true) {
                return scanStartFrame + AVAudioFramePosition(frame)
            }
            scanEndFrame = scanStartFrame
        }
        return nil
    }

    private func nonSilentFrame(in buffer: AVAudioPCMBuffer, reversed: Bool) throws -> Int? {
        guard let pcmReader = AudioPCMBufferReader(buffer: buffer) else {
            throw AudioSilenceDetectorError.invalidPCMBuffer
        }
        let frameCount = pcmReader.frameCount

        if reversed {
            for frame in stride(
                from: frameCount - 1,
                through: 0,
                by: -1
            ) where pcmReader.peak(at: frame) > Self.threshold {
                return frame
            }
        } else {
            for frame in 0..<frameCount where pcmReader.peak(at: frame) > Self.threshold {
                return frame
            }
        }
        return nil
    }
}
