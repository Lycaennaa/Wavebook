import AppKit
import WavebookCore

struct LibraryRootScanProgress: Equatable, Sendable {
    let root: URL
    let completedFileCount: Int
    let totalFileCount: Int
    let matchedLyricTrackCount: Int?
}

struct LibraryRootScanFailure: Equatable, Sendable {
    let root: URL
}

struct LibraryRootMatchedLyricsCount: Equatable, Sendable {
    let root: URL
    let matchedLyricTrackCount: Int?
}

@MainActor
final class LibraryScanCoordinator {
    private struct PendingScan {
        let root: URL
        let database: LibraryDatabase
        let generation: UUID
        let startReplayGain: Bool
        let access: ScopedRootAccess
        let rootID: Int64
        let pathUpdate: RootPathUpdate?
    }

    private struct PersistedScanBatch {
        var remainingRootPaths: Set<String>
        var succeeded: Bool
        let completion: (Bool) -> Void
    }

    let databaseProvider: () -> LibraryDatabase?
    let scan: LibraryRootScanOperation
    let onEvent: (PlaybackSessionEvent) -> Void
    let onLibraryChanged: () -> Void
    let onReplayGainStart: () -> Void
    let onScanStateChanged: (LibraryScanSnapshot) -> Void
    private var pendingScans: [String: PendingScan] = [:]
    private var scanTask: Task<Void, Never>?
    private var activeScanKey: String?
    private var activeScanRootID: Int64?
    private var scanGenerations: [String: UUID] = [:]
    private var persistedScanBatch: PersistedScanBatch?
    private var rootRemovalGenerations: [Int64: UUID] = [:]
    private var latestScanProgress: LibraryRootScanProgress?
    private var latestCompletedMatchedLyricsCount: LibraryRootMatchedLyricsCount?
    private var latestScanFailure: LibraryRootScanFailure?

    var isScanning: Bool { activeScanKey != nil || !pendingScans.isEmpty }
    var snapshot: LibraryScanSnapshot {
        LibraryScanSnapshot(
            isScanning: isScanning,
            progress: latestScanProgress,
            lastCompletedMatchedLyricsCount: latestCompletedMatchedLyricsCount,
            failure: latestScanFailure
        )
    }

    convenience init(
        databaseProvider: @escaping () -> LibraryDatabase?,
        scanner: LibraryScanner = LibraryScanner(),
        onEvent: @escaping (PlaybackSessionEvent) -> Void,
        onLibraryChanged: @escaping () -> Void,
        onReplayGainStart: @escaping () -> Void,
        onScanStateChanged: @escaping (LibraryScanSnapshot) -> Void = { _ in }
    ) {
        self.init(
            databaseProvider: databaseProvider,
            scan: { root, database, generation, progress in
                try await scanner.scan(
                    root: root,
                    database: database,
                    generation: generation,
                    progress: progress
                )
            },
            onEvent: onEvent,
            onLibraryChanged: onLibraryChanged,
            onReplayGainStart: onReplayGainStart,
            onScanStateChanged: onScanStateChanged
        )
    }

    init(
        databaseProvider: @escaping () -> LibraryDatabase?,
        scan: @escaping LibraryRootScanOperation,
        onEvent: @escaping (PlaybackSessionEvent) -> Void,
        onLibraryChanged: @escaping () -> Void,
        onReplayGainStart: @escaping () -> Void,
        onScanStateChanged: @escaping (LibraryScanSnapshot) -> Void = { _ in }
    ) {
        self.databaseProvider = databaseProvider
        self.scan = scan
        self.onEvent = onEvent
        self.onLibraryChanged = onLibraryChanged
        self.onReplayGainStart = onReplayGainStart
        self.onScanStateChanged = onScanStateChanged
    }

    deinit {
        scanTask?.cancel()
    }

