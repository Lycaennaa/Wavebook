import Foundation

struct ReplayGainAlbumDecoder: Sendable {
    static let defaultConcurrency = 4
    static let maximumConcurrency = ReplayGain.maximumAnalysisFileConcurrency

    struct DecodedMeasurement: Sendable {
        let snapshot: LibEBUR128State.MeasurementSnapshot
        let samplePeak: Double
    }

    typealias Decode = @Sendable (URL) async throws -> DecodedMeasurement
    typealias ConcurrencyProvider = BoundedConcurrencyProvider

    private let concurrency: ConcurrencyProvider
    private let cancellationCheck: @Sendable () throws -> Void
    private let decode: Decode

    init(
        concurrency: Int = defaultConcurrency,
        cancellationCheck: @escaping @Sendable () throws -> Void,
        decode: @escaping Decode
    ) {
        let concurrency = min(max(concurrency, 1), Self.maximumConcurrency)
        self.concurrency = { concurrency }
        self.cancellationCheck = cancellationCheck
        self.decode = decode
    }

    init(
        maximumConcurrentCount: @escaping ConcurrencyProvider,
        cancellationCheck: @escaping @Sendable () throws -> Void,
        decode: @escaping Decode
    ) {
        self.concurrency = {
            min(max(maximumConcurrentCount(), 1), Self.maximumConcurrency)
        }
        self.cancellationCheck = cancellationCheck
        self.decode = decode
    }

    func measure(urls: [URL]) async throws -> ReplayGainMeasurement {
        let decoded = try await decode(urls: urls)
        return try Self.makeMeasurement(
            snapshots: decoded.map(\.snapshot),
            samplePeak: decoded.map(\.samplePeak).max() ?? 0
        )
    }

    func decode(urls: [URL]) async throws -> [DecodedMeasurement] {
        guard !urls.isEmpty else { throw ReplayGainAnalyzerError.emptyAudio }

        var decodedMeasurements = [DecodedMeasurement?](repeating: nil, count: urls.count)
        var firstFailure: (index: Int, error: Error)?
        let results = try await BoundedTaskRunner.runUntilFailure(
            items: Array(urls.indices),
            maximumConcurrentCount: concurrency,
            cancellationCheck: cancellationCheck,
            operation: { [self] index in
                try await decodeResult(url: urls[index])
            }
        )

        for (index, result) in results {
            switch result {
            case let .success(decoded):
                decodedMeasurements[index] = decoded
            case let .failure(error):
                if firstFailure.map({ $0.index > index }) ?? true {
                    firstFailure = (index, error)
                }
            }
        }

        if let firstFailure {
            throw firstFailure.error
        }

        try cancellationCheck()
        let orderedMeasurements = decodedMeasurements.compactMap(\.self)
        guard orderedMeasurements.count == urls.count else {
            throw ReplayGainAnalyzerError.decodedFrameCountMismatch(
                expected: Int64(urls.count),
                actual: Int64(orderedMeasurements.count)
            )
        }
        return orderedMeasurements
    }

    static func makeMeasurement(
        snapshots: [LibEBUR128State.MeasurementSnapshot],
        samplePeak: Double
    ) throws -> ReplayGainMeasurement {
        let integratedLUFS = LibEBUR128State.loudnessGlobalMultiple(snapshots: snapshots)
        guard integratedLUFS.isFinite else { throw ReplayGainAnalyzerError.undefinedLoudness }

        guard samplePeak.isFinite, samplePeak > 0 else { throw ReplayGainAnalyzerError.invalidSamplePeak }
        return ReplayGainMeasurement(integratedLUFS: integratedLUFS, samplePeak: samplePeak)
    }

    private func decodeResult(url: URL) async throws -> Result<DecodedMeasurement, Error> {
        do {
            return .success(try await decode(url))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(error)
        }
    }
}
