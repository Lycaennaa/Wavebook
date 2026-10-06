import Foundation

typealias BoundedConcurrencyProvider = @Sendable () -> Int

struct BoundedTaskRunner {
    private struct RunRequest<Item: Sendable, Result: Sendable>: Sendable {
        let maximumConcurrentCount: @Sendable () -> Int
        let priority: TaskPriority?
        let cancellationCheck: @Sendable () throws -> Void
        let next: @Sendable () throws -> Item?
        let operation: @Sendable (Item) async throws -> Result
        let collectResults: Bool
        let shouldScheduleNext: @Sendable (Result) -> Bool
        let progress: (@Sendable (Int, Int) async -> Void)?
        let totalCount: Int?
    }
    private struct RunState<Result: Sendable>: Sendable {
        var activeCount = 0
        var completedCount = 0
        var results = [Result]()
        var scheduleMoreTasks = true
    }
    static func run<Item: Sendable, Result: Sendable>(
        items: [Item],
        maximumConcurrentCount: Int,
        priority: TaskPriority? = nil,
        cancellationCheck: @escaping @Sendable () throws -> Void = {},
        progress: (@Sendable (Int, Int) async -> Void)? = nil,
        operation: @escaping @Sendable (Item) async throws -> Result
    ) async throws -> [Result] {
        let iterator = BoundedTaskIterator(items)
        let request = RunRequest(
            maximumConcurrentCount: { maximumConcurrentCount },
            priority: priority,
            cancellationCheck: cancellationCheck,
            next: { iterator.next() },
            operation: operation,
            collectResults: true,
            shouldScheduleNext: { _ in true },
            progress: progress,
            totalCount: items.count
        )
        return try await runImpl(request: request)
    }

    static func run<Item: Sendable, Result: Sendable>(
        maximumConcurrentCount: Int,
        priority: TaskPriority? = nil,
        cancellationCheck: @escaping @Sendable () throws -> Void = {},
        next: @escaping @Sendable () throws -> Item?,
        operation: @escaping @Sendable (Item) async throws -> Result
    ) async throws -> [Result] {
        let request = RunRequest(
            maximumConcurrentCount: { maximumConcurrentCount },
            priority: priority,
            cancellationCheck: cancellationCheck,
            next: next,
            operation: operation,
            collectResults: true,
            shouldScheduleNext: { _ in true },
            progress: nil,
            totalCount: nil
        )
        return try await runImpl(request: request)
    }

    static func runUntilFailure<Item: Sendable, Output: Sendable>(
        items: [Item],
        maximumConcurrentCount: @escaping BoundedConcurrencyProvider,
        priority: TaskPriority? = nil,
        cancellationCheck: @escaping @Sendable () throws -> Void = {},
        operation: @escaping @Sendable (Item) async throws -> Result<Output, Error>
    ) async throws -> [(Item, Result<Output, Error>)] {
        let iterator = BoundedTaskIterator(items)
        let request = RunRequest(
            maximumConcurrentCount: maximumConcurrentCount,
            priority: priority,
            cancellationCheck: cancellationCheck,
            next: { iterator.next() },
            operation: { item in
                let result = try await operation(item)
                return (item, result)
            },
            collectResults: true,
            shouldScheduleNext: { outcome in
                switch outcome.1 {
                case .success:
                    return true
                case .failure:
                    return false
                }
            },
            progress: nil,
            totalCount: nil
        )
        return try await runImpl(request: request)
    }

    static func drain<Item: Sendable>(
        maximumConcurrentCount: @escaping BoundedConcurrencyProvider,
        priority: TaskPriority? = nil,
        cancellationCheck: @escaping @Sendable () throws -> Void = {},
        next: @escaping @Sendable () throws -> Item?,
        operation: @escaping @Sendable (Item) async throws -> Void
    ) async throws {
        let request = RunRequest(
            maximumConcurrentCount: maximumConcurrentCount,
            priority: priority,
            cancellationCheck: cancellationCheck,
            next: next,
            operation: operation,
            collectResults: false,
            shouldScheduleNext: { _ in true },
            progress: nil,
            totalCount: nil
        )
        _ = try await runImpl(request: request)
    }

    private static func runImpl<Item: Sendable, Result: Sendable>(
        request: RunRequest<Item, Result>
    ) async throws -> [Result] {
        try request.cancellationCheck()
        return try await runTaskGroup(request: request)
    }

    private static func runTaskGroup<Item: Sendable, Result: Sendable>(
        request: RunRequest<Item, Result>
    ) async throws -> [Result] {
        try await withThrowingTaskGroup(of: Result.self) { group in
            var state = RunState<Result>()
            try scheduleTasks(
                group: &group,
                request: request,
                activeCount: &state.activeCount,
                maximum: max(request.maximumConcurrentCount(), 1)
            )

            while state.activeCount > 0 {
                let result: Result?
                do {
                    result = try await group.next()
                } catch {
                    if state.scheduleMoreTasks { throw error }
                    break
                }
                guard let result else { break }
                state.activeCount -= 1
                state.completedCount += 1
                if let progress = request.progress, let totalCount = request.totalCount {
                    let interval = max(totalCount / 100, 1)
                    if state.completedCount.isMultiple(of: interval) || state.completedCount == totalCount {
                        await progress(state.completedCount, totalCount)
                    }
                }
                try processTaskResult(
                    result,
                    request: request,
                    group: &group,
                    state: &state
                )
            }
            return state.results
        }
    }

    private static func processTaskResult<Item: Sendable, Result: Sendable>(
        _ result: Result,
        request: RunRequest<Item, Result>,
        group: inout ThrowingTaskGroup<Result, Error>,
        state: inout RunState<Result>
    ) throws {
        if request.collectResults {
            state.results.append(result)
        }
        if !request.shouldScheduleNext(result) {
            state.scheduleMoreTasks = false
            group.cancelAll()
        }
        try request.cancellationCheck()
        guard state.scheduleMoreTasks else { return }
        try scheduleTasks(
            group: &group,
            request: request,
            activeCount: &state.activeCount,
            maximum: max(request.maximumConcurrentCount(), 1)
        )
    }
    private static func scheduleTasks<Item: Sendable, Result: Sendable>(
        group: inout ThrowingTaskGroup<Result, Error>,
        request: RunRequest<Item, Result>,
        activeCount: inout Int,
        maximum: Int
    ) throws {
        while activeCount < maximum {
            guard let item = try request.next() else { break }
            group.addTask(priority: request.priority) {
                try await request.operation(item)
            }
            activeCount += 1
        }
    }
}

final class BoundedConcurrencyLimit: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    init(_ value: Int) {
        self.value = value
    }

    func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func update(_ value: Int) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

private final class BoundedTaskIterator<Item: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var iterator: IndexingIterator<[Item]>

    init(_ items: [Item]) {
        iterator = items.makeIterator()
    }

    func next() -> Item? {
        lock.lock()
        defer { lock.unlock() }
        return iterator.next()
    }
}
