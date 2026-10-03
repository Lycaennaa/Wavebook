import Foundation
import WavebookCore

@MainActor
final class StatisticsPageLoader {
    typealias DatabaseProvider = () -> LibraryDatabase?
    typealias YearCompletion = @MainActor (Result<StatisticsYearSnapshot, Error>) -> Void
    typealias DayCompletion = @MainActor (Result<StatisticsDaySnapshot, Error>) -> Void
    typealias TimelineCompletion = @MainActor (Result<ListeningQualifiedPlayTimelinePage, Error>) -> Void

    private var yearGeneration = 0
    private var isActive = false
    private var yearTask: Task<Void, Never>?
    private var yearQuery: Task<StatisticsYearSnapshot, Error>?
    private var yearCancellation: LibraryDatabaseCancellationToken?
    private var dayGeneration = 0
    private var dayTask: Task<Void, Never>?
    private var dayQuery: Task<StatisticsDaySnapshot, Error>?
    private var dayCancellation: LibraryDatabaseCancellationToken?
    private var timelineGeneration = 0
    private var timelineTask: Task<Void, Never>?
    private var timelineQuery: Task<ListeningQualifiedPlayTimelinePage, Error>?
    private var timelineCancellation: LibraryDatabaseCancellationToken?

    var isActivePage: Bool { isActive }

    deinit {
        yearCancellation?.cancel()
        yearQuery?.cancel()
        yearTask?.cancel()
        dayCancellation?.cancel()
        dayQuery?.cancel()
        dayTask?.cancel()
        timelineCancellation?.cancel()
        timelineQuery?.cancel()
        timelineTask?.cancel()
    }

    func activate() {
        isActive = true
    }

    func deactivate() {
        isActive = false
        invalidateYearLoad()
        cancelDayAndTimeline()
    }

    @discardableResult
    func loadYear(
        year: Int,
        databaseProvider: @escaping DatabaseProvider,
        completion: @escaping YearCompletion
    ) -> Bool {
        invalidateYearLoad()
        guard isActive, let database = databaseProvider() else { return false }

        let generation = yearGeneration
        let cancellation = LibraryDatabaseCancellationToken()
        let query = Task.detached(priority: .userInitiated) {
            try LibraryDatabase.withCatalogCancellationToken(cancellation) {
                try Task.checkCancellation()
                let snapshot = try Self.loadYear(database: database, year: year)
                try Task.checkCancellation()
                return snapshot
            }
        }
        yearCancellation = cancellation
        yearQuery = query
        yearTask = Task { [weak self, query, cancellation] in
            defer {
                cancellation.cancel()
                query.cancel()
            }

            do {
                let snapshot = try await withTaskCancellationHandler(operation: {
                    try await query.value
                }, onCancel: {
                    cancellation.cancel()
                    query.cancel()
                })
                try Task.checkCancellation()
                guard let self, self.isActive, generation == self.yearGeneration else { return }
                self.yearCancellation = nil
                self.yearQuery = nil
                self.yearTask = nil
                completion(.success(snapshot))
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.isActive, generation == self.yearGeneration else { return }
                self.yearCancellation = nil
                self.yearQuery = nil
                self.yearTask = nil
                completion(.failure(error))
            }
        }
        return true
    }

    @discardableResult
    func loadDay(
        day: ListeningLocalDay,
        databaseProvider: @escaping DatabaseProvider,
        completion: @escaping DayCompletion
    ) -> Bool {
        invalidateDayLoad()
        guard isActive, let database = databaseProvider() else { return false }

        let generation = dayGeneration
        let cancellation = LibraryDatabaseCancellationToken()
        let query = Task.detached(priority: .userInitiated) {
            try LibraryDatabase.withCatalogCancellationToken(cancellation) {
                try Task.checkCancellation()
                let snapshot = try Self.loadDay(database: database, day: day)
                try Task.checkCancellation()
                return snapshot
            }
        }
        dayCancellation = cancellation
        dayQuery = query
        dayTask = Task { [weak self, query, cancellation] in
            defer {
                cancellation.cancel()
                query.cancel()
            }

            do {
                let snapshot = try await withTaskCancellationHandler(operation: {
                    try await query.value
                }, onCancel: {
                    cancellation.cancel()
                    query.cancel()
                })
                try Task.checkCancellation()
                guard let self, self.isActive, generation == self.dayGeneration else { return }
                self.dayCancellation = nil
                self.dayQuery = nil
                self.dayTask = nil
                completion(.success(snapshot))
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.isActive, generation == self.dayGeneration else { return }
                self.dayCancellation = nil
                self.dayQuery = nil
                self.dayTask = nil
                completion(.failure(error))
            }
        }
        return true
    }

