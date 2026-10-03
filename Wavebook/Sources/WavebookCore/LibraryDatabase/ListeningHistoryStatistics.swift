import Foundation
import GRDB
struct ListeningNameRankingConfiguration {
    let table: String
    let dimension: ListeningStatisticsDimension
}

extension LibraryDatabase {
    static func isValidListeningUTCOffset(_ seconds: Int) -> Bool {
        TimeZone(secondsFromGMT: seconds) != nil
    }

    // Song identity uses track:<liveTrackId> while the catalog row exists, and
    // snapshot:<snapshotId> after deletion nulls the foreign key. Catalog path
    // upserts keep track IDs stable across metadata rescans.
    static func listeningSongIdentityExpression(snapshotAlias: String) -> String {
        "CASE WHEN \(snapshotAlias).liveTrackId IS NOT NULL THEN 'track:' || " +
            "CAST(\(snapshotAlias).liveTrackId AS TEXT) " +
            "ELSE 'snapshot:' || CAST(\(snapshotAlias).id AS TEXT) END"
    }

    private struct ListeningRankingPredicates {
        let qualified: String
        let listened: String
        let arguments: StatementArguments
    }

    private static func listeningRankingPredicates(
        year: Int?,
        day: ListeningLocalDay?
    ) throws -> ListeningRankingPredicates {
        var qualifiedArguments: StatementArguments = []
        var listenedArguments: StatementArguments = []
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
        return ListeningRankingPredicates(
            qualified: qualified,
            listened: listened,
            arguments: qualifiedArguments + listenedArguments
        )
    }

    private static func collectRankingEntries(
        nextRow: () throws -> Row?,
        limit: Int,
        makeEntry: (Row) throws -> ListeningRankingEntry
    ) throws -> [ListeningRankingEntry] {
        var entries: [ListeningRankingEntry] = []
        while let row = try nextRow() {
            try Self.checkCatalogCancellation()
            Self.keepTopRankingEntry(try makeEntry(row), in: &entries, limit: limit)
        }
        return entries
    }
    static func songRankings(
        db database: Database,
        year: Int?,
        day: ListeningLocalDay?,
        limit: Int
    ) throws -> [ListeningRankingEntry] {
        let songIdentityExpression = Self.listeningSongIdentityExpression(snapshotAlias: "s")
        let predicates = try Self.listeningRankingPredicates(year: year, day: day)
        let cursor = try Row.fetchCursor(
            database,
            sql: """
            SELECT q.rankingID, q.displayName, q.qualifiedCount,
                   COALESCE(l.listenedSeconds, 0) AS listenedSeconds
            FROM (
                SELECT \(songIdentityExpression) AS rankingID,
                       MIN(s.title) AS displayName, COUNT(*) AS qualifiedCount
                FROM listeningEvents e
                JOIN listeningMediaSnapshots s ON s.id = e.snapshotId
                 WHERE e.qualifiedAtUTC IS NOT NULL AND (\(predicates.qualified))
                GROUP BY \(songIdentityExpression)
            ) q
            LEFT JOIN (
                SELECT \(songIdentityExpression) AS rankingID, SUM(d.actualListenedSeconds) AS listenedSeconds
                FROM listeningEvents e
                JOIN listeningMediaSnapshots s ON s.id = e.snapshotId
                JOIN listeningEventDays d ON d.eventId = e.id
                WHERE \(predicates.listened)
                GROUP BY \(songIdentityExpression)
            ) l ON l.rankingID = q.rankingID
             ORDER BY q.qualifiedCount DESC, listenedSeconds DESC,
                      q.displayName COLLATE NOCASE ASC, q.displayName ASC, q.rankingID ASC
            """,
            arguments: predicates.arguments
        )
        return try collectRankingEntries(
            nextRow: { try cursor.next() },
            limit: limit,
            makeEntry: { row in
                try Self.validatedRankingEntry(
                    id: row["rankingID"],
                    dimension: .song,
                    displayName: row["displayName"],
                    qualifiedPlayCount: row["qualifiedCount"],
                    listenedSeconds: row["listenedSeconds"]
                )
            }
        )
    }

