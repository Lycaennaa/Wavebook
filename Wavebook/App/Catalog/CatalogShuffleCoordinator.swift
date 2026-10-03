import Foundation
import WavebookCore

enum CatalogShuffleRequest: Sendable {
    case songs(query: String)
    case artist(query: String, name: String)
    case album(query: String, key: AlbumKey)
    case genre(query: String, name: String)
}

enum CatalogQueueStart: Sendable {
    case shuffled
    case selectedTrack(Track)
}

private struct CatalogShuffleSearch {
    let scope: LibraryTrackScope
    let query: String
    let searchField: CatalogSearchField

    nonisolated init(request: CatalogShuffleRequest) {
        switch request {
        case let .songs(query):
            scope = .all
            self.query = query
            searchField = .title
        case let .artist(query, name):
            scope = .artist(name)
            self.query = query
            searchField = .all
        case let .album(query, key):
            scope = .album(key)
            self.query = query
            searchField = .all
        case let .genre(query, name):
            scope = .genre(name)
            self.query = query
            searchField = .all
        }
    }
}

private enum CatalogShuffleQueueError: LocalizedError {
    case selectedTrackUnavailable

    var errorDescription: String? {
        "The selected track is no longer available in this list."
    }
}

@MainActor
final class CatalogShuffleCoordinator {
    private let databaseProvider: () -> LibraryDatabase?
    private let queueLoader: @Sendable (CatalogShuffleRequest, LibraryDatabase) throws -> PlaybackQueue
    private var task: Task<Void, Never>?
    private var generation = PlaybackRequestGeneration()

    init(databaseProvider: @escaping () -> LibraryDatabase?) {
        self.databaseProvider = databaseProvider
        queueLoader = { request, database in
            try Self.makeQueue(request: request, database: database)
        }
    }

    init(
        databaseProvider: @escaping () -> LibraryDatabase?,
        queueLoader: @escaping @Sendable (CatalogShuffleRequest, LibraryDatabase) throws -> PlaybackQueue
    ) {
        self.databaseProvider = databaseProvider
        self.queueLoader = queueLoader
    }

    deinit {
        task?.cancel()
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation.cancel()
    }

    @discardableResult
    func start(
        request: CatalogShuffleRequest,
        start: CatalogQueueStart,
        onSuccess: @escaping @MainActor (PlaybackQueue) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) -> Bool {
        cancel()
        guard let database = databaseProvider() else { return false }
        let requestGeneration = generation.begin()
        let queueLoader = self.queueLoader
        task = Task { [weak self, database, queueLoader] in
            let cancellation = LibraryDatabaseCancellationToken()
            let worker = Task.detached(priority: .userInitiated) {
                defer { cancellation.cancel() }
                return try LibraryDatabase.withCatalogCancellationToken(cancellation) {
                    try Task.checkCancellation()
                    var queue = try queueLoader(request, database)
                    try Task.checkCancellation()
                    switch start {
                    case .shuffled:
                        queue.setShuffleEnabled(true)
                    case let .selectedTrack(track):
                        queue.setShuffleEnabled(false)
                        guard let index = queue.entries.firstIndex(where: {
                            $0.track.hasSameIdentity(as: track)
                        }), queue.play(at: index) != nil else {
                            throw CatalogShuffleQueueError.selectedTrackUnavailable
                        }
                    }
                    return queue
                }
            }
            defer { worker.cancel() }

            do {
                let queue = try await withTaskCancellationHandler(operation: {
                    try await worker.value
                }, onCancel: {
                    cancellation.cancel()
                    worker.cancel()
                })
                try Task.checkCancellation()
                guard let self, self.generation.accepts(requestGeneration) else { return }
                self.task = nil
                self.generation.cancel()
                onSuccess(queue)
            } catch is CancellationError {
            } catch {
                guard let self, self.generation.accepts(requestGeneration) else { return }
                self.task = nil
                self.generation.cancel()
                onFailure(error)
            }
        }
        return true
    }

    private nonisolated static func makeQueue(
        request: CatalogShuffleRequest,
        database: LibraryDatabase
    ) throws -> PlaybackQueue {
        let search = CatalogShuffleSearch(request: request)
        var queue = PlaybackQueue()
        try database.forEachTrackPage(
            for: search.scope,
            matching: search.query,
            searchField: search.searchField,
            limit: LibraryDatabase.maximumTrackPageSize
        ) { page in
            try Task.checkCancellation()
            queue.append(contentsOf: page)
            return queue.entries.count < PlaybackQueue.maximumEntryCount
        }
        return queue
    }
}
