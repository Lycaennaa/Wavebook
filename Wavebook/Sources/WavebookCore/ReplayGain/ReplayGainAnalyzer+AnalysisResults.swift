import Foundation

extension ReplayGainAnalyzer {
    func albumValues(urls: [URL]) async throws -> ReplayGainScopeValues {
        try await albumValues(tagURLs: urls, measurementURLs: urls)
    }

    /// Measures aggregate replay-gain values for an album.
    public func albumValues(
        tagURLs: [URL],
        measurementURLs: [URL],
        maximumConcurrentDecoding: Int
    ) async throws -> ReplayGainScopeValues {
        try await albumValues(
            tagURLs: tagURLs,
            measurementURLs: measurementURLs,
            maximumConcurrentDecoding: { maximumConcurrentDecoding }
        )
    }

    func albumValues(
        tagURLs: [URL],
        measurementURLs: [URL],
        maximumConcurrentDecoding: @escaping BoundedConcurrencyProvider = { ReplayGainAlbumDecoder.defaultConcurrency },
        cachedMeasurements: [ReplayGainCachedMeasurement] = []
    ) async throws -> ReplayGainScopeValues {
        guard tagURLs.count <= Self.maximumAlbumTrackCount else {
            throw ReplayGainAnalyzerError.albumTrackLimitExceeded(tagURLs.count)
        }
        guard measurementURLs.count <= Self.maximumAlbumTrackCount else {
            throw ReplayGainAnalyzerError.albumTrackLimitExceeded(measurementURLs.count)
        }
        let measurementPaths = Set(measurementURLs.map(\.standardizedFileURL.path))
        let tagged = try await collectTaggedAlbumValues(
            tagURLs: tagURLs,
            measurementPaths: measurementPaths,
            maximumConcurrentDecoding: maximumConcurrentDecoding
        )
        if tagged.isReady { return tagged }
        guard !measurementURLs.isEmpty else {
            throw ReplayGainAnalyzerError.emptyAudio
        }
        try validateAlbumBounds(urls: measurementURLs)
        let cachedByPath = Dictionary(
            cachedMeasurements.map { ($0.path, $0.measurement) },
            uniquingKeysWith: { first, _ in first }
        )
        let uncachedURLs = measurementURLs.filter {
            cachedByPath[$0.standardizedFileURL.path] == nil
        }
        let uncachedMeasurements = uncachedURLs.isEmpty
            ? []
            : try await decodeValidatedAlbumConcurrently(
                urls: uncachedURLs,
                maximumConcurrentDecoding: maximumConcurrentDecoding
            )
        var uncachedIndex = 0
        var decodedMeasurements: [ReplayGainAlbumDecoder.DecodedMeasurement] = []
        decodedMeasurements.reserveCapacity(measurementURLs.count)
        for url in measurementURLs {
            if let cached = cachedByPath[url.standardizedFileURL.path] {
                decodedMeasurements.append(cached)
            } else {
                decodedMeasurements.append(uncachedMeasurements[uncachedIndex])
                uncachedIndex += 1
            }
        }
        let measured = try ReplayGainAlbumDecoder.makeMeasurement(
            snapshots: decodedMeasurements.map(\.snapshot),
            samplePeak: decodedMeasurements.map(\.samplePeak).max() ?? 0
        )
        return tagged.fillingMissing(from: measured.values)
    }

    private func collectTaggedAlbumValues(
        tagURLs: [URL],
        measurementPaths: Set<String>,
        maximumConcurrentDecoding: @escaping BoundedConcurrencyProvider
    ) async throws -> ReplayGainScopeValues {
        let tagResults = try await readAlbumTagResults(
            tagURLs: tagURLs,
            maximumConcurrentDecoding: maximumConcurrentDecoding
        )
        var replayGain: ReplayGainGain?
        var r128: ReplayGainGain?
        var samplePeak: Double?
        for (index, result) in tagResults.sorted(by: { $0.0 < $1.0 }) {
            try cancellationCheck()
            let tags: ReplayGainScopeValues?
            switch result {
            case let .success(values):
                tags = values
            case let .failure(error):
                guard !measurementPaths.contains(tagURLs[index].standardizedFileURL.path) else {
                    throw error
                }
                continue
            }
            guard let tags else { continue }
            try mergeAlbumTag(
                tags,
                replayGain: &replayGain,
                r128: &r128,
                samplePeak: &samplePeak
            )
        }
        return ReplayGainScopeValues(gain: replayGain ?? r128, samplePeak: samplePeak)
    }