    static func albumRankings(
        db database: Database,
        year: Int?,
        day: ListeningLocalDay?,
        limit: Int
    ) throws -> [ListeningRankingEntry] {
        let predicates = try Self.listeningRankingPredicates(year: year, day: day)
        let cursor = try Row.fetchCursor(
            database,
            sql: """
            SELECT q.albumTitle, q.albumOwner, q.qualifiedCount,
                   COALESCE(l.listenedSeconds, 0) AS listenedSeconds
            FROM (
                SELECT s.albumTitle, s.albumOwner, COUNT(*) AS qualifiedCount
                FROM listeningEvents e
                JOIN listeningMediaSnapshots s ON s.id = e.snapshotId
                 WHERE s.albumTitle <> '' AND e.qualifiedAtUTC IS NOT NULL AND (\(predicates.qualified))
                GROUP BY s.albumTitle, s.albumOwner
            ) q
            LEFT JOIN (
                SELECT s.albumTitle, s.albumOwner, SUM(d.actualListenedSeconds) AS listenedSeconds
                FROM listeningEvents e
                JOIN listeningMediaSnapshots s ON s.id = e.snapshotId
                JOIN listeningEventDays d ON d.eventId = e.id
                WHERE s.albumTitle <> '' AND (\(predicates.listened))
                GROUP BY s.albumTitle, s.albumOwner
            ) l ON l.albumTitle = q.albumTitle AND l.albumOwner = q.albumOwner
            ORDER BY q.qualifiedCount DESC, listenedSeconds DESC,
                     q.albumTitle COLLATE NOCASE ASC, q.albumTitle ASC,
                     q.albumOwner COLLATE NOCASE ASC, q.albumOwner ASC
            """,
            arguments: predicates.arguments
        )
        return try collectRankingEntries(
            nextRow: { try cursor.next() },
            limit: limit,
            makeEntry: { row in
                let title: String = row["albumTitle"]
                let owner: String = row["albumOwner"]
                return try Self.validatedRankingEntry(
                    id: Self.albumRankingID(title: title, owner: owner),
                    dimension: .album,
                    displayName: title,
                    qualifiedPlayCount: row["qualifiedCount"],
                    listenedSeconds: row["listenedSeconds"]
                )
            }
        )
    }

    static func nameRankings(
        db database: Database,
        year: Int?,
        day: ListeningLocalDay?,
        limit: Int,
        configuration: ListeningNameRankingConfiguration
    ) throws -> [ListeningRankingEntry] {
        let predicates = try Self.listeningRankingPredicates(year: year, day: day)
        let cursor = try Row.fetchCursor(
            database,
            sql: """
            SELECT q.rankingID, q.qualifiedCount,
                   COALESCE(l.listenedSeconds, 0) AS listenedSeconds
            FROM (
                SELECT a.displayValue AS rankingID, COUNT(DISTINCT e.id) AS qualifiedCount
                FROM listeningEvents e
                JOIN \(configuration.table) a ON a.snapshotId = e.snapshotId
                 WHERE e.qualifiedAtUTC IS NOT NULL AND (\(predicates.qualified))
                GROUP BY a.displayValue
            ) q
            LEFT JOIN (
                SELECT a.displayValue AS rankingID, SUM(d.actualListenedSeconds) AS listenedSeconds
                FROM listeningEvents e
                JOIN \(configuration.table) a ON a.snapshotId = e.snapshotId
                JOIN listeningEventDays d ON d.eventId = e.id
                WHERE \(predicates.listened)
                GROUP BY a.displayValue
            ) l ON l.rankingID = q.rankingID
            ORDER BY q.qualifiedCount DESC, listenedSeconds DESC, q.rankingID COLLATE NOCASE ASC, q.rankingID ASC
            """,
            arguments: predicates.arguments
        )
        return try collectRankingEntries(
            nextRow: { try cursor.next() },
            limit: limit,
            makeEntry: { row in
                let name: String = row["rankingID"]
                return try Self.validatedRankingEntry(
                    id: name,
                    dimension: configuration.dimension,
                    displayName: name,
                    qualifiedPlayCount: row["qualifiedCount"],
                    listenedSeconds: row["listenedSeconds"]
                )
            }
        )
    }

    static func validatedRankingEntry(
        id: String,
        dimension: ListeningStatisticsDimension,
        displayName: String,
        qualifiedPlayCount: Int,
        listenedSeconds: Double
    ) throws -> ListeningRankingEntry {
        guard listenedSeconds.isFinite, listenedSeconds >= 0 else {
            throw LibraryDatabaseError.invalidListeningEvent
        }
        return ListeningRankingEntry(
            id: id,
            dimension: dimension,
            displayName: displayName,
            qualifiedPlayCount: qualifiedPlayCount,
            listenedSeconds: listenedSeconds
        )
    }

    static func keepTopRankingEntry(
        _ entry: ListeningRankingEntry,
        in entries: inout [ListeningRankingEntry],
        limit: Int
    ) {
        entries.append(entry)
        entries.sort(by: Self.rankingPrecedes)
        if entries.count > limit {
            entries.removeLast()
        }
    }

    static func rankingPrecedes(_ lhs: ListeningRankingEntry, _ rhs: ListeningRankingEntry) -> Bool {
        if lhs.qualifiedPlayCount != rhs.qualifiedPlayCount {
            return lhs.qualifiedPlayCount > rhs.qualifiedPlayCount
        }
        if lhs.listenedSeconds != rhs.listenedSeconds {
            return lhs.listenedSeconds > rhs.listenedSeconds
        }
        let nameOrder = CatalogFacetOrdering.localizedNameComparison(lhs.displayName, rhs.displayName)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return CatalogFacetOrdering.localizedNameComparison(lhs.id, rhs.id) == .orderedAscending
    }

    static func albumRankingID(title: String, owner: String) -> String {
        Data("\(owner)\u{0}\(title)".utf8).base64EncodedString()
    }
}
