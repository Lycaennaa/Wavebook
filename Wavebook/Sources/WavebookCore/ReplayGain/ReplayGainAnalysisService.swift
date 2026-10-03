import Foundation

/// Current replay-gain analysis service status.
public struct ReplayGainAnalysisServiceStatus: Equatable, Sendable {
    /// Counts of items by analysis state.
    public let counts: ReplayGainAnalysisStatusCounts
    /// Paths currently being analyzed.
    public let currentPaths: [String]
    /// Whether the service has active analysis work.
    public var isRunning: Bool { stage != .idle }
    /// Current service error reason, if any.
    public let serviceErrorReason: String?
    /// Maximum number of files analyzed concurrently.
    public let maximumConcurrentFileCount: Int
    /// Current analysis phase.
    public let stage: ReplayGainAnalysisStage
    /// Track and album completion progress.
    public let progress: ReplayGainAnalysisProgress

    /// First path currently being analyzed, if any.
    public var currentPath: String? {
        currentPaths.first
    }

    /// Creates an analysis service status value.
    public init(
        counts: ReplayGainAnalysisStatusCounts,
        currentPaths: [String],
        serviceErrorReason: String? = nil,
        maximumConcurrentFileCount: Int,
        stage: ReplayGainAnalysisStage = .idle,
        progress: ReplayGainAnalysisProgress = ReplayGainAnalysisProgress()
    ) {
        self.counts = counts
        self.currentPaths = currentPaths
        self.serviceErrorReason = serviceErrorReason
        self.maximumConcurrentFileCount = maximumConcurrentFileCount
        self.stage = stage
        self.progress = progress
    }

    /// Compatibility initializer for callers that still provide a running flag.
    public init(
        counts: ReplayGainAnalysisStatusCounts,
        currentPaths: [String],
        isRunning: Bool,
        serviceErrorReason: String?,
        maximumConcurrentFileCount: Int,
        stage: ReplayGainAnalysisStage = .idle,
        progress: ReplayGainAnalysisProgress = ReplayGainAnalysisProgress()
    ) {
        self.init(
            counts: counts,
            currentPaths: currentPaths,
            serviceErrorReason: serviceErrorReason,
            maximumConcurrentFileCount: maximumConcurrentFileCount,
            stage: isRunning && stage == .idle ? .recovering : (isRunning ? stage : .idle),
            progress: progress
        )
    }
}

