import AudioToolbox
@preconcurrency import AVFoundation
import Foundation

enum ReplayGainAnalysisLimitError: Error, Equatable, LocalizedError, Sendable {
    case durationExceeded(TimeInterval)
    case frameCountExceeded(Int64)
    case decodedByteCountExceeded(Int64)
    case decodedByteCountOverflow

    var errorDescription: String? {
        switch self {
        case let .durationExceeded(duration):
            "Track exceeds maximum analysis duration: \(duration) seconds"
        case let .frameCountExceeded(frameCount):
            "Track exceeds maximum analysis frame count: \(frameCount)"
        case let .decodedByteCountExceeded(byteCount):
            "Track exceeds maximum decoded byte count: \(byteCount)"
        case .decodedByteCountOverflow:
            "Track decoded byte count overflowed"
        }
    }
}

private struct DecodeFrameContext {
    let file: AVAudioFile
    let buffer: AVAudioPCMBuffer
    let state: LibEBUR128State
    let expectedFrameCount: Int64
    let chunkFrameCapacity: AVAudioFrameCount
    let sampleRate: Double
    let channelCount: UInt32
    var interleavedSamples: [Float]?
}

extension ReplayGainAnalyzer {
    func decodeState(
        url: URL,
        overrideChunkFrameCapacity: AVAudioFrameCount? = nil
    ) throws -> DecodedState {
        let chunkFrameCapacity = min(
            self.chunkFrameCapacity,
            overrideChunkFrameCapacity ?? self.chunkFrameCapacity
        )
        var context = try makeDecodeFrameContext(url: url, chunkFrameCapacity: chunkFrameCapacity)
        let decodedFrameCount = try decodeFrames(context: &context)
        guard decodedFrameCount == context.expectedFrameCount else {
            throw ReplayGainAnalyzerError.decodedFrameCountMismatch(
                expected: context.expectedFrameCount,
                actual: decodedFrameCount
            )
        }
        try cancellationCheck()
        let samplePeak = try maximumSamplePeak(state: context.state, channelCount: context.channelCount)
        return DecodedState(state: context.state, channelCount: context.channelCount, samplePeak: samplePeak)
    }

    private func makeDecodeFrameContext(
        url: URL,
        chunkFrameCapacity: AVAudioFrameCount
    ) throws -> DecodeFrameContext {
        try cancellationCheck()
        let file = try audioFile(for: url)
        let format = file.processingFormat
        let channelCount = format.channelCount
        let expectedFrameCount = file.length
        try validateTrackBounds(
            frameCount: expectedFrameCount,
            sampleRate: format.sampleRate,
            channelCount: channelCount
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrameCapacity) else {
            throw ReplayGainAnalyzerError.invalidPCMBuffer
        }
        let interleavedSamples = channelCount == 1
            ? nil
            : [Float](repeating: 0, count: Int(chunkFrameCapacity) * Int(channelCount))
        let state: LibEBUR128State
        do {
            state = try LibEBUR128State(channelCount: channelCount, sampleRate: UInt(format.sampleRate))
        } catch {
            throw ReplayGainAnalyzerError.libEBUR128InitializationFailed
        }
        return DecodeFrameContext(
            file: file,
            buffer: buffer,
            state: state,
            expectedFrameCount: expectedFrameCount,
            chunkFrameCapacity: chunkFrameCapacity,
            sampleRate: format.sampleRate,
            channelCount: channelCount,
            interleavedSamples: interleavedSamples
        )
    }

    private func decodeFrames(context: inout DecodeFrameContext) throws -> Int64 {
        var decodedFrameCount: Int64 = 0
        while decodedFrameCount < context.expectedFrameCount {
            decodedFrameCount = try decodeFrame(
                context: &context,
                decodedFrameCount: decodedFrameCount
            )
        }
        return decodedFrameCount
    }

    private func decodeFrame(
        context: inout DecodeFrameContext,
        decodedFrameCount: Int64
    ) throws -> Int64 {
        try cancellationCheck()
        context.buffer.frameLength = 0
        let remainingFrames = context.expectedFrameCount - decodedFrameCount
        let requestedFrames = AVAudioFrameCount(
            min(Int64(context.chunkFrameCapacity), remainingFrames)
        )
        try context.file.read(into: context.buffer, frameCount: requestedFrames)
        let frameCount = context.buffer.frameLength
        guard frameCount > 0 else {
            throw ReplayGainAnalyzerError.decodedFrameCountMismatch(
                expected: context.expectedFrameCount,
                actual: decodedFrameCount
            )
        }
        let (nextFrameCount, overflow) = decodedFrameCount.addingReportingOverflow(Int64(frameCount))
        guard !overflow else {
            throw ReplayGainAnalysisLimitError.frameCountExceeded(Int64.max)
        }
        guard nextFrameCount <= context.expectedFrameCount else {
            throw ReplayGainAnalyzerError.decodedFrameCountMismatch(
                expected: context.expectedFrameCount,
                actual: nextFrameCount
            )
        }
        try validateTrackBounds(
            frameCount: nextFrameCount,
            sampleRate: context.sampleRate,
            channelCount: context.channelCount
        )
        try processDecodedBuffer(
            context.buffer,
            state: context.state,
            frameCount: frameCount,
            channelCount: context.channelCount,
            interleavedSamples: &context.interleavedSamples
        )
        return nextFrameCount
    }

