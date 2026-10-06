import AppKit
import WavebookCore

typealias LibraryRootScanOperation = @MainActor (URL, LibraryDatabase, UUID) async throws -> LibraryScanResult

@MainActor
final class LibraryScanCoordinator {
    private struct PendingScan {
        let root: URL
        let database: LibraryDatabase
        let generation: UUID
        let startReplayGain: Bool
    }

    private struct PersistedScanBatch {
        var remainingRootPaths: Set<String>
        var succeeded: Bool
        let completion: (Bool) -> Void
    }

    private let databaseProvider: () -> LibraryDatabase?
    private let scan: LibraryRootScanOperation
    private let onEvent: (PlaybackSessionEvent) -> Void
    private let onLibraryChanged: () -> Void
    private let onReplayGainStart: () -> Void
    private var pendingScans: [String: PendingScan] = [:]
    private var scanTask: Task<Void, Never>?
    private var activeScanKey: String?
    private var scanGenerations: [String: UUID] = [:]
    private var persistedScanBatch: PersistedScanBatch?
    private var rootRemovalGenerations: [String: UUID] = [:]

    convenience init(
        databaseProvider: @escaping () -> LibraryDatabase?,
        scanner: LibraryScanner = LibraryScanner(),
        onEvent: @escaping (PlaybackSessionEvent) -> Void,
        onLibraryChanged: @escaping () -> Void,
        onReplayGainStart: @escaping () -> Void
    ) {
        self.init(
            databaseProvider: databaseProvider,
            scan: { root, database, generation in
                try await scanner.scan(root: root, database: database, generation: generation)
            },
            onEvent: onEvent,
            onLibraryChanged: onLibraryChanged,
            onReplayGainStart: onReplayGainStart
        )
    }

