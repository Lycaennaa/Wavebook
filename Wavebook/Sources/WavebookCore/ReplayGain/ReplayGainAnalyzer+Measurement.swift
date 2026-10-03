import Foundation

extension ReplayGainAnalyzer {
    /// Measures integrated loudness and sample peak for an audio file.
    public func measure(url: URL) throws -> ReplayGainMeasurement {
        let decoded = try decodeState(url: url)
        return try measurement(state: decoded.state, channelCount: decoded.channelCount)
    }
    func measureWithSnapshot(
        url: URL
    ) throws -> (values: ReplayGainScopeValues, measurement: ReplayGainAlbumDecoder.DecodedMeasurement) {
        let decoded = try decodeState(url: url)
        let values = try measurement(state: decoded.state, channelCount: decoded.channelCount).values
        return (
            values: values,
            measurement: ReplayGainAlbumDecoder.DecodedMeasurement(
                snapshot: decoded.state.snapshot(),
                samplePeak: decoded.samplePeak
            )
        )
    }

    func decodedMeasurement(url: URL) throws -> ReplayGainAlbumDecoder.DecodedMeasurement {
        let decoded = try decodeState(url: url)
        return ReplayGainAlbumDecoder.DecodedMeasurement(
            snapshot: decoded.state.snapshot(),
            samplePeak: decoded.samplePeak
        )
    }

    /// Returns the sample peak for an audio file.
    public func samplePeak(url: URL) throws -> Double {
        let decoded = try decodeState(url: url)
        return decoded.samplePeak
    }

    /// Measures aggregate replay-gain values for an album.
    public func measureAlbum(urls: [URL]) throws -> ReplayGainMeasurement {
        try validateAlbumBounds(urls: urls)
        return try measureValidatedAlbum(urls: urls)
    }

    private func measureValidatedAlbum(urls: [URL]) throws -> ReplayGainMeasurement {
        var snapshots: [LibEBUR128State.MeasurementSnapshot] = []
        var samplePeak = 0.0
        for url in urls {
            let decoded = try decodeState(url: url)
            snapshots.append(decoded.state.snapshot())
            samplePeak = max(samplePeak, decoded.samplePeak)
        }

        try cancellationCheck()
        return try ReplayGainAlbumDecoder.makeMeasurement(snapshots: snapshots, samplePeak: samplePeak)
    }

    func measureValidatedAlbumConcurrently(
        urls: [URL],
        maximumConcurrentDecoding: @escaping BoundedConcurrencyProvider
    ) async throws -> ReplayGainMeasurement {
        let decoded = try await decodeValidatedAlbumConcurrently(
            urls: urls,
            maximumConcurrentDecoding: maximumConcurrentDecoding
        )
        return try ReplayGainAlbumDecoder.makeMeasurement(
            snapshots: decoded.map(\.snapshot),
            samplePeak: decoded.map(\.samplePeak).max() ?? 0
        )
    }

    func decodeValidatedAlbumConcurrently(
        urls: [URL],
        maximumConcurrentDecoding: @escaping BoundedConcurrencyProvider
    ) async throws -> [ReplayGainAlbumDecoder.DecodedMeasurement] {
        let decoder = ReplayGainAlbumDecoder(
            maximumConcurrentCount: maximumConcurrentDecoding,
            cancellationCheck: cancellationCheck,
            decode: { [self] url in
                let decoded = try decodeState(
                    url: url,
                    overrideChunkFrameCapacity: Self.maximumConcurrentChunkFrameCapacity
                )
                return ReplayGainAlbumDecoder.DecodedMeasurement(
                    snapshot: decoded.state.snapshot(),
                    samplePeak: decoded.samplePeak
                )
            }
        )
        return try await decoder.decode(urls: urls)
    }

    private func measurement(state: LibEBUR128State, channelCount: UInt32) throws -> ReplayGainMeasurement {
        try cancellationCheck()
        let integratedLUFS = state.loudnessGlobal()
        guard integratedLUFS.isFinite else { throw ReplayGainAnalyzerError.undefinedLoudness }
        return ReplayGainMeasurement(
            integratedLUFS: integratedLUFS,
            samplePeak: try maximumSamplePeak(state: state, channelCount: channelCount)
        )
    }

    func maximumSamplePeak(state: LibEBUR128State, channelCount: UInt32) throws -> Double {
        var maximum = 0.0
        for channel in 0..<channelCount {
            let peak = try callLibEBUR128("sample_peak") {
                try state.samplePeak(channelNumber: channel)
            }
            guard peak.isFinite, peak >= 0 else { throw ReplayGainAnalyzerError.invalidSamplePeak }
            maximum = max(maximum, peak)
        }
        guard maximum > 0 else { throw ReplayGainAnalyzerError.invalidSamplePeak }
        return maximum
    }
}