    @discardableResult
    func loadTimelinePage(
        day: ListeningLocalDay,
        cursor: ListeningTimelineCursor?,
        databaseProvider: @escaping DatabaseProvider,
        completion: @escaping TimelineCompletion
    ) -> Bool {
        invalidateTimelineLoad()
        guard isActive, let database = databaseProvider() else { return false }

        let generation = timelineGeneration
        let cancellation = LibraryDatabaseCancellationToken()
        let query = Task.detached(priority: .userInitiated) {
            try LibraryDatabase.withCatalogCancellationToken(cancellation) {
                try Task.checkCancellation()
                let page = try database.qualifiedPlayTimeline(day: day, cursor: cursor)
                try Task.checkCancellation()
                return page
            }
        }
        timelineCancellation = cancellation
        timelineQuery = query
        timelineTask = Task { [weak self, query, cancellation] in
            defer {
                cancellation.cancel()
                query.cancel()
            }

            do {
                let page = try await withTaskCancellationHandler(operation: {
                    try await query.value
                }, onCancel: {
                    cancellation.cancel()
                    query.cancel()
                })
                try Task.checkCancellation()
                guard let self, self.isActive, generation == self.timelineGeneration else { return }
                self.timelineCancellation = nil
                self.timelineQuery = nil
                self.timelineTask = nil
                completion(.success(page))
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.isActive, generation == self.timelineGeneration else { return }
                self.timelineCancellation = nil
                self.timelineQuery = nil
                self.timelineTask = nil
                completion(.failure(error))
            }
        }
        return true
    }

    func cancelDayAndTimeline() {
        invalidateDayLoad()
        invalidateTimelineLoad()
    }

    private func invalidateYearLoad() {
        yearGeneration += 1
        yearCancellation?.cancel()
        yearQuery?.cancel()
        yearTask?.cancel()
        yearCancellation = nil
        yearQuery = nil
        yearTask = nil
    }

    private func invalidateDayLoad() {
        dayGeneration += 1
        dayCancellation?.cancel()
        dayQuery?.cancel()
        dayTask?.cancel()
        dayCancellation = nil
        dayQuery = nil
        dayTask = nil
    }

    private func invalidateTimelineLoad() {
        timelineGeneration += 1
        timelineCancellation?.cancel()
        timelineQuery?.cancel()
        timelineTask?.cancel()
        timelineCancellation = nil
        timelineQuery = nil
        timelineTask = nil
    }

    nonisolated private static func loadYear(
        database: LibraryDatabase,
        year: Int
    ) throws -> StatisticsYearSnapshot {
        try Task.checkCancellation()
        var rankings: [ListeningStatisticsDimension: [ListeningRankingEntry]] = [:]
        for dimension in ListeningStatisticsDimension.allCases {
            rankings[dimension] = try database.listeningRankings(dimension: dimension, year: year, day: nil)
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        let summary = try database.listeningStatisticsSummary(year: year, day: nil)
        try Task.checkCancellation()
        let lifetime = try database.listeningStatisticsSummary(year: nil, day: nil)
        try Task.checkCancellation()
        let heatmap = try database.listeningHeatmap(year: year)
        try Task.checkCancellation()
        let skippedSongs = try database.listeningSkippedSongs(year: year, day: nil)
        return StatisticsYearSnapshot(
            year: year,
            summary: summary,
            lifetime: lifetime,
            heatmap: heatmap,
            rankings: rankings,
            skippedSongs: skippedSongs
        )
    }

    nonisolated private static func loadDay(
        database: LibraryDatabase,
        day: ListeningLocalDay
    ) throws -> StatisticsDaySnapshot {
        try Task.checkCancellation()
        var rankings: [ListeningStatisticsDimension: [ListeningRankingEntry]] = [:]
        for dimension in ListeningStatisticsDimension.allCases {
            rankings[dimension] = try database.listeningRankings(dimension: dimension, year: nil, day: day)
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        let summary = try database.listeningStatisticsSummary(year: nil, day: day)
        try Task.checkCancellation()
        let skippedSongs = try database.listeningSkippedSongs(year: nil, day: day)
        return StatisticsDaySnapshot(
            day: day,
            summary: summary,
            rankings: rankings,
            skippedSongs: skippedSongs
        )
    }
}