    private func mergeAlbumTag(
        _ tags: ReplayGainScopeValues,
        replayGain: inout ReplayGainGain?,
        r128: inout ReplayGainGain?,
        samplePeak: inout Double?
    ) throws {
        if let gain = tags.gain {
            switch gain.source {
            case .replayGain:
                guard replayGain == nil || replayGain == gain else {
                    throw ReplayGainAnalyzerError.conflictingAlbumGainValues
                }
                replayGain = gain
            case .r128:
                guard r128 == nil || r128 == gain else {
                    throw ReplayGainAnalyzerError.conflictingAlbumGainValues
                }
                r128 = gain
            case .measured:
                break
            }
        }
        if let peak = tags.samplePeak {
            guard samplePeak == nil || samplePeak == peak else {
                throw ReplayGainAnalyzerError.conflictingAlbumPeakValues
            }
            samplePeak = peak
        }
    }

    private func readAlbumTagResults(
        tagURLs: [URL],
        maximumConcurrentDecoding: @escaping BoundedConcurrencyProvider
    ) async throws -> [(Int, Result<ReplayGainScopeValues?, Error>)] {
        let maximumConcurrentMetadataReads: BoundedConcurrencyProvider = {
            min(max(maximumConcurrentDecoding(), 1), ReplayGainAlbumDecoder.maximumConcurrency)
        }
        return try await BoundedTaskRunner.run(
            items: Array(tagURLs.indices),
            maximumConcurrentCount: maximumConcurrentMetadataReads(),
            cancellationCheck: cancellationCheck,
            operation: { [self] index in
                try cancellationCheck()
                do {
                    let tags = try await metadataReader.replayGainTags(for: tagURLs[index]).album
                    return (index, Result<ReplayGainScopeValues?, Error>.success(tags))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return (index, Result<ReplayGainScopeValues?, Error>.failure(error))
                }
            }
        )
    }
    enum ReplayGainTrackAnalysisResult: Sendable {
        case committed(trackID: Int64, values: ReplayGainScopeValues)
        case measured(
            trackID: Int64,
            values: ReplayGainScopeValues,
            measurement: ReplayGainAlbumDecoder.DecodedMeasurement
        )
        case discardedStale(trackID: Int64)
        case failed(trackID: Int64, reason: String)

        var outcome: ReplayGainAnalysisOutcome {
            switch self {
            case let .committed(trackID, values), let .measured(trackID, values, _):
                return .committed(trackID: trackID, values: values)
            case let .discardedStale(trackID):
                return .discardedStale(trackID: trackID)
            case let .failed(trackID, reason):
                return .failed(trackID: trackID, reason: reason)
            }
        }

        var measurement: ReplayGainAlbumDecoder.DecodedMeasurement? {
            guard case let .measured(_, _, measurement) = self else { return nil }
            return measurement
        }
    }

    struct ReplayGainCachedMeasurement: Sendable {
        let path: String
        let fingerprint: ReplayGainFileFingerprint
        let measurement: ReplayGainAlbumDecoder.DecodedMeasurement

        init(
            path: String,
            fingerprint: ReplayGainFileFingerprint,
            measurement: ReplayGainAlbumDecoder.DecodedMeasurement
        ) {
            self.path = URL(fileURLWithPath: path).standardizedFileURL.path
            self.fingerprint = fingerprint
            self.measurement = measurement
        }
    }
    private struct TrackValuesResult {
        let values: ReplayGainScopeValues
        let measurement: ReplayGainAlbumDecoder.DecodedMeasurement?
    }
    /// Analyzes the next pending replay-gain track.
    public func analyzeNextPendingItem(in database: LibraryDatabase) async throws -> ReplayGainAnalysisOutcome {
        guard let item = try database.claimNextPendingReplayGainItem() else { return .noPendingItem }
        return try await analyzeClaimedItem(item, in: database)
    }

    func analyzeClaimedItem(
        _ item: ReplayGainPendingItem,
        in database: LibraryDatabase
    ) async throws -> ReplayGainAnalysisOutcome {
        try await analyzeClaimedItemWithMeasurement(item, in: database).outcome
    }

    func analyzeClaimedItemWithMeasurement(
        _ item: ReplayGainPendingItem,
        in database: LibraryDatabase
    ) async throws -> ReplayGainTrackAnalysisResult {
        do {
            return try await commitClaimedItem(item, in: database)
        } catch is CancellationError {
            _ = try database.releaseReplayGainClaim(
                trackID: item.trackID,
                fingerprint: item.fingerprint,
                claimToken: item.claimToken
            )
            throw CancellationError()
        } catch {
            return try handleClaimedItemFailure(item, in: database, error: error)
        }
    }

