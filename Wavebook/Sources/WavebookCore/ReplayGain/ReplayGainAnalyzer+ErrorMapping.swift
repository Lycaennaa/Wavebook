import Foundation

extension ReplayGainAnalyzerError {
    /// Human-readable analyzer error text.
    public var errorDescription: String? {
        switch self {
        case let .invalidSampleRate(sampleRate):
            "Invalid sample rate: \(sampleRate)"
        case let .unsupportedChannelCount(channelCount):
            "Unsupported channel count: \(channelCount)"
        case let .unsupportedChannelLayout(layoutTag):
            "Unsupported channel layout: \(layoutTag)"
        case .emptyAudio:
            "Audio file contains no decoded frames"
        case let .decodedFrameCountMismatch(expected, actual):
            "Decoded frame count mismatch: expected \(expected), got \(actual)"
        case .invalidPCMBuffer:
            "Could not access decoded PCM samples"
        case .libEBUR128InitializationFailed:
            "libebur128 could not initialize"
        case let .libEBUR128CallFailed(operation, code):
            "libebur128 \(operation) failed with code \(code)"
        case .undefinedLoudness:
            "Integrated loudness is undefined"
        case .invalidSamplePeak:
            "Sample peak is undefined"
        case let .albumTrackLimitExceeded(count):
            "Album group exceeds 500 tracks: \(count)"
        case let .albumDurationLimitExceeded(duration):
            "Album group exceeds 48 hours: \(duration) seconds"
        case .conflictingAlbumGainValues:
            "Album group contains conflicting gain tags"
        case .conflictingAlbumPeakValues:
            "Album group contains conflicting peak tags"
        }
    }
}

extension ReplayGainAnalyzer {
    // Preserve the existing public error codes at the analyzer boundary.
    func callLibEBUR128<T>(_ operation: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch LibEBUR128StateError.invalidChannelIndex {
            throw ReplayGainAnalyzerError.libEBUR128CallFailed(operation: operation, code: 3)
        } catch LibEBUR128StateError.invalidInput {
            throw ReplayGainAnalyzerError.libEBUR128CallFailed(operation: operation, code: 2)
        } catch {
            throw error
        }
    }

    func failureReason(for error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
