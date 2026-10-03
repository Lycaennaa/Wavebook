@preconcurrency import AVFoundation
import Foundation

/// Measured replay-gain loudness and peak values.
public struct ReplayGainMeasurement: Equatable, Sendable {
    /// Integrated loudness in LUFS.
    public let integratedLUFS: Double
    /// Maximum sample peak.
    public let samplePeak: Double

    /// Creates a replay-gain measurement.
    public init(integratedLUFS: Double, samplePeak: Double) {
        self.integratedLUFS = integratedLUFS
        self.samplePeak = samplePeak
    }

    /// Converts measured values to normalized replay-gain scope values.
    public var values: ReplayGainScopeValues {
        ReplayGainScopeValues(
            gain: ReplayGain.measuredGainDB(integratedLUFS: integratedLUFS).map {
                ReplayGainGain(decibels: $0, source: .measured)
            },
            samplePeak: samplePeak
        )
    }
}

/// Outcome of a replay-gain analysis operation.
public enum ReplayGainAnalysisOutcome: Equatable, Sendable {
    /// No pending analysis item was available.
    case noPendingItem
    /// Analysis values were committed for a track.
    case committed(trackID: Int64, values: ReplayGainScopeValues)
    /// A stale analysis result was discarded.
    case discardedStale(trackID: Int64)
    /// Analysis failed for a track.
    case failed(trackID: Int64, reason: String)
}

/// Errors raised by replay-gain analysis.
public enum ReplayGainAnalyzerError: Error, Equatable, LocalizedError, Sendable {
    /// The source sample rate was invalid.
    case invalidSampleRate(Double)
    /// The source channel count was unsupported.
    case unsupportedChannelCount(UInt32)
    /// The source channel layout was unsupported.
    case unsupportedChannelLayout(UInt32)
    /// The source contained no audio.
    case emptyAudio
    /// Decoded frame count differed from the expected count.
    case decodedFrameCountMismatch(expected: Int64, actual: Int64)
    /// Decoded PCM samples were inaccessible.
    case invalidPCMBuffer
    /// libebur128 initialization failed.
    case libEBUR128InitializationFailed
    /// A libebur128 operation failed.
    case libEBUR128CallFailed(operation: String, code: Int32)
    /// Integrated loudness could not be calculated.
    case undefinedLoudness
    /// Sample peak could not be calculated.
    case invalidSamplePeak
    /// The album exceeded the track limit.
    case albumTrackLimitExceeded(Int)
    /// The album exceeded the duration limit.
    case albumDurationLimitExceeded(TimeInterval)
    /// Album gain tags disagreed.
    case conflictingAlbumGainValues
    /// Album peak tags disagreed.
    case conflictingAlbumPeakValues
}

/// An analyzer for bounded replay-gain measurements.
public struct ReplayGainAnalyzer: Sendable {
    /// Default decoded frame capacity per chunk.
    public static let defaultChunkFrameCapacity: AVAudioFrameCount = 16_384
    /// Maximum decoded frame capacity per chunk.
    public static let maximumChunkFrameCapacity: AVAudioFrameCount = 1_048_576
    // 64 KiB keeps 15 stereo 192 kHz decoders within a bounded transient working set.
    static let maximumConcurrentChunkFrameCapacity: AVAudioFrameCount = 65_536
    /// Maximum number of tracks in one album analysis.
    public static let maximumAlbumTrackCount = 500
    /// Maximum duration of one album analysis.
    public static let maximumAlbumDuration: TimeInterval = 48 * 60 * 60
    static let maximumTrackDuration: TimeInterval = 4 * 60 * 60
    static let maximumTrackFrameCount: Int64 = 1_000_000_000
    static let maximumTrackDecodedByteCount: Int64 = 4 * 1024 * 1024 * 1024

    let chunkFrameCapacity: AVAudioFrameCount
    let metadataReader: AudioMetadataReader
    let cancellationCheck: @Sendable () throws -> Void

    /// Creates an analyzer using the default bounded configuration.
    public init(chunkFrameCapacity: AVAudioFrameCount = defaultChunkFrameCapacity) {
        self.init(
            chunkFrameCapacity: chunkFrameCapacity,
            metadataReader: AudioMetadataReader(),
            cancellationCheck: { try Task.checkCancellation() }
        )
    }

    init(
        chunkFrameCapacity: AVAudioFrameCount,
        metadataReader: AudioMetadataReader = AudioMetadataReader(),
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) {
        self.chunkFrameCapacity = min(max(chunkFrameCapacity, 1), Self.maximumChunkFrameCapacity)
        self.metadataReader = metadataReader
        self.cancellationCheck = cancellationCheck
    }

    func constrainedForConcurrentDecoding() -> ReplayGainAnalyzer {
        guard chunkFrameCapacity > Self.maximumConcurrentChunkFrameCapacity else { return self }
        return ReplayGainAnalyzer(
            chunkFrameCapacity: Self.maximumConcurrentChunkFrameCapacity,
            metadataReader: metadataReader,
            cancellationCheck: cancellationCheck
        )
    }
}
