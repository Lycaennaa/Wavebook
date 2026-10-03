import Foundation
import WavebookCore

@MainActor
final class PlaylistMutationCoordinator {
    private var task: Task<Void, Never>?
    private var generation: UUID?
    private var cancellation: LibraryDatabaseCancellationToken?

    var isRunning: Bool { task != nil }

    deinit {
        cancellation?.cancel()
        task?.cancel()
    }

    func cancel() {
        cancellation?.cancel()
        task?.cancel()
    }

    @discardableResult
    func start<Output: Sendable>(
        database: LibraryDatabase,
        operation: @escaping @Sendable (LibraryDatabase) throws -> Output,
        onSuccess: @escaping @MainActor (Output) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void,
        onFinished: @escaping @MainActor () -> Void
    ) -> Bool {
        guard task == nil else { return false }
        let generation = UUID()
        self.generation = generation
        let cancellation = LibraryDatabaseCancellationToken()
        self.cancellation = cancellation
        let worker = Task.detached(priority: .userInitiated) {
            defer { cancellation.cancel() }
            return try LibraryDatabase.withCatalogCancellationToken(cancellation) {
                try Task.checkCancellation()
                return try operation(database)
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
                guard let self, self.generation == generation else { return }
                self.finish(generation: generation)
                onFinished()
                onSuccess(result)
            } catch is CancellationError {
                guard let self, self.generation == generation else { return }
                self.finish(generation: generation)
                onFinished()
            } catch {
                guard let self, self.generation == generation else { return }
                self.finish(generation: generation)
                onFinished()
                onFailure(error)
            }
        }
        return true
    }

    private func finish(generation: UUID) {
        guard self.generation == generation else { return }
        task = nil
        self.generation = nil
        cancellation = nil
    }
}
