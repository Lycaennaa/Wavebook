import Foundation
import GRDB

extension LibraryDatabase {
    /// Returns local years containing qualified plays or skips in the current timezone.
    public func availableListeningYears() throws -> [Int] {
        try readCatalog { database in
            let rows = try Row.fetchCursor(database, sql: """
                SELECT qualifiedAtUTC AS timestamp
                FROM listeningEvents
                WHERE qualifiedAtUTC IS NOT NULL
                UNION ALL
                SELECT skipAtUTC AS timestamp
                FROM listeningEvents
                WHERE skipAtUTC IS NOT NULL
                """)
            var years = Set<Int>()
            while let row = try rows.next() {
                try Self.checkCatalogCancellation()
                guard let date = Self.date(from: row, column: "timestamp"),
                      let day = ListeningLocalDay(date: date, timeZone: .current) else {
                    throw LibraryDatabaseError.invalidListeningEvent
                }
                years.insert(day.year)
            }
            return years.sorted()
        }
    }

    private struct ListeningStatisticsPredicates {
        let qualified: String
        let listened: String
        let skip: String
        let arguments: StatementArguments
    }

    /// Returns listening totals for a year or day scope.
    public func listeningStatisticsSummary(
        year: Int? = nil,
        day: ListeningLocalDay? = nil
    ) throws -> ListeningStatisticsSummary {
        try Self.validateListeningScope(year: year, day: day)
        return try readCatalog { database in
            try Self.listeningStatisticsSummary(year: year, day: day, database: database)
        }
    }

    private static func listeningStatisticsSummary(
        year: Int?,
        day: ListeningLocalDay?,
        database: Database
    ) throws -> ListeningStatisticsSummary {
        let predicates = try listeningStatisticsPredicates(year: year, day: day)
        let row = try listeningStatisticsRow(predicates: predicates, database: database)
        guard let row else { return ListeningStatisticsSummary() }
        let listenedSeconds: Double = row["listenedSeconds"]
        guard listenedSeconds.isFinite, listenedSeconds >= 0 else {
            throw LibraryDatabaseError.invalidListeningEvent
        }
        return ListeningStatisticsSummary(
            qualifiedPlayCount: row["qualifiedPlayCount"],
            listenedSeconds: listenedSeconds,
            uniqueSongCount: row["uniqueSongCount"],
            uniqueArtistCount: row["uniqueArtistCount"],
            skipCount: row["skipCount"]
        )
    }

    private static func listeningStatisticsPredicates(
        year: Int?,
        day: ListeningLocalDay?
    ) throws -> ListeningStatisticsPredicates {
        var qualifiedArguments: StatementArguments = []
        var listenedArguments: StatementArguments = []
        var skipArguments: StatementArguments = []
        let qualified = try Self.listeningScopePredicate(
            column: "e.qualifiedAtUTC",
            year: year,
            day: day,
            arguments: &qualifiedArguments
        )
        let listened = try Self.listeningScopePredicate(
            column: "e.qualifiedAtUTC",
            year: year,
            day: day,
            arguments: &listenedArguments
        )
        let skip = try Self.listeningScopePredicate(
            column: "e.skipAtUTC",
            year: year,
            day: day,
            arguments: &skipArguments
        )
        var arguments = qualifiedArguments
        arguments += listenedArguments
        arguments += qualifiedArguments
        arguments += qualifiedArguments
        arguments += skipArguments
        return ListeningStatisticsPredicates(
            qualified: qualified,
            listened: listened,
            skip: skip,
            arguments: arguments
        )
    }

    private static func listeningStatisticsRow(
        predicates: ListeningStatisticsPredicates,
        database: Database
    ) throws -> Row? {
        let songIdentityExpression = Self.listeningSongIdentityExpression(snapshotAlias: "s")
        return try Row.fetchOne(
            database,
            sql: """
            SELECT
                (SELECT COUNT(*) FROM listeningEvents e WHERE e.qualifiedAtUTC IS NOT NULL AND (
                    \(predicates.qualified)
                )) AS qualifiedPlayCount,
                (SELECT COALESCE(SUM(d.actualListenedSeconds), 0)
                 FROM listeningEvents e
                 JOIN listeningEventDays d ON d.eventId = e.id
                 WHERE \(predicates.listened)) AS listenedSeconds,
                (SELECT COUNT(DISTINCT \(songIdentityExpression))
                 FROM listeningEvents e
                 JOIN listeningMediaSnapshots s ON s.id = e.snapshotId
                  WHERE e.qualifiedAtUTC IS NOT NULL AND (\(predicates.qualified))) AS uniqueSongCount,
                (SELECT COUNT(DISTINCT a.displayValue)
                 FROM listeningEvents e
                 JOIN listeningSnapshotArtists a ON a.snapshotId = e.snapshotId
                  WHERE e.qualifiedAtUTC IS NOT NULL AND (\(predicates.qualified))) AS uniqueArtistCount,
                 (SELECT COUNT(*) FROM listeningEvents e WHERE e.skipAtUTC IS NOT NULL AND (
                     \(predicates.skip)
                 )) AS skipCount
            """,
            arguments: predicates.arguments
        )
    }