/// Coordinates background replay-gain analysis.
public actor ReplayGainAnalysisService {
    typealias AnalyzeTrack = @Sendable (
        ReplayGainPendingItem,
        LibraryDatabase
    ) async throws -> ReplayGainAnalyzer.ReplayGainTrackAnalysisResult
    typealias AnalyzeAlbum = @Sendable (
        ReplayGainAlbumAnalysisItem,
        BoundedConcurrencyProvider
    ) async throws -> ReplayGainScopeValues
    typealias ReleaseClaim = @Sendable (ReplayGainPendingItem) throws -> Bool
    typealias RecoverClaim = @Sendable (ReplayGainPendingItem) throws -> Bool

    private let database: LibraryDatabase
    private let analyzeTrack: AnalyzeTrack
    private let analyzeAlbum: AnalyzeAlbum
    private let concurrencyLimit: BoundedConcurrencyLimit
    private let measurementCache: ReplayGainMeasurementCache
    private let releaseClaim: ReleaseClaim
    private let recoverClaim: RecoverClaim
    private var worker: Task<Void, Never>?
    private var workerID: UUID?
    private var controlOperationID: UUID?
    private var currentPaths = Set<String>()
    private var serviceErrorReason: String?
    private var stage: ReplayGainAnalysisStage = .idle
    private var activeBatchStartedClaims = Set<String>()
    private var claimsAwaitingRecovery: [String: ReplayGainPendingItem] = [:]
    private static let claimCleanupAttemptCount = 3
    private static let maximumClaimsAwaitingRecovery = ReplayGain.maximumAnalysisFileConcurrency
    private let workerIdleHandler: (@Sendable () async -> Void)?
    private var workGeneration: UInt64 = 0
    private var maximumConcurrentFileCountRevision: UInt64 = 0

    /// Creates an analysis service with the default analyzer.
    public init(
        database: LibraryDatabase,
        analyzer: ReplayGainAnalyzer = ReplayGainAnalyzer(),
        maximumConcurrentFileCount: Int = ReplayGain.defaultAnalysisFileConcurrency
    ) {
        self.database = database
        self.workerIdleHandler = nil
        let clampedConcurrency = ReplayGain.clampedAnalysisFileConcurrency(maximumConcurrentFileCount)
        let concurrencyLimit = BoundedConcurrencyLimit(clampedConcurrency)
        self.concurrencyLimit = concurrencyLimit
        let concurrentAnalyzer = analyzer.constrainedForConcurrentDecoding()
        let measurementCache = ReplayGainMeasurementCache()
        self.measurementCache = measurementCache
        analyzeTrack = { item, database in
            try await concurrentAnalyzer.analyzeClaimedItemWithMeasurement(item, in: database)
        }
        analyzeAlbum = { item, _ in
            let cachedMeasurements = await measurementCache.values(
                for: item.availablePaths,
                fingerprints: item.fingerprintsByPath
            )
            return try await concurrentAnalyzer.albumValues(
                tagURLs: item.allPaths.map { URL(fileURLWithPath: $0) },
                measurementURLs: item.availablePaths.map { URL(fileURLWithPath: $0) },
                maximumConcurrentDecoding: { concurrencyLimit.current() },
                cachedMeasurements: cachedMeasurements
            )
        }
        releaseClaim = { item in
            try database.releaseReplayGainClaim(
                trackID: item.trackID,
                fingerprint: item.fingerprint,
                claimToken: item.claimToken
            )
        }
        recoverClaim = { item in
            try database.recoverReplayGainClaim(trackID: item.trackID, claimToken: item.claimToken)
        }
    }

    init(
        database: LibraryDatabase,
        maximumConcurrentFileCount: Int = ReplayGain.defaultAnalysisFileConcurrency,
        analyzeTrack: @escaping AnalyzeTrack,
        analyzeAlbum: @escaping AnalyzeAlbum,
        workerIdleHandler: (@Sendable () async -> Void)? = nil,
        releaseClaim: ReleaseClaim? = nil,
        recoverClaim: RecoverClaim? = nil
    ) {
        self.database = database
        self.measurementCache = ReplayGainMeasurementCache()
        self.workerIdleHandler = workerIdleHandler
        let clampedConcurrency = ReplayGain.clampedAnalysisFileConcurrency(maximumConcurrentFileCount)
        self.concurrencyLimit = BoundedConcurrencyLimit(clampedConcurrency)
        self.analyzeTrack = analyzeTrack
        self.analyzeAlbum = analyzeAlbum
        self.releaseClaim = releaseClaim ?? { item in
            try database.releaseReplayGainClaim(
                trackID: item.trackID,
                fingerprint: item.fingerprint,
                claimToken: item.claimToken
            )
        }
        self.recoverClaim = recoverClaim ?? { item in
            try database.recoverReplayGainClaim(trackID: item.trackID, claimToken: item.claimToken)
        }
    }

    /// Starts replay-gain analysis.
    public func start() {
        guard controlOperationID == nil else { return }
        guard worker == nil else {
            workGeneration &+= 1
            return
        }
        let workerID = UUID()
        self.workerID = workerID
        stage = .recovering
        worker = Task(priority: .utility) {
            await self.run(workerID: workerID)
        }
    }
    /// Updates the maximum concurrent file count.
    public func setMaximumConcurrentFileCount(_ value: Int) {
        let clampedConcurrency = ReplayGain.clampedAnalysisFileConcurrency(value)
        concurrencyLimit.update(clampedConcurrency)
    }

    /// Updates the analysis concurrency when the revision is newer.
    public func setMaximumConcurrentFileCount(_ value: Int, revision: UInt64) {
        guard revision > maximumConcurrentFileCountRevision else { return }
        maximumConcurrentFileCountRevision = revision
        setMaximumConcurrentFileCount(value)
    }

    /// Cancels the active analysis worker.
    public func cancel() async {
        let operationID = beginControlOperation()
        await stopWorker()
        guard controlOperationID == operationID else { return }
        controlOperationID = nil
    }

    /// Requeues every track for replay-gain analysis.
    public func rescanAll() async throws {
        let operationID = beginControlOperation()
        await stopWorker()
        guard controlOperationID == operationID else { return }
        do {
            try database.requeueReplayGain()
        } catch {
            controlOperationID = nil
            throw error
        }
        controlOperationID = nil
        start()
    }

    /// Requeues selected tracks for replay-gain analysis.
    public func rescan(trackIDs: [Int64]) async throws {
        guard !trackIDs.isEmpty else { return }
        let operationID = beginControlOperation()
        await stopWorker()
        guard controlOperationID == operationID else { return }
        do {
            try database.requeueReplayGain(trackIDs: trackIDs)
        } catch {
            controlOperationID = nil
            throw error
        }
        controlOperationID = nil
        start()
    }

    /// Returns current replay-gain analysis status.
    public func status() throws -> ReplayGainAnalysisServiceStatus {
        let snapshot = try database.replayGainAnalysisStatusSnapshot()
        return ReplayGainAnalysisServiceStatus(
            counts: snapshot.counts,
            currentPaths: currentPaths.sorted(),
            serviceErrorReason: serviceErrorReason,
            maximumConcurrentFileCount: concurrencyLimit.current(),
            stage: stage,
            progress: snapshot.progress
        )
    }

    /// Returns recorded replay-gain failures.
    public func failures(limit: Int = 100) throws -> [ReplayGainAnalysisFailure] {
        try database.replayGainFailures(limit: limit)
    }

    func waitUntilIdle() async {
        await worker?.value
    }

}