    init(
        databaseProvider: @escaping () -> LibraryDatabase?,
        scan: @escaping LibraryRootScanOperation,
        onEvent: @escaping (PlaybackSessionEvent) -> Void,
        onLibraryChanged: @escaping () -> Void,
        onReplayGainStart: @escaping () -> Void
    ) {
        self.databaseProvider = databaseProvider
        self.scan = scan
        self.onEvent = onEvent
        self.onLibraryChanged = onLibraryChanged
        self.onReplayGainStart = onReplayGainStart
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

    func libraryRoots() -> [LibraryRoot] {
        guard let database = databaseProvider() else { return [] }
        do {
            let roots = try database.roots()
            onEvent(.clearOperationalErrors(.database))
            return roots
        } catch {
            onEvent(.error(error, message: "Could not load library folders", kind: .database))
            return []
        }
    }

    func addRoots(_ roots: [URL]) {
        guard let database = databaseProvider() else { return }
        for root in roots {
            scanInBackground(root: root, database: database, addingRoot: true)
        }
    }

    func removeRoot(_ root: LibraryRoot) async {
        guard let database = databaseProvider() else { return }
        let removalGeneration = UUID()
        rootRemovalGenerations[root.path] = removalGeneration
        pendingScans[root.path] = nil
        scanGenerations[root.path] = nil
        if activeScanKey == root.path, let scanTask {
            scanTask.cancel()
            await scanTask.value
        }
        guard rootRemovalGenerations[root.path] == removalGeneration else { return }
        do {
            _ = try database.removeRoot(id: root.id)
            rootRemovalGenerations[root.path] = nil
            finishPersistedScanRoot(key: root.path, succeeded: true)
            onEvent(.clearOperationalErrors(.database))
            onLibraryChanged()
        } catch {
            rootRemovalGenerations[root.path] = nil
            onEvent(.error(error, message: "Could not remove library folder", kind: .database))
            scanInBackground(root: root.url, database: database, addingRoot: false)
        }
    }

    func rescanPersistedRoots(
        startReplayGain: Bool = true,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard let database = databaseProvider() else {
            completion?(false)
            return
        }
        let roots: [LibraryRoot]
        do {
            roots = try database.roots()
            onEvent(.clearOperationalErrors(.database))
        } catch {
            onEvent(.error(error, message: "Could not load library folders", kind: .database))
            completion?(false)
            return
        }
        let availableRoots = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !availableRoots.isEmpty else {
            if startReplayGain { onReplayGainStart() }
            completion?(true)
            return
        }
        if let completion {
            persistedScanBatch = PersistedScanBatch(
                remainingRootPaths: Set(availableRoots.map(\.path)),
                succeeded: true,
                completion: completion
            )
        }
        for root in availableRoots {
            scanInBackground(
                root: root.url,
                database: database,
                addingRoot: false,
                startReplayGain: startReplayGain
            )
        }
    }

    func cancel() {
        let completion = persistedScanBatch?.completion
        persistedScanBatch = nil
        scanTask?.cancel()
        scanTask = nil
        activeScanKey = nil
        pendingScans.removeAll()
        scanGenerations.removeAll()
        // A confirmed root removal resumes after its scan task settles.
        completion?(false)
    }

    private func scanInBackground(
        root: URL,
        database: LibraryDatabase,
        addingRoot: Bool,
        startReplayGain: Bool = true
    ) {
        var scanRoot = root
        var rootPath = root.path
        if addingRoot {
            do {
                let rootID = try database.addRoot(path: root.path)
                guard let registeredRoot = try database.roots().first(where: { $0.id == rootID }) else {
                    throw LibraryDatabaseError.missingRoot(String(rootID))
                }
                rootPath = registeredRoot.path
                scanRoot = registeredRoot.url
                onEvent(.clearOperationalErrors(.database))
            } catch {
                onEvent(.error(error, message: "Could not add library folder", kind: .database))
                return
            }
        }

        let key = rootPath
        rootRemovalGenerations[key] = nil
        let generation = UUID()
        scanGenerations[key] = generation
        pendingScans[key] = PendingScan(
            root: scanRoot,
            database: database,
            generation: generation,
            startReplayGain: startReplayGain
        )
        if activeScanKey == key {
            scanTask?.cancel()
        }
        startNextScanIfNeeded()
    }

    private func startNextScanIfNeeded() {
        guard scanTask == nil,
              let key = pendingScans.keys.sorted(by: CatalogFacetOrdering.localizedPathPrecedes).first,
              let request = pendingScans.removeValue(forKey: key) else { return }
        activeScanKey = key
        let scan = scan
        scanTask = Task(priority: .utility) { [weak self] in
            do {
                let result = try await scan(request.root, request.database, request.generation)
                self?.scanCompleted(
                    key: key,
                    generation: request.generation,
                    error: nil,
                    wasCancelled: false,
                    startReplayGain: request.startReplayGain,
                    result: result
                )
            } catch is CancellationError {
                self?.scanCompleted(
                    key: key,
                    generation: request.generation,
                    error: nil,
                    wasCancelled: true,
                    startReplayGain: request.startReplayGain
                )
            } catch {
                self?.scanCompleted(
                    key: key,
                    generation: request.generation,
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
        error: Error?,
        wasCancelled: Bool,
        startReplayGain: Bool,
        result: LibraryScanResult? = nil
    ) {
        guard activeScanKey == key else { return }
        scanTask = nil
        activeScanKey = nil
        if scanGenerations[key] == generation {
            scanGenerations[key] = nil
            if let error {
                onEvent(
                    .error(
                        error,
                        message: "Library scan failed; previous library data was kept",
                        kind: .libraryScan
                    )
                )
            } else if !wasCancelled {
                onEvent(.clearOperationalErrors(.libraryScan))
                if let result, let summary = scanSummary(for: result) {
                    onEvent(.presentOperationalMessage(summary, kind: .libraryScan))
                }
                onLibraryChanged()
                if startReplayGain { onReplayGainStart() }
            }
            finishPersistedScanRoot(key: key, succeeded: error == nil && !wasCancelled)
        }
        startNextScanIfNeeded()
    }

    private func finishPersistedScanRoot(key: String, succeeded: Bool) {
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
