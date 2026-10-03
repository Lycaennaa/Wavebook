import AppKit
import WavebookCore

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
    private let scanner: LibraryScanner
    private let onEvent: (PlaybackSessionEvent) -> Void
    private let onLibraryChanged: () -> Void
    private let onReplayGainStart: () -> Void
    private var pendingScans: [String: PendingScan] = [:]
    private var scanTask: Task<Void, Never>?
    private var activeScanKey: String?
    private var scanGenerations: [String: UUID] = [:]
    private var persistedScanBatch: PersistedScanBatch?

    init(
        databaseProvider: @escaping () -> LibraryDatabase?,
        scanner: LibraryScanner = LibraryScanner(),
        onEvent: @escaping (PlaybackSessionEvent) -> Void,
        onLibraryChanged: @escaping () -> Void,
        onReplayGainStart: @escaping () -> Void
    ) {
        self.databaseProvider = databaseProvider
        self.scanner = scanner
        self.onEvent = onEvent
        self.onLibraryChanged = onLibraryChanged
        self.onReplayGainStart = onReplayGainStart
    }

    deinit {
        scanTask?.cancel()
    }

    func addRoot() {
        guard let database = databaseProvider() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            scanInBackground(root: url, database: database, addingRoot: true)
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
        completion?(false)
    }

    private func scanInBackground(
        root: URL,
        database: LibraryDatabase,
        addingRoot: Bool,
        startReplayGain: Bool = true
    ) {
        let root = root.standardizedFileURL
        if addingRoot {
            do {
                _ = try database.addRoot(path: root.path)
                onEvent(.clearOperationalErrors(.database))
            } catch {
                onEvent(.error(error, message: "Could not add library folder", kind: .database))
                return
            }
        }

        let key = root.path
        let generation = UUID()
        scanGenerations[key] = generation
        pendingScans[key] = PendingScan(
            root: root,
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
        let scanner = scanner
        scanTask = Task(priority: .utility) { [weak self] in
            do {
                let result = try await scanner.scan(
                    root: request.root,
                    database: request.database,
                    generation: request.generation
                )
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