    private func commitClaimedItem(
        _ item: ReplayGainPendingItem,
        in database: LibraryDatabase
    ) async throws -> ReplayGainTrackAnalysisResult {
        try cancellationCheck()
        let trackValues = try await trackValues(for: item)
        try cancellationCheck()

        let precommitFingerprint = try currentFingerprint(for: item.path)
        guard fingerprintsMatch(precommitFingerprint, item.fingerprint) else {
            _ = try database.invalidateReplayGainForFileChange(
                trackID: item.trackID,
                expectedFingerprint: item.fingerprint,
                currentFingerprint: precommitFingerprint,
                claimToken: item.claimToken
            )
            return .discardedStale(trackID: item.trackID)
        }

        let committed = try database.commitReplayGainTrackResult(
            request: LibraryDatabase.TrackCommitInput(
                trackID: item.trackID,
                fingerprint: item.fingerprint,
                claimToken: item.claimToken,
                values: trackValues.values,
                analyzerVersion: ReplayGain.analyzerVersion,
                tagSchemaVersion: ReplayGain.tagSchemaVersion,
                currentFingerprint: precommitFingerprint
            )
        )
        guard committed else {
            return .discardedStale(trackID: item.trackID)
        }
        let finalFingerprint = ReplayGainFileFingerprint.currentIgnoringCancellation(path: item.path)
        guard fingerprintsMatch(finalFingerprint, item.fingerprint) else {
            _ = try database.invalidateReplayGainForFileChange(
                trackID: item.trackID,
                expectedFingerprint: item.fingerprint,
                currentFingerprint: finalFingerprint,
                claimToken: nil,
                ignoringCancellation: true
            )
            try cancellationCheck()
            return .discardedStale(trackID: item.trackID)
        }
        try cancellationCheck()
        if let measurement = trackValues.measurement {
            return .measured(
                trackID: item.trackID,
                values: trackValues.values,
                measurement: measurement
            )
        }
        return .committed(trackID: item.trackID, values: trackValues.values)
    }

    private func handleClaimedItemFailure(
        _ item: ReplayGainPendingItem,
        in database: LibraryDatabase,
        error: Error
    ) throws -> ReplayGainTrackAnalysisResult {
        let failureFingerprint = try currentFingerprint(for: item.path)
        guard fingerprintsMatch(failureFingerprint, item.fingerprint) else {
            _ = try database.invalidateReplayGainForFileChange(
                trackID: item.trackID,
                expectedFingerprint: item.fingerprint,
                currentFingerprint: failureFingerprint,
                claimToken: item.claimToken
            )
            return .discardedStale(trackID: item.trackID)
        }
        let reason = failureReason(for: error)
        let recorded = try database.recordReplayGainFailure(
            request: LibraryDatabase.TrackFailureRequest(
                trackID: item.trackID,
                fingerprint: item.fingerprint,
                currentFingerprint: failureFingerprint,
                claimToken: item.claimToken,
                reason: String(reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)),
                timestamp: Date(),
                analyzerVersion: ReplayGain.analyzerVersion,
                tagSchemaVersion: ReplayGain.tagSchemaVersion,
                path: item.path
            )
        )
        return recorded
            ? .failed(trackID: item.trackID, reason: reason)
            : .discardedStale(trackID: item.trackID)
    }

    private func trackValues(for item: ReplayGainPendingItem) async throws -> TrackValuesResult {
        if let cached = item.cachedTrackValues, cached.isReady {
            return TrackValuesResult(values: cached, measurement: nil)
        }
        let url = URL(fileURLWithPath: item.path)
        let taggedValues = try await metadataReader.replayGainTags(for: url).track
        let authoritativeValues: ReplayGainScopeValues?
        if let cached = item.cachedTrackValues, let taggedValues {
            authoritativeValues = cached.fillingMissing(from: taggedValues)
        } else {
            authoritativeValues = item.cachedTrackValues ?? taggedValues
        }
        if let authoritativeValues, authoritativeValues.isReady {
            return TrackValuesResult(values: authoritativeValues, measurement: nil)
        }

        if let authoritativeValues, authoritativeValues.gain != nil {
            let decoded = try decodedMeasurement(url: url)
            return TrackValuesResult(
                values: authoritativeValues.fillingMissing(
                    from: ReplayGainScopeValues(samplePeak: decoded.samplePeak)
                ),
                measurement: decoded
            )
        }

        let measured = try measureWithSnapshot(url: url)
        return TrackValuesResult(
            values: authoritativeValues?.fillingMissing(from: measured.values) ?? measured.values,
            measurement: measured.measurement
        )
    }
    private func currentFingerprint(for path: String) throws -> ReplayGainFileFingerprint {
        let fingerprint = ReplayGainFileFingerprint.current(path: path)
        try Task.checkCancellation()
        return fingerprint
    }

    private func fingerprintsMatch(_ current: ReplayGainFileFingerprint, _ claimed: ReplayGainFileFingerprint) -> Bool {
        ReplayGainFileFingerprint.matches(current, claimed)
    }

}
