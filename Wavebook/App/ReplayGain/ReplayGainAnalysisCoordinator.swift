import Foundation
import WavebookCore

@MainActor
final class ReplayGainAnalysisCoordinator {
    private let databaseProvider: () -> LibraryDatabase?
    private let onEvent: (PlaybackSessionEvent) -> Void
    private(set) var service: ReplayGainAnalysisService?
    private(set) var fileConcurrency = ReplayGain.defaultAnalysisFileConcurrency
    private var fileConcurrencyRevision: UInt64 = 0
    private var albumTask: Task<Void, Never>?
    private var albumGeneration: UUID?

    init(
        databaseProvider: @escaping () -> LibraryDatabase?,
        onEvent: @escaping (PlaybackSessionEvent) -> Void
    ) {
        self.databaseProvider = databaseProvider
        self.onEvent = onEvent
    }

    deinit {
        albumTask?.cancel()
        if let service {
            Task { await service.cancel() }
        }
    }
    func cancelAlbumRescan() {
        albumTask?.cancel()
        albumTask = nil
        albumGeneration = nil
    }

    func applySavedFileConcurrency() {
        do {
            fileConcurrency = try databaseProvider()?.replayGainAnalysisFileConcurrency()
                ?? ReplayGain.defaultAnalysisFileConcurrency
            onEvent(.clearOperationalErrors(.database))
        } catch {
            fileConcurrency = ReplayGain.defaultAnalysisFileConcurrency
            onEvent(.error(error, message: "Could not load saved ReplayGain analysis concurrency", kind: .database))
        }
        _ = makeServiceIfNeeded()
    }
    func applySavedFileConcurrency(_ savedConcurrency: Int) {
        fileConcurrency = ReplayGain.clampedAnalysisFileConcurrency(savedConcurrency)
        onEvent(.clearOperationalErrors(.database))
        _ = makeServiceIfNeeded()
    }

    func start() {
        guard let service = makeServiceIfNeeded() else { return }
        Task { await service.start() }
    }

    private func makeServiceIfNeeded() -> ReplayGainAnalysisService? {
        guard let database = databaseProvider() else { return nil }
        if let service { return service }
        let service = ReplayGainAnalysisService(
            database: database,
            maximumConcurrentFileCount: fileConcurrency
        )
        self.service = service
        return service
    }

    func rescanLoudness(for tracks: [Track]) {
        guard let service else {
            onEvent(.replayGainActionError("ReplayGain analysis is unavailable"))
            return
        }

        var seen = Set<Int64>()
        let trackIDs = tracks.compactMap(\.id).filter { seen.insert($0).inserted }
        guard !trackIDs.isEmpty else {
            onEvent(.replayGainActionError("Selected tracks are no longer in the library"))
            return
        }

        Task { [weak self, service] in
            do {
                try await service.rescan(trackIDs: trackIDs)
            } catch is CancellationError {
            } catch {
                self?.onEvent(.replayGainActionError(error.localizedDescription))
            }
        }
    }

    func rescanAlbum(
        key: AlbumKey?,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        guard let key else {
            onEvent(.replayGainActionError("No album is selected"))
            return
        }
        guard let database = databaseProvider() else {
            onEvent(.replayGainActionError("ReplayGain analysis is unavailable"))
            return
        }

        albumTask?.cancel()
        let generation = UUID()
        albumGeneration = generation
        albumTask = Task(priority: .utility) { [weak self, database] in
            let worker = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let tracks = try database.allTracks(album: key, matching: "")
                try Task.checkCancellation()
                return tracks
            }
            defer { worker.cancel() }

            do {
                let tracks = try await withTaskCancellationHandler(operation: {
                    try await worker.value
                }, onCancel: {
                    worker.cancel()
                })
                try Task.checkCancellation()
                guard let self,
                      self.albumGeneration == generation,
                      isCurrent() else { return }
                self.albumTask = nil
                self.albumGeneration = nil
                self.rescanLoudness(for: tracks)
            } catch is CancellationError {
            } catch {
                guard let self, self.albumGeneration == generation else { return }
                self.albumTask = nil
                self.albumGeneration = nil
                self.onEvent(.replayGainActionError(error.localizedDescription))
            }
        }
    }

    func setFileConcurrency(_ requestedValue: Int, restore: @escaping (Int) -> Void) {
        let value = ReplayGain.clampedAnalysisFileConcurrency(requestedValue)
        guard value != fileConcurrency else { return }
        guard let database = databaseProvider() else {
            restore(fileConcurrency)
            onEvent(.replayGainActionError("ReplayGain settings are unavailable"))
            return
        }

        do {
            try database.saveReplayGainAnalysisFileConcurrency(value)
            onEvent(.clearOperationalErrors(.database))
        } catch {
            restore(fileConcurrency)
            onEvent(.error(error, message: "Could not save ReplayGain analysis concurrency", kind: .database))
            return
        }

        fileConcurrency = value
        if let service {
            fileConcurrencyRevision += 1
            let revision = fileConcurrencyRevision
            Task {
                await service.setMaximumConcurrentFileCount(value, revision: revision)
            }
        }
    }

    func cancel() {
        albumTask?.cancel()
        albumTask = nil
        albumGeneration = nil
        if let service {
            Task { await service.cancel() }
        }
    }
}