extension ReplayGainAnalysisService {
    private func run(workerID: UUID) async {
        stage = .recovering
        await measurementCache.removeAll()
        defer {
            stage = .idle
            currentPaths.removeAll()
            if self.workerID == workerID {
                worker = nil
                self.workerID = nil
            }
        }

        do {
            guard try await recoverWorkerClaims() else { return }
            try await processAvailableWork()
        } catch is CancellationError {
        } catch {
            if claimsAwaitingRecovery.isEmpty {
                serviceErrorReason = Self.failureReason(for: error)
            }
        }
    }

    private func recoverWorkerClaims() async throws -> Bool {
        if claimsAwaitingRecovery.isEmpty {
            try database.recoverReplayGainClaims()
        }
        await recoverClaimsAwaitingRecovery()
        return claimsAwaitingRecovery.isEmpty
    }

    private func processAvailableWork() async throws {
        while !Task.isCancelled {
            let passGeneration = workGeneration
            stage = .tracks
            let analyzedTracks = try await analyzePendingTrackBatch()
            try Task.checkCancellation()
            guard let album = try database.nextReplayGainAlbumAnalysisItem() else {
                guard !analyzedTracks else { continue }
                guard try await shouldStopAfterIdle(passGeneration: passGeneration) else { continue }
                break
            }
            stage = .albums
            try await analyze(album)
        }
    }

    private func shouldStopAfterIdle(passGeneration: UInt64) async throws -> Bool {
        stage = .waiting
        if let workerIdleHandler {
            await workerIdleHandler()
        }
        try Task.checkCancellation()
        return passGeneration == workGeneration
    }

    private func analyzePendingTrackBatch() async throws -> Bool {
        guard claimsAwaitingRecovery.isEmpty else { return false }
        let batchLimit = max(concurrencyLimit.current(), 1)
        var items: [ReplayGainPendingItem] = []
        items.reserveCapacity(batchLimit)
        activeBatchStartedClaims.removeAll(keepingCapacity: true)
        do {
            for _ in 0..<batchLimit {
                try Task.checkCancellation()
                guard let item = try database.claimNextPendingReplayGainItem() else { break }
                items.append(item)
            }
            guard !items.isEmpty else { return false }

            _ = try await BoundedTaskRunner.run(
                items: items,
                maximumConcurrentCount: batchLimit,
                priority: .utility,
                cancellationCheck: { try Task.checkCancellation() },
                operation: { item in
                    await self.markBatchClaimStarted(item.claimToken)
                    try await self.analyze(item)
                }
            )
            activeBatchStartedClaims.removeAll(keepingCapacity: true)
            return true
        } catch {
            let unstartedItems = items.filter { !activeBatchStartedClaims.contains($0.claimToken) }
            activeBatchStartedClaims.removeAll(keepingCapacity: true)
            for item in unstartedItems {
                do {
                    try await releaseOrRecoverClaim(for: item)
                } catch {
                    if rememberClaimAwaitingRecovery(item) {
                        serviceErrorReason = Self.failureReason(for: error)
                    } else {
                        serviceErrorReason = "ReplayGain claim recovery backlog limit reached"
                    }
                }
            }
            if claimsAwaitingRecovery.isEmpty {
                serviceErrorReason = nil
            }
            throw error
        }
    }

    private func markBatchClaimStarted(_ claimToken: String) {
        activeBatchStartedClaims.insert(claimToken)
    }
    @discardableResult
    private func rememberClaimAwaitingRecovery(_ item: ReplayGainPendingItem) -> Bool {
        guard claimsAwaitingRecovery[item.claimToken] != nil
                || claimsAwaitingRecovery.count < Self.maximumClaimsAwaitingRecovery else {
            return false
        }
        claimsAwaitingRecovery[item.claimToken] = item
        return true
    }