    @discardableResult
    func addRoot() -> Bool {
        guard databaseProvider() != nil else { return false }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return false }
        addRoots(panel.urls)
        return true
    }


    func clearScanResult(for rootPath: String) {
        let hadProgress = latestScanProgress?.root.path == rootPath
        let hadCompletedCount = latestCompletedMatchedLyricsCount?.root.path == rootPath
        let hadFailure = latestScanFailure?.root.path == rootPath
        if hadProgress { latestScanProgress = nil }
        if hadCompletedCount { latestCompletedMatchedLyricsCount = nil }
        if hadFailure { latestScanFailure = nil }
        if hadProgress || hadCompletedCount || hadFailure { onScanStateChanged(snapshot) }
    }


    func beginRootRemoval(forRootID rootID: Int64) async -> (generation: UUID, scanKeys: Set<String>) {
        let generation = UUID()
        rootRemovalGenerations[rootID] = generation
        var scanKeys = Set(
            pendingScans.compactMap { key, request in
                request.rootID == rootID ? key : nil
            }
        )
        for key in scanKeys {
            pendingScans[key] = nil
            scanGenerations[key] = nil
        }
        if activeScanRootID == rootID,
           let activeKey = activeScanKey,
           let scanTask {
            scanKeys.insert(activeKey)
            scanGenerations[activeKey] = nil
            scanTask.cancel()
            await scanTask.value
        }
        return (generation, scanKeys)
    }

    func isRootRemovalCurrent(forRootID rootID: Int64, generation: UUID) -> Bool {
        rootRemovalGenerations[rootID] == generation
    }

    func isRootRemovalInProgress(forRootID rootID: Int64) -> Bool {
        rootRemovalGenerations[rootID] != nil
    }

    func finishRootRemoval(forRootID rootID: Int64, generation: UUID) {
        guard rootRemovalGenerations[rootID] == generation else { return }
        rootRemovalGenerations[rootID] = nil
    }

    func beginPersistedScanBatch(
        remainingRootPaths: Set<String>,
        succeeded: Bool,
        completion: ((Bool) -> Void)?
    ) {
        guard let completion else { return }
        persistedScanBatch = PersistedScanBatch(
            remainingRootPaths: remainingRootPaths,
            succeeded: succeeded,
            completion: completion
        )
    }

    func cancel() {
        let wasScanning = isScanning
        let completion = persistedScanBatch?.completion
        persistedScanBatch = nil
        scanTask?.cancel()
        scanTask = nil
        activeScanKey = nil
        activeScanRootID = nil
        pendingScans.removeAll()
        scanGenerations.removeAll()
        if wasScanning { onScanStateChanged(snapshot) }
        // A confirmed root removal resumes after its scan task settles.
        completion?(false)
    }

    func scanInBackground(
        root: URL,
        database: LibraryDatabase,
        rootAccess: RootScanAccess = .selectedFolder,
        startReplayGain: Bool = true
    ) {
        let accessLease: ScopedRootAccess
        let addingRoot: Bool
        let scanKeyOverride: String?
        let pathUpdate: RootPathUpdate?
        var rootID: Int64?
        switch rootAccess {
        case .selectedFolder:
            accessLease = ScopedRootAccess(url: root)
            addingRoot = true
            scanKeyOverride = nil
            pathUpdate = nil
        case let .persisted(
            rootID: persistedRootID,
            access: access,
            scanKey: scanKey,
            pathUpdate: update
        ):
            guard rootRemovalGenerations[persistedRootID] == nil else {
                finishPersistedScanRoot(key: scanKey, succeeded: false)
                return
            }
            accessLease = access
            addingRoot = false
            rootID = persistedRootID
            scanKeyOverride = scanKey
            pathUpdate = update
        }
        var scanRoot = root
        var rootPath = root.path
        if addingRoot {
            do {
                let bookmark = Self.makeSecurityScopedBookmark(for: root)
                let registeredRootID = try database.addRoot(
                    path: root.path,
                    securityScopedBookmark: bookmark
                )
                guard let registeredRoot = try database.roots().first(where: { $0.id == registeredRootID }) else {
                    throw LibraryDatabaseError.missingRoot(String(registeredRootID))
                }
                rootID = registeredRootID
                rootRemovalGenerations[registeredRootID] = nil
                rootPath = registeredRoot.path
                scanRoot = registeredRoot.url
                onEvent(.clearOperationalErrors(.database))
            } catch {
                latestScanFailure = LibraryRootScanFailure(root: root)
                onScanStateChanged(snapshot)
                onEvent(.error(error, message: "Could not add library folder", kind: .database))
                return
            }
        }
        guard let rootID else {
            let error = LibraryDatabaseError.missingRoot(rootPath)
            latestScanFailure = LibraryRootScanFailure(root: scanRoot)
            onScanStateChanged(snapshot)
            onEvent(.error(error, message: "Could not add library folder", kind: .database))
            return
        }

        let wasScanning = isScanning
        let key = scanKeyOverride ?? rootPath
        let generation = UUID()
        scanGenerations[key] = generation
        pendingScans[key] = PendingScan(
            root: scanRoot,
            database: database,
            generation: generation,
            startReplayGain: startReplayGain,
            access: accessLease,
            rootID: rootID,
            pathUpdate: pathUpdate
        )
        if activeScanRootID == rootID, let scanTask {
            scanTask.cancel()
        }
        startNextScanIfNeeded()
        if !wasScanning, isScanning {
            latestScanProgress = nil
            latestScanFailure = nil
            onScanStateChanged(snapshot)
        }
    }

    private func startNextScanIfNeeded() {
        guard scanTask == nil,
              let key = pendingScans.keys.sorted(by: CatalogFacetOrdering.localizedPathPrecedes).first,
              let request = pendingScans.removeValue(forKey: key) else { return }
        activeScanKey = key
        activeScanRootID = request.rootID
        var scanRoot = request.root
        var rootPathChanged = false
        if let pathUpdate = request.pathUpdate {
            guard rootRemovalGenerations[request.rootID] == nil else {
                scanCompleted(
                    key: key,
                    generation: request.generation,
                    root: scanRoot,
                    rootPathChanged: false,
                    error: nil,
                    wasCancelled: true,
                    startReplayGain: request.startReplayGain
                )
                return
            }
            do {
                let canonicalPath = try request.database.updateRootPath(
                    pathUpdate.path,
                    forRootID: request.rootID,
                    securityScopedBookmark: pathUpdate.securityScopedBookmark
                )
                scanRoot = URL(fileURLWithPath: canonicalPath, isDirectory: true)
                rootPathChanged = canonicalPath != key
            } catch {
                scanCompleted(
                    key: key,
                    generation: request.generation,
                    root: scanRoot,
                    rootPathChanged: false,
                    error: error,
                    wasCancelled: false,
                    startReplayGain: request.startReplayGain
                )
                return
            }
        }
        if latestScanProgress != nil {
            latestScanProgress = nil
            onScanStateChanged(snapshot)
        }
        let scan = scan
        let progressRoot = scanRoot
        let progressGeneration = request.generation
        let scanProgress = scanProgressHandler(root: progressRoot, key: key, generation: progressGeneration)
        scanTask = Task(priority: .utility) { [weak self] in
            do {
                let result = try await scan(
                    scanRoot,
                    request.database,
                    request.generation,
                    scanProgress
                )
                self?.scanCompleted(
                    key: key,
                    generation: request.generation,
                    root: scanRoot,
                    rootPathChanged: rootPathChanged,
                    error: nil,
                    wasCancelled: false,
                    startReplayGain: request.startReplayGain,
                    result: result
                )
            } catch is CancellationError {
                self?.scanCompleted(
                    key: key,
                    generation: request.generation,
                    root: scanRoot,
                    rootPathChanged: rootPathChanged,
                    error: nil,
                    wasCancelled: true,
                    startReplayGain: request.startReplayGain
                )
            } catch {
                self?.scanCompleted(
                    key: key,
                    generation: request.generation,
                    root: scanRoot,
                    rootPathChanged: rootPathChanged,
                    error: error,
                    wasCancelled: false,
                    startReplayGain: request.startReplayGain
                )
            }
        }
    }

    private func scanCompleted(
        key: String,
        generation: UUID,
        root: URL,
        rootPathChanged: Bool,
        error: Error?,
        wasCancelled: Bool,
        startReplayGain: Bool,
        result: LibraryScanResult? = nil
    ) {
        guard activeScanKey == key else { return }
        scanTask = nil
        activeScanKey = nil
        activeScanRootID = nil
        var didFail = false
        if scanGenerations[key] == generation {
            scanGenerations[key] = nil
            if let error {
                latestScanFailure = LibraryRootScanFailure(root: root)
                didFail = true
                onEvent(
                    .error(
                        error,
                        message: "Library scan failed; previous library data was kept",
                        kind: .libraryScan
                    )
                )
            } else if !wasCancelled {
                latestScanFailure = nil
                onEvent(.clearOperationalErrors(.libraryScan))
                if let result, let summary = scanSummary(for: result) {
                    onEvent(.presentOperationalMessage(summary, kind: .libraryScan))
                }
                if let result {
                    updateMatchedLyricTrackCount(result)
                    latestCompletedMatchedLyricsCount = LibraryRootMatchedLyricsCount(
                        root: latestScanProgress?.root ?? root,
                        matchedLyricTrackCount: result.matchedLyricTrackCount
                    )
                }
                onLibraryChanged()
                if startReplayGain { onReplayGainStart() }
            }
            if rootPathChanged && (error != nil || wasCancelled) {
                onLibraryChanged()
            }
            finishPersistedScanRoot(key: key, succeeded: error == nil && !wasCancelled)
        }
        startNextScanIfNeeded()
        if didFail || !isScanning { onScanStateChanged(snapshot) }
    }

    func finishPersistedScanRoot(key: String, succeeded: Bool) {
        guard var batch = persistedScanBatch,
              batch.remainingRootPaths.remove(key) != nil else { return }
        batch.succeeded = batch.succeeded && succeeded
        guard batch.remainingRootPaths.isEmpty else {
            persistedScanBatch = batch
            return
        }
        persistedScanBatch = nil
        batch.completion(batch.succeeded)
    }

    private func scanSummary(for result: LibraryScanResult) -> String? {
        guard result.failedCandidateCount > 0 else { return nil }
        let fileLabel = result.failedCandidateCount == 1 ? "file" : "files"
        var summary = "Library scan completed with \(result.failedCandidateCount) unreadable \(fileLabel)"
        let names = result.failures.prefix(3).map { URL(fileURLWithPath: $0.path).lastPathComponent }
        if !names.isEmpty {
            summary += ": \(names.joined(separator: ", "))"
        }
        let remainingCount = result.failedCandidateCount - names.count
        if remainingCount > 0 {
            summary += " (and \(remainingCount) more)"
        }
        return summary
    }
}