    private func processDecodedBuffer(
        _ buffer: AVAudioPCMBuffer,
        state: LibEBUR128State,
        frameCount: AVAudioFrameCount,
        channelCount: UInt32,
        interleavedSamples: inout [Float]?
    ) throws {
        guard let channelData = buffer.floatChannelData else {
            throw ReplayGainAnalyzerError.invalidPCMBuffer
        }
        if channelCount == 1 {
            let samples = UnsafeBufferPointer(start: channelData[0], count: Int(frameCount))
            try callLibEBUR128("add_frames_float") {
                try state.addFramesFloat(samples, frameCount: Int(frameCount))
            }
            return
        }
        let frameCount = Int(frameCount)
        let channelCount = Int(channelCount)
        guard var interleavedSamples else {
            throw ReplayGainAnalyzerError.invalidPCMBuffer
        }
        interleavedSamples.withUnsafeMutableBufferPointer { samples in
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    samples[frame * channelCount + channel] = channelData[channel][frame]
                }
            }
        }
        try interleavedSamples.withUnsafeBufferPointer { samples in
            try callLibEBUR128("add_frames_float") {
                try state.addFramesFloat(samples, frameCount: frameCount)
            }
        }
    }

    private func audioFile(for url: URL) throws -> AVAudioFile {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.sampleRate <= Double(UInt.max) else {
            throw ReplayGainAnalyzerError.invalidSampleRate(format.sampleRate)
        }
        guard 1...2 ~= format.channelCount else {
            throw ReplayGainAnalyzerError.unsupportedChannelCount(format.channelCount)
        }
        try validateChannelLayout(
            channelCount: format.channelCount,
            layoutTag: file.fileFormat.channelLayout?.layoutTag
        )
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw ReplayGainAnalyzerError.invalidPCMBuffer
        }
        return file
    }

    func validateChannelLayout(channelCount: UInt32, layoutTag: AudioChannelLayoutTag?) throws {
        guard let layoutTag else { return }
        let expectedTag = channelCount == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        guard layoutTag == expectedTag else {
            throw ReplayGainAnalyzerError.unsupportedChannelLayout(layoutTag)
        }
    }

    func validateTrackBounds(
        frameCount: Int64,
        sampleRate: Double,
        channelCount: UInt32
    ) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw ReplayGainAnalyzerError.invalidSampleRate(sampleRate)
        }
        guard frameCount > 0 else { throw ReplayGainAnalyzerError.emptyAudio }
        guard frameCount <= Self.maximumTrackFrameCount else {
            throw ReplayGainAnalysisLimitError.frameCountExceeded(frameCount)
        }

        let duration = Double(frameCount) / sampleRate
        guard duration.isFinite, duration <= Self.maximumTrackDuration else {
            throw ReplayGainAnalysisLimitError.durationExceeded(duration)
        }

        guard let decodedByteCount = decodedByteCount(frameCount: frameCount, channelCount: channelCount) else {
            throw ReplayGainAnalysisLimitError.decodedByteCountOverflow
        }
        guard decodedByteCount <= Self.maximumTrackDecodedByteCount else {
            throw ReplayGainAnalysisLimitError.decodedByteCountExceeded(decodedByteCount)
        }
    }

    private func decodedByteCount(frameCount: Int64, channelCount: UInt32) -> Int64? {
        let (bytesPerFrame, bytesPerFrameOverflow) = Int64(channelCount).multipliedReportingOverflow(
            by: Int64(MemoryLayout<Float>.stride)
        )
        guard !bytesPerFrameOverflow else { return nil }
        let (decodedByteCount, overflow) = frameCount.multipliedReportingOverflow(by: bytesPerFrame)
        return overflow ? nil : decodedByteCount
    }

    func validateAlbumBounds(urls: [URL]) throws {
        guard urls.count <= Self.maximumAlbumTrackCount else {
            throw ReplayGainAnalyzerError.albumTrackLimitExceeded(urls.count)
        }
        guard !urls.isEmpty else { throw ReplayGainAnalyzerError.emptyAudio }

        var duration: TimeInterval = 0
        for url in urls {
            try cancellationCheck()
            let file = try audioFile(for: url)
            duration += Double(file.length) / file.processingFormat.sampleRate
            guard duration <= Self.maximumAlbumDuration else {
                throw ReplayGainAnalyzerError.albumDurationLimitExceeded(duration)
            }
        }
    }

    struct DecodedState {
        let state: LibEBUR128State
        let channelCount: UInt32
        let samplePeak: Double
    }
}