    private func analyze(_ item: ReplayGainPendingItem) async throws {
        currentPaths.insert(item.path)
        defer { currentPaths.remove(item.path) }
        do {
            let result = try await analyzeTrack(item, database)
            if case let .measured(_, _, measurement) = result {
                await measurementCache.store(
                    measurement,
                    for: item.path,
                    fingerprint: item.fingerprint
                )
            } else {
                await measurementCache.remove(paths: [item.path])
            }
            if claimsAwaitingRecovery.isEmpty {
                serviceErrorReason = nil
            }
        } catch {
            let cancellationRequested = Task.isCancelled || error is CancellationError
            do {
                try await releaseOrRecoverClaim(for: item)
                claimsAwaitingRecovery.removeValue(forKey: item.claimToken)
            } catch {
                if rememberClaimAwaitingRecovery(item) {
                    serviceErrorReason = Self.failureReason(for: error)
                } else {
                    serviceErrorReason = "ReplayGain claim recovery backlog limit reached"
                }
                if cancellationRequested {
                    throw CancellationError()
                }
                throw error
            }
            if cancellationRequested {
                throw CancellationError()
            }
            throw error
        }
    }
    private func recoverClaimsAwaitingRecovery() async {
        for item in Array(claimsAwaitingRecovery.values) {
            do {
                try await releaseOrRecoverClaim(for: item)
                claimsAwaitingRecovery.removeValue(forKey: item.claimToken)
            } catch {
                serviceErrorReason = Self.failureReason(for: error)
            }
        }
        if claimsAwaitingRecovery.isEmpty {
            serviceErrorReason = nil
        }
    }

    private func releaseOrRecoverClaim(for item: ReplayGainPendingItem) async throws {
        var lastError: Error?
        for attempt in 0..<Self.claimCleanupAttemptCount {
            do {
                if try releaseClaim(item) { return }
            } catch {
                lastError = error
            }
            do {
                if try recoverClaim(item) { return }
                return
            } catch {
                lastError = error
            }
            guard attempt + 1 < Self.claimCleanupAttemptCount else { break }
            try? await Task.sleep(for: attempt == 0 ? .milliseconds(10) : .milliseconds(25))
        }
        if let lastError { throw lastError }
    }

    private func analyze(_ item: ReplayGainAlbumAnalysisItem) async throws {
        let path = item.availablePaths.first ?? item.displayPath
        currentPaths.insert(path)
        defer { currentPaths.remove(path) }
        guard let albumKey = item.albumKey else {
            await measurementCache.remove(paths: item.allPaths)
            _ = try database.recordReplayGainAlbumFailure(
                item: item,
                reason: "Album title and album artist are required"
            )
            return
        }

        do {
            guard item.trackCount <= ReplayGainAnalyzer.maximumAlbumTrackCount else {
                await measurementCache.removeAll()
                throw ReplayGainAnalyzerError.albumTrackLimitExceeded(item.trackCount)
            }
            guard item.totalDuration <= ReplayGainAnalyzer.maximumAlbumDuration else {
                await measurementCache.remove(paths: item.allPaths)
                throw ReplayGainAnalyzerError.albumDurationLimitExceeded(item.totalDuration)
            }
            let maximumConcurrentDecoding: BoundedConcurrencyProvider = { [concurrencyLimit] in
                concurrencyLimit.current()
            }
            let values = try await analyzeAlbum(item, maximumConcurrentDecoding)
            await measurementCache.remove(paths: item.allPaths)
            try Task.checkCancellation()
            _ = try database.commitReplayGainAlbumResult(
                albumKey: albumKey,
                members: item.members,
                values: values
            )
            if claimsAwaitingRecovery.isEmpty {
                serviceErrorReason = nil
            }
        } catch is CancellationError {
            await measurementCache.remove(paths: item.allPaths)
            throw CancellationError()
        } catch {
            await measurementCache.remove(paths: item.allPaths)
            let recorded = try database.recordReplayGainAlbumFailure(
                item: item,
                reason: Self.failureReason(for: error)
            )
            if !recorded {
                return
            }
        }

    }
    private func stopWorker() async {
        guard let worker else { return }
        worker.cancel()
        await worker.value
    }

    private func beginControlOperation() -> UUID {
        let operationID = UUID()
        controlOperationID = operationID
        return operationID
    }

    private static func failureReason(for error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