    /// Returns a calendar heatmap of qualified plays for a year.
    public func listeningHeatmap(year: Int) throws -> [ListeningHeatmapDay] {
        try Self.validateListeningScope(year: year, day: nil)
        return try readCatalog { database in
            let startDay = try Self.listeningYearStart(year)
            let endDay = try Self.listeningYearEnd(year)
            guard let range = Self.currentTimeZoneDateRange(from: startDay, through: endDay) else {
                throw LibraryDatabaseError.invalidListeningYear(year)
            }
            let rows = try Row.fetchCursor(
                database,
                sql: """
                    SELECT qualifiedAtUTC AS timestamp
                    FROM listeningEvents
                    WHERE qualifiedAtUTC >= ? AND qualifiedAtUTC < ?
                    """,
                arguments: [range.start, range.endExclusive]
            )
            var counts: [String: Int] = [:]
            while let row = try rows.next() {
                try Self.checkCatalogCancellation()
                guard let date = Self.date(from: row, column: "timestamp"),
                      let day = ListeningLocalDay(date: date, timeZone: .current) else {
                    throw LibraryDatabaseError.invalidListeningEvent
                }
                counts[day.rawValue, default: 0] += 1
            }

            var result: [ListeningHeatmapDay] = []
            for month in 1...12 {
                for date in 1...31 {
                    try Self.checkCatalogCancellation()
                    guard let day = ListeningLocalDay(year: year, month: month, day: date) else { continue }
                    result.append(ListeningHeatmapDay(day: day, qualifiedPlayCount: counts[day.rawValue] ?? 0))
                }
            }
            return result
        }
    }

    /// Returns ranked listening entries for a dimension and scope.
    public func listeningRankings(
        dimension: ListeningStatisticsDimension,
        year: Int? = nil,
        day: ListeningLocalDay? = nil,
        limit: Int = 10
    ) throws -> [ListeningRankingEntry] {
        try Self.validateListeningScope(year: year, day: day)
        let limit = min(max(limit, 0), 10)
        guard limit > 0 else { return [] }
        return try readCatalog { database in
            switch dimension {
            case .song:
                return try Self.songRankings(db: database, year: year, day: day, limit: limit)
            case .album:
                return try Self.albumRankings(db: database, year: year, day: day, limit: limit)
            case .artist:
                return try Self.nameRankings(
                    db: database,
                    year: year,
                    day: day,
                    limit: limit,
                    configuration: ListeningNameRankingConfiguration(
                        table: "listeningSnapshotArtists",
                        dimension: .artist
                    )
                )
            case .genre:
                return try Self.nameRankings(
                    db: database,
                    year: year,
                    day: day,
                    limit: limit,
                    configuration: ListeningNameRankingConfiguration(
                        table: "listeningSnapshotGenres",
                        dimension: .genre
                    )
                )
            }
        }
    }

    /// Returns songs ordered by skip count for a scope.
    public func listeningSkippedSongs(
        year: Int? = nil,
        day: ListeningLocalDay? = nil,
        limit: Int = 10
    ) throws -> [ListeningSkippedSong] {
        try Self.validateListeningScope(year: year, day: day)
        let limit = min(max(limit, 0), 10)
        guard limit > 0 else { return [] }
        return try readCatalog { database in
            var arguments: StatementArguments = []
            let predicate = try Self.listeningScopePredicate(
                column: "e.skipAtUTC",
                year: year,
                day: day,
                arguments: &arguments
            )
            arguments += [limit]
            return try Row.fetchAll(
                database,
                sql: """
                SELECT s.id AS snapshotID, s.title, s.artistDisplay, s.albumTitle, COUNT(*) AS skipCount
                FROM listeningEvents e
                JOIN listeningMediaSnapshots s ON s.id = e.snapshotId
                 WHERE e.skipAtUTC IS NOT NULL AND (\(predicate))
                GROUP BY s.id, s.title, s.artistDisplay, s.albumTitle
                ORDER BY skipCount DESC, s.title COLLATE NOCASE ASC, s.id ASC
                LIMIT ?
                """,
                arguments: arguments
            ).map { row in
                ListeningSkippedSong(
                    snapshotID: row["snapshotID"],
                    title: row["title"],
                    artistDisplay: row["artistDisplay"],
                    albumTitle: row["albumTitle"],
                    skipCount: row["skipCount"]
                )
            }
        }
    }

