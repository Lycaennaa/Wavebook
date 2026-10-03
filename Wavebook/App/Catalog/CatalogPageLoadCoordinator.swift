import Foundation
import WavebookCore

@MainActor
final class CatalogPageLoadCoordinator {
    private var task: Task<Void, Never>?
    private var generation: UUID?

    var isLoading: Bool {
        task != nil
    }

    deinit {
        task?.cancel()
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation = nil
    }

    func start(
        database: LibraryDatabase,
        request: CatalogPageRequest,
        onSuccess: @escaping @MainActor (CatalogPageResult) -> Void,
        onFailure: @escaping @MainActor (CatalogPageContext, Error) -> Void
    ) {
        cancel()
        let generation = UUID()
        self.generation = generation

        let cancellation = LibraryDatabaseCancellationToken()
        let worker = Task.detached(priority: .userInitiated) {
            defer { cancellation.cancel() }
            return try LibraryDatabase.withCatalogCancellationToken(cancellation) {
                try Task.checkCancellation()
                let result = try request.load(from: database)
                try Task.checkCancellation()
                return result
            }
        }

        task = Task { [weak self] in
            defer {
                if let self, self.generation == generation {
                    self.task = nil
                    self.generation = nil
                }
            }

            do {
                let result = try await withTaskCancellationHandler(operation: {
                    try await worker.value
                }, onCancel: {
                    cancellation.cancel()
                    worker.cancel()
                })
                try Task.checkCancellation()
                guard let self, self.generation == generation else { return }
                onSuccess(result)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.generation == generation else { return }
                onFailure(request.context, error)
            }
        }
    }
}
