import Foundation
import WavebookCore

enum PlaylistPageContent: Sendable {
    case manual(LibraryPlaylistItemPage)
    case tracks(LibraryPlaylistTrackPage)
}

struct PlaylistPageLoadRequest: Sendable {
    let destination: PlaylistDestination
    let query: String
    let limit: Int
    let offset: Int

    nonisolated func load(from database: LibraryDatabase) throws -> PlaylistPageLoadResult {
        try Task.checkCancellation()
        switch destination {
        case let .system(kind):
            let page = try database.systemPlaylistPage(kind, limit: limit, offset: offset, query: query)
            return PlaylistPageLoadResult(
                destination: destination,
                title: kind.displayName,
                kind: nil,
                definition: nil,
                content: .tracks(page)
            )
        case let .user(id):
            guard let playlist = try database.playlist(id: id) else {
                throw LibraryDatabaseError.missingPlaylist(id)
            }
            switch playlist.kind {
            case .manual:
                let page = try database.playlistItemPage(
                    playlistID: id,
                    query: query,
                    limit: limit,
                    offset: offset
                )
                return PlaylistPageLoadResult(
                    destination: destination,
                    title: playlist.name,
                    kind: .manual,
                    definition: playlist.definition,
                    content: .manual(page)
                )
            case .smart:
                let page = try database.smartPlaylistPage(playlistID: id, limit: limit, offset: offset, query: query)
                return PlaylistPageLoadResult(
                    destination: destination,
                    title: playlist.name,
                    kind: .smart,
                    definition: playlist.definition,
                    content: .tracks(page)
                )
            }
        }
    }
}

struct PlaylistPageLoadResult: Sendable {
    let destination: PlaylistDestination
    let title: String
    let kind: PlaylistKind?
    let definition: PlaylistDefinition?
    let content: PlaylistPageContent
}

@MainActor
private final class PlaylistLoadCoordinator<Result: Sendable, Request: Sendable> {
    private var task: Task<Void, Never>?
    private var generation = PlaybackRequestGeneration()

    var isLoading: Bool { task != nil }

    deinit {
        task?.cancel()
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation.cancel()
    }

    func start(
        database: LibraryDatabase,
        request: Request,
        load: @escaping @Sendable (Request, LibraryDatabase) throws -> Result,
        onSuccess: @escaping @MainActor (Result) -> Void,
        onFailure: @escaping @MainActor (Request, Error) -> Void
    ) {
        cancel()
        let requestGeneration = generation.begin()
        let cancellation = LibraryDatabaseCancellationToken()
        let worker = Task.detached(priority: .userInitiated) {
            defer { cancellation.cancel() }
            return try LibraryDatabase.withCatalogCancellationToken(cancellation) {
                try load(request, database)
            }
        }

        task = Task { [weak self] in
            do {
                let result = try await withTaskCancellationHandler(operation: {
                    try await worker.value
                }, onCancel: {
                    cancellation.cancel()
                    worker.cancel()
                })
                try Task.checkCancellation()
                guard let self, self.generation.accepts(requestGeneration) else { return }
                self.task = nil
                self.generation.cancel()
                onSuccess(result)
            } catch is CancellationError {
                guard let self, self.generation.accepts(requestGeneration) else { return }
                self.task = nil
                self.generation.cancel()
            } catch {
                guard let self, self.generation.accepts(requestGeneration) else { return }
                self.task = nil
                self.generation.cancel()
                onFailure(request, error)
            }
        }
    }
}

@MainActor
final class PlaylistPageLoadCoordinator {
    private let coordinator = PlaylistLoadCoordinator<PlaylistPageLoadResult, PlaylistPageLoadRequest>()

    var isLoading: Bool { coordinator.isLoading }

    func cancel() {
        coordinator.cancel()
    }

    func start(
        database: LibraryDatabase,
        request: PlaylistPageLoadRequest,
        onSuccess: @escaping @MainActor (PlaylistPageLoadResult) -> Void,
        onFailure: @escaping @MainActor (PlaylistPageLoadRequest, Error) -> Void
    ) {
        coordinator.start(
            database: database,
            request: request,
            load: { request, database in try request.load(from: database) },
            onSuccess: onSuccess,
            onFailure: onFailure
        )
    }
}

struct PlaylistPlaybackLoadRequest: Sendable, Equatable {
    let destination: PlaylistDestination
    let query: String
    let source: ListeningPlaybackSource
    let startingAt: PlaylistPlaybackStart

    nonisolated func load(from database: LibraryDatabase) throws -> PlaybackQueue {
        try Task.checkCancellation()
        let queue: PlaybackQueue
        switch destination {
        case let .system(kind):
            queue = try database.resolvePlaylistQueue(kind, matching: query, source: source)
        case let .user(id):
            queue = try database.resolvePlaylistQueue(id: id, matching: query, source: source)
        }
        try Task.checkCancellation()
        return try PlaylistPlaybackSelection.preparedQueue(from: queue, startingAt: startingAt)
    }
}

@MainActor
final class PlaylistPlaybackLoadCoordinator {
    private let coordinator = PlaylistLoadCoordinator<PlaybackQueue, PlaylistPlaybackLoadRequest>()

    var isLoading: Bool { coordinator.isLoading }

    func cancel() {
        coordinator.cancel()
    }

    func start(
        database: LibraryDatabase,
        request: PlaylistPlaybackLoadRequest,
        onSuccess: @escaping @MainActor (PlaybackQueue) -> Void,
        onFailure: @escaping @MainActor (PlaylistPlaybackLoadRequest, Error) -> Void
    ) {
        coordinator.start(
            database: database,
            request: request,
            load: { request, database in try request.load(from: database) },
            onSuccess: onSuccess,
            onFailure: onFailure
        )
    }
}