    /// Returns a cursor-paginated timeline of qualified plays.
    public func qualifiedPlayTimeline(
        day: ListeningLocalDay,
        cursor: ListeningTimelineCursor? = nil,
        limit: Int = 100
    ) throws -> ListeningQualifiedPlayTimelinePage {
        try Self.validateListeningScope(year: nil, day: day)
        let limit = min(max(limit, 1), 100)
        return try readCatalog { database in
            try Self.qualifiedPlayTimeline(
                day: day,
                cursor: cursor,
                limit: limit,
                database: database
            )
        }
    }

    private static func qualifiedPlayTimeline(
        day: ListeningLocalDay,
        cursor: ListeningTimelineCursor?,
        limit: Int,
        database: Database
    ) throws -> ListeningQualifiedPlayTimelinePage {
        guard let range = Self.currentTimeZoneDateRange(for: day) else {
            throw LibraryDatabaseError.invalidListeningDay(day.rawValue)
        }
        let timeZone = TimeZone.current
        var arguments: StatementArguments = [range.start, range.endExclusive]
        var cursorPredicate = ""
        if let cursor {
            cursorPredicate = "AND (e.qualifiedAtUTC > ? OR (e.qualifiedAtUTC = ? AND e.id > ?))"
            guard let cursorTimestamp = Self.databaseTimestamp(cursor.qualifiedAtUTC) else {
                throw LibraryDatabaseError.invalidListeningEvent
            }
            arguments += [cursorTimestamp, cursorTimestamp, cursor.eventID.uuidString]
        }
        arguments += [limit + 1]
        let rows = try Row.fetchAll(
            database,
            sql: """
            SELECT e.id, e.qualifiedAtUTC,
                   s.id AS snapshotID, s.title, s.artistDisplay, s.albumTitle
            FROM listeningEvents e
            JOIN listeningMediaSnapshots s ON s.id = e.snapshotId
            WHERE e.qualifiedAtUTC >= ? AND e.qualifiedAtUTC < ?
              AND e.qualifiedAtUTC IS NOT NULL \(cursorPredicate)
            ORDER BY e.qualifiedAtUTC ASC, e.id ASC
            LIMIT ?
            """,
            arguments: arguments
        )
        let hasNext = rows.count > limit
        let pageRows = hasNext ? Array(rows.prefix(limit)) : rows
        let entries = try pageRows.map { try Self.qualifiedTimelineEntry(row: $0, timeZone: timeZone) }
        let nextCursor = hasNext
            ? entries.last.flatMap {
                ListeningTimelineCursor(qualifiedAtUTC: $0.qualifiedAtUTC, eventID: $0.eventID)
            }
            : nil
        return ListeningQualifiedPlayTimelinePage(entries: entries, nextCursor: nextCursor)
    }

    private static func qualifiedTimelineEntry(
        row: Row,
        timeZone: TimeZone
    ) throws -> ListeningQualifiedPlayTimelineEntry {
        try Self.checkCatalogCancellation()
        guard
            let eventID = UUID(uuidString: row["id"]),
            let qualifiedAtUTC = Self.date(from: row, column: "qualifiedAtUTC"),
            let localDay = ListeningLocalDay(date: qualifiedAtUTC, timeZone: timeZone)
        else {
            throw LibraryDatabaseError.invalidListeningEvent
        }
        return ListeningQualifiedPlayTimelineEntry(
            eventID: eventID,
            qualifiedAtUTC: qualifiedAtUTC,
            localDay: localDay,
            utcOffsetSeconds: timeZone.secondsFromGMT(for: qualifiedAtUTC),
            snapshotID: row["snapshotID"],
            title: row["title"],
            artistDisplay: row["artistDisplay"],
            albumTitle: row["albumTitle"]
        )
    }
}
