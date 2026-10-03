import AVFoundation
import Foundation

@MainActor
enum AudioPlaybackTransitionBuilder {
    private enum TransitionError: Error {
        case unsupportedFormat
        case incompleteRead
    }

    private final class ConverterInput: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var wasProvided = false

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    static func makeBuffers(
        for schedule: AudioPlaybackSchedule,
        url: URL,
        format: AVAudioFormat,
        outputFormat: AVAudioFormat
    ) throws -> [AudioPlaybackRange: AVAudioPCMBuffer] {
        let file = try AVAudioFile(forReading: url)
        var buffers = [AudioPlaybackRange: AVAudioPCMBuffer]()
        for (index, scheduledRange) in schedule.scheduledRanges.enumerated() {
            let frameCount = scheduledRange.trailingTransitionFrameCount
            guard frameCount > 0 else { continue }
            guard frameCount <= AVAudioFramePosition(UInt32.max) else {
                throw TransitionError.incompleteRead
            }
            let count = AVAudioFrameCount(frameCount)
            let range = scheduledRange.source
            let nextRange = schedule.scheduledRanges[index + 1].source
            let tail = try readBuffer(
                from: file,
                at: range.endFrame - frameCount,
                frameCount: count,
                format: format
            )
            let head = try readBuffer(
                from: file,
                at: nextRange.startFrame,
                frameCount: count,
                format: format
            )
            buffers[scheduledRange.source] = try makeCrossfadeBuffer(
                tail: tail,
                head: head,
                frameCount: count,
                outputFormat: outputFormat
            )
        }
        return buffers
    }

    private static func readBuffer(
        from file: AVAudioFile,
        at startFrame: AVAudioFramePosition,
        frameCount: AVAudioFrameCount,
        format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw TransitionError.unsupportedFormat
        }
        file.framePosition = startFrame
        try file.read(into: buffer, frameCount: frameCount)
        guard buffer.frameLength == frameCount else { throw TransitionError.incompleteRead }
        return buffer
    }

    private static func makeCrossfadeBuffer(
        tail: AVAudioPCMBuffer,
        head: AVAudioPCMBuffer,
        frameCount: AVAudioFrameCount,
        outputFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard tail.format == head.format,
              let buffer = AVAudioPCMBuffer(pcmFormat: tail.format, frameCapacity: frameCount),
              let output = buffer.floatChannelData,
              let tailData = tail.floatChannelData,
              let headData = head.floatChannelData else {
            throw TransitionError.unsupportedFormat
        }
        buffer.frameLength = frameCount
        let channels = Int(tail.format.channelCount)
        let stride = max(buffer.stride, 1)
        let frameTotal = Int(frameCount)
        for frame in 0..<frameTotal {
            let progress = frameTotal > 1
                ? Double(frame) / Double(frameTotal - 1)
                : 1
            let tailGain = Float(cos(progress * Double.pi / 2))
            let headGain = Float(sin(progress * Double.pi / 2))
            if tail.format.isInterleaved {
                for channel in 0..<channels {
                    let sampleIndex = frame * stride + channel
                    output[0][sampleIndex] = tailData[0][sampleIndex] * tailGain
                        + headData[0][sampleIndex] * headGain
                }
            } else {
                for channel in 0..<channels {
                    output[channel][frame] = tailData[channel][frame] * tailGain
                        + headData[channel][frame] * headGain
                }
            }
        }
        guard outputFormat.sampleRate.isFinite,
              outputFormat.sampleRate > 0,
              outputFormat.channelCount > 0 else {
            throw TransitionError.unsupportedFormat
        }
        guard buffer.format.sampleRate == outputFormat.sampleRate,
              buffer.format.channelCount == outputFormat.channelCount,
              buffer.format.commonFormat == outputFormat.commonFormat,
              buffer.format.isInterleaved == outputFormat.isInterleaved else {
            return try convertedBuffer(buffer, to: outputFormat)
        }
        return buffer
    }

    private static func convertedBuffer(
        _ input: AVAudioPCMBuffer,
        to format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard input.format.sampleRate.isFinite,
              input.format.sampleRate > 0,
              format.sampleRate.isFinite,
              format.sampleRate > 0,
              format.channelCount > 0 else {
            throw TransitionError.unsupportedFormat
        }
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = ceil(Double(input.frameLength) * ratio) + 1
        guard ratio.isFinite,
              ratio > 0,
              capacity <= Double(UInt32.max),
              let output = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(capacity)
              ),
              let converter = AVAudioConverter(from: input.format, to: format) else {
            throw TransitionError.unsupportedFormat
        }
        let inputState = ConverterInput(buffer: input)
        var conversionError: NSError?
        _ = converter.convert(to: output, error: &conversionError) { _, status in
            guard !inputState.wasProvided else {
                status.pointee = .endOfStream
                return nil
            }
            inputState.wasProvided = true
            status.pointee = .haveData
            return inputState.buffer
        }
        if let conversionError { throw conversionError }
        guard output.frameLength > 0 else { throw TransitionError.incompleteRead }
        return output
    }
}