extension LibraryScanCoordinator {
    func libraryRoots() -> [LibraryRoot]? {
        guard let database = databaseProvider() else { return nil }
        do {
            let roots = try database.roots()
            onEvent(.clearOperationalErrors(.database))
            return roots
        } catch {
            onEvent(.error(error, message: "Could not load library folders", kind: .database))
            return nil
        }
    }
}

extension LibraryScanCoordinator {

    static func makeSecurityScopedBookmark(for url: URL) -> Data? {
        if let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return bookmark
        }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolveSecurityScopedBookmark(_ bookmark: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        if let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return (url: url, isStale: isStale)
        }
        isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        return (url: url, isStale: isStale)
    }
    func scanProgressHandler(root: URL, key: String, generation: UUID) -> LibraryScanProgressHandler {
        { [weak self] completedCount, totalCount in
            await MainActor.run {
                guard let self,
                      self.activeScanKey == key,
                      self.scanGenerations[key] == generation else { return }
                self.latestScanProgress = LibraryRootScanProgress(
                    root: root,
                    completedFileCount: completedCount,
                    totalFileCount: totalCount,
                    matchedLyricTrackCount: self.latestScanProgress?.matchedLyricTrackCount
                )
                self.onScanStateChanged(self.snapshot)
            }
        }
    }
    func updateMatchedLyricTrackCount(_ result: LibraryScanResult) {
        guard let progress = latestScanProgress else { return }
        latestScanProgress = LibraryRootScanProgress(
            root: progress.root,
            completedFileCount: progress.completedFileCount,
            totalFileCount: progress.totalFileCount,
            matchedLyricTrackCount: result.matchedLyricTrackCount
        )
    }
}
