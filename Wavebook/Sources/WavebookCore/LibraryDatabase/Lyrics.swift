import Foundation
import GRDB

private struct LyricTrackAssociation {
    let rootID: Int64
    let path: URL
    let key: String
    let basename: String
}

struct LyricAssociationQueryEvent: Sendable {
    let keyColumn: String
    let sql: String
    let candidateLimit: Int
    let returnedCounts: [String: Int]
    let queryPlan: [String]
}

enum LyricAssociationQueryTesting {
    @TaskLocal
    static var observer: (@Sendable (LyricAssociationQueryEvent) -> Void)?

    static func record(_ event: LyricAssociationQueryEvent) {
        observer?(event)
    }
}

private enum LyricTrackAssociationIndex: Equatable {
    case basename
    case associationKey

    var column: String {
        switch self {
        case .basename: "lyricsBasename"
        case .associationKey: "lyricsKey"
        }
    }

    var indexName: String {
        switch self {
        case .basename: "tracks_lyricsBasename"
        case .associationKey: "tracks_lyricsKey"
        }
    }
}

extension LibraryDatabase {
    static let maximumLyricCandidateCount = 256
    static let maximumReconciliationTrackCount = 50_000
    static let maximumReconciliationLyricFileCount = 50_000

    private static func appendBounded(
        _ association: LyricTrackAssociation,
        for indexKey: String,
        to index: inout [String: [LyricTrackAssociation]]
    ) {
        guard index[indexKey]?.count ?? 0 < Self.maximumLyricCandidateCount + 1 else { return }
        index[indexKey, default: []].append(association)
    }

    private static func association(from row: Row) throws -> LyricTrackAssociation {
        let rootID: Int64 = row["rootId"]
        let path: String = row["path"]
        let key: String = row["lyricsKey"]
        let canonicalPath = URL(fileURLWithPath: try Self.resolveRootPath(path))
        let storedBasename: String = row["lyricsBasename"]
        let basename = storedBasename.isEmpty
            ? canonicalPath
                .deletingPathExtension()
                .lastPathComponent
                .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            : storedBasename
        return LyricTrackAssociation(rootID: rootID, path: canonicalPath, key: key, basename: basename)
    }

    private struct LyricAssociationChunkResult {
        let associations: [String: [LyricTrackAssociation]]
        let returnedCounts: [String: Int]
    }

    private static func fetchTrackAssociations(
        for keys: [String],
        index: LyricTrackAssociationIndex,
        db database: Database
    ) throws -> [String: [LyricTrackAssociation]] {
        guard !keys.isEmpty else { return [:] }
        var associationsByKey = [String: [LyricTrackAssociation]]()
        let candidateLimit = Self.maximumLyricCandidateCount + 1
        let requestedKeys = Set(keys)
        var keyStart = 0
        while keyStart < keys.count {
            try Self.checkCatalogCancellation()
            let keyEnd = min(keyStart + DatabaseQueryLimits.maximumSQLiteArgumentCount, keys.count)
            let keyChunk = Array(keys[keyStart..<keyEnd])
            let chunk = try fetchTrackAssociationChunk(
                keyChunk: keyChunk,
                index: index,
                requestedKeys: requestedKeys,
                candidateLimit: candidateLimit,
                database: database
            )
            for (key, associations) in chunk.associations {
                associationsByKey[key, default: []].append(contentsOf: associations)
            }
            keyStart = keyEnd
        }
        return associationsByKey
    }

    private static func fetchTrackAssociationChunk(
        keyChunk: [String],
        index: LyricTrackAssociationIndex,
        requestedKeys: Set<String>,
        candidateLimit: Int,
        database: Database
    ) throws -> LyricAssociationChunkResult {
        let query = trackAssociationQuery(
            keyChunk: keyChunk,
            index: index,
            candidateLimit: candidateLimit
        )
        let queryPlan: [String]
        if LyricAssociationQueryTesting.observer == nil {
            queryPlan = []
        } else {
            queryPlan = try Row.fetchAll(
                database,
                sql: "EXPLAIN QUERY PLAN \(query.sql)",
                arguments: query.arguments
            ).map { row in
                let detail: String = row["detail"]
                return detail
            }
        }
        let rows = try Row.fetchAll(database, sql: query.sql, arguments: query.arguments)
        try Self.checkCatalogCancellation()
        let result = try processTrackAssociationRows(
            rows,
            index: index,
            requestedKeys: requestedKeys
        )
        LyricAssociationQueryTesting.record(
            LyricAssociationQueryEvent(
                keyColumn: index.column,
                sql: query.sql,
                candidateLimit: candidateLimit,
                returnedCounts: result.returnedCounts,
                queryPlan: queryPlan
            )
        )
        return result
    }

    private static func trackAssociationQuery(
        keyChunk: [String],
        index: LyricTrackAssociationIndex,
        candidateLimit: Int
    ) -> (sql: String, arguments: StatementArguments) {
        let valueRows = keyChunk.map { _ in "(?)" }.joined(separator: ", ")
        let arguments = StatementArguments(keyChunk) + [candidateLimit]
        let sql = """
            WITH RECURSIVE requested(key) AS (
                VALUES \(valueRows)
            ), candidates(key, id, candidateRank) AS (
                SELECT requested.key,
                       (
                           SELECT track.id
                           FROM tracks AS track INDEXED BY \(index.indexName)
                           WHERE track.\(index.column) = requested.key
                           ORDER BY track.id
                           LIMIT 1
                       ),
                       1
                FROM requested
                UNION ALL
                SELECT candidates.key,
                       (
                           SELECT track.id
                           FROM tracks AS track INDEXED BY \(index.indexName)
                           WHERE track.\(index.column) = candidates.key
                             AND track.id > candidates.id
                           ORDER BY track.id
                           LIMIT 1
                       ),
                       candidates.candidateRank + 1
                FROM candidates
                WHERE candidates.id IS NOT NULL
                  AND candidates.candidateRank < ?
            )
            SELECT track.rootId, track.path, track.lyricsKey, track.lyricsBasename
            FROM candidates
            JOIN tracks AS track ON track.id = candidates.id
            WHERE candidates.id IS NOT NULL
            ORDER BY candidates.key, candidates.id
            """
        return (sql, arguments)
    }

    private static func processTrackAssociationRows(
        _ rows: [Row],
        index: LyricTrackAssociationIndex,
        requestedKeys: Set<String>
    ) throws -> LyricAssociationChunkResult {
        var associationsByKey = [String: [LyricTrackAssociation]]()
        var returnedCounts = [String: Int]()
        for row in rows {
            try Self.checkCatalogCancellation()
            let association = try Self.association(from: row)
            let indexKey = index == .basename ? association.basename : association.key
            returnedCounts[indexKey, default: 0] += 1
            guard !association.key.isEmpty else { continue }
            if index == .basename {
                guard requestedKeys.contains(association.basename) else { continue }
            }
            Self.appendBounded(association, for: indexKey, to: &associationsByKey)
        }
        return LyricAssociationChunkResult(
            associations: associationsByKey,
            returnedCounts: returnedCounts
        )
    }

    private struct LyricReconciliationPaths {
        let discoveredURLs: [URL]
        let discoveredPaths: Set<String>
        let preservedCanonicalPaths: Set<String>
    }

    static func reconcileLyricFiles(
        _ urls: [URL],
        rootID: Int64,
        preservedPaths: Set<String> = [],
        db database: Database
    ) throws -> Set<String> {
        guard urls.count <= Self.maximumReconciliationLyricFileCount else {
            throw LibraryDatabaseError.tooManyLyricFiles(limit: Self.maximumReconciliationLyricFileCount)
        }
        guard preservedPaths.count <= Self.maximumReconciliationLyricFileCount else {
            throw LibraryDatabaseError.tooManyLyricFiles(limit: Self.maximumReconciliationLyricFileCount)
        }
        guard let rootPath = try Self.rootPath(forID: rootID, db: database) else {
            throw LibraryDatabaseError.missingRoot(String(rootID))
        }
        let paths = try canonicalLyricPaths(
            urls: urls,
            preservedPaths: preservedPaths,
            rootPath: rootPath
        )
        let existingKeysByPath = try existingLyricKeys(
            rootID: rootID,
            paths: paths.discoveredPaths.union(paths.preservedCanonicalPaths),
            database: database
        )
        let requestedBasenames = Set(paths.discoveredURLs.map { LRCLyrics.baseNameKey(forFileURL: $0) })
        let requestedAssociationKeys = existingKeysByPath.values.reduce(into: Set<String>()) { result, keys in
            result.formUnion(keys.filter { !$0.isEmpty })
        }
        let tracksByBasename = try Self.fetchTrackAssociations(
            for: requestedBasenames.sorted(),
            index: .basename,
            db: database
        )
        let tracksByAssociationKey = try Self.fetchTrackAssociations(
            for: requestedAssociationKeys.sorted(),
            index: .associationKey,
            db: database
        )
        let entries = try buildLyricEntries(
            discoveredURLs: paths.discoveredURLs,
            preservedCanonicalPaths: paths.preservedCanonicalPaths,
            existingKeysByPath: existingKeysByPath,
            tracksByBasename: tracksByBasename,
            tracksByAssociationKey: tracksByAssociationKey
        )
        return try persistLyricEntries(entries, rootID: rootID, database: database)
    }

    private static func canonicalLyricPaths(
        urls: [URL],
        preservedPaths: Set<String>,
        rootPath: String
    ) throws -> LyricReconciliationPaths {
        var discoveredURLs: [URL] = []
        var discoveredPaths = Set<String>()
        discoveredURLs.reserveCapacity(urls.count)
        discoveredPaths.reserveCapacity(urls.count)
        for url in urls {
            try Self.checkCatalogCancellation()
            let path = try Self.canonicalPath(url.path, underRoot: rootPath)
            guard discoveredPaths.insert(path).inserted else { continue }
            discoveredURLs.append(URL(fileURLWithPath: path))
        }
        let preservedCanonicalPaths = try Set(preservedPaths.map { path in
            return try Self.canonicalPathPreservingUnresolvedLeaf(path, underRoot: rootPath)
        })
        return LyricReconciliationPaths(
            discoveredURLs: discoveredURLs,
            discoveredPaths: discoveredPaths,
            preservedCanonicalPaths: preservedCanonicalPaths
        )
    }

    private static func existingLyricKeys(
        rootID: Int64,
        paths: Set<String>,
        database: Database
    ) throws -> [String: Set<String>] {
        let relevantPaths = paths.sorted()
        var existingKeysByPath = [String: Set<String>]()
        var pathStart = 0
        while pathStart < relevantPaths.count {
            try Self.checkCatalogCancellation()
            let pathEnd = min(pathStart + DatabaseQueryLimits.maximumSQLiteArgumentCount, relevantPaths.count)
            let pathChunk = relevantPaths[pathStart..<pathEnd]
            let placeholders = pathChunk.map { _ in "?" }.joined(separator: ", ")
            var arguments = StatementArguments([rootID])
            arguments += StatementArguments(Array(pathChunk))
            let cursor = try Row.fetchCursor(
                database,
                sql: "SELECT path, lyricsKey FROM lyricFiles WHERE rootId = ? AND path IN (\(placeholders))",
                arguments: arguments
            )
            while let row = try cursor.next() {
                try Self.checkCatalogCancellation()
                let path: String = row["path"]
                existingKeysByPath[path, default: []].insert(row["lyricsKey"])
            }
            pathStart = pathEnd
        }
        return existingKeysByPath
    }

    private static func buildLyricEntries(
        discoveredURLs: [URL],
        preservedCanonicalPaths: Set<String>,
        existingKeysByPath: [String: Set<String>],
        tracksByBasename: [String: [LyricTrackAssociation]],
        tracksByAssociationKey: [String: [LyricTrackAssociation]]
    ) throws -> [String: String] {
        var entries: [String: String] = [:]
        entries.reserveCapacity(discoveredURLs.count + preservedCanonicalPaths.count)
        for standardizedURL in discoveredURLs {
            try Self.checkCatalogCancellation()
            let path = standardizedURL.path
            let existingKeys = existingKeysByPath[path, default: []]
            let basename = LRCLyrics.baseNameKey(forFileURL: standardizedURL)
            var candidates = tracksByBasename[basename, default: []]
            for key in existingKeys {
                candidates.append(contentsOf: tracksByAssociationKey[key, default: []])
            }
            var seenPaths = Set<String>()
            candidates = candidates.filter { seenPaths.insert($0.path.path).inserted }
            let existingCandidates = candidates.filter { existingKeys.contains($0.key) }
            let existingKey: String? = {
                guard existingKeys.count == 1, existingCandidates.count == 1 else { return nil }
                return existingCandidates[0].key
            }()
            let basenameCandidates = candidates.filter { $0.basename == basename }
            let lyricDirectory = standardizedURL.deletingLastPathComponent().path
            let localCandidates = basenameCandidates.filter {
                $0.path.deletingLastPathComponent().path == lyricDirectory
            }
            let key: String
            if let existingKey {
                key = existingKey
            } else if basenameCandidates.count <= Self.maximumLyricCandidateCount, localCandidates.count == 1 {
                key = localCandidates[0].key
            } else if basenameCandidates.count == 1 {
                key = basenameCandidates[0].key
            } else {
                key = standardizedURL.path
            }
            entries[path] = key
        }
        for path in preservedCanonicalPaths where entries[path] == nil {
            try Self.checkCatalogCancellation()
            guard let existingKey = existingKeysByPath[path]?.sorted().first else { continue }
            entries[path] = existingKey
        }
        return entries
    }

    private static func persistLyricEntries(
        _ entries: [String: String],
        rootID: Int64,
        database: Database
    ) throws -> Set<String> {
        let rows = try Row.fetchAll(
            database,
            sql: "SELECT path, lyricsKey FROM lyricFiles WHERE rootId = ?",
            arguments: [rootID]
        )
        var existingEntries: [String: String] = [:]
        existingEntries.reserveCapacity(rows.count)
        for row in rows {
            try Self.checkCatalogCancellation()
            let path: String = row["path"]
            let key: String = row["lyricsKey"]
            existingEntries[path] = key
        }
        var changedLyricKeys = Set<String>()
        for path in existingEntries.keys where entries[path] == nil {
            try Self.checkCatalogCancellation()
            guard let existingKey = existingEntries[path] else { continue }
            changedLyricKeys.insert(existingKey)
            try database.execute(
                sql: "DELETE FROM lyricFiles WHERE rootId = ? AND path = ?",
                arguments: [rootID, path]
            )
        }
        for path in entries.keys.sorted() {
            try Self.checkCatalogCancellation()
            guard let key = entries[path], existingEntries[path] != key else { continue }
            if let existingKey = existingEntries[path] { changedLyricKeys.insert(existingKey) }
            changedLyricKeys.insert(key)
            try database.execute(
                sql: """
                    INSERT INTO lyricFiles (rootId, path, lyricsKey) VALUES (?, ?, ?)
                    ON CONFLICT(rootId, path) DO UPDATE SET lyricsKey = excluded.lyricsKey
                    """,
                arguments: [rootID, path, key]
            )
        }
        return changedLyricKeys
    }

    /// Registers a lyric file for a track path.
    public func registerLyricFile(_ lyricURL: URL, forTrackPath trackPath: String) throws {
        try writer.write { database in
            let canonicalTrackPath = try Self.resolveRootPath(trackPath)
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT rootId, lyricsKey FROM tracks WHERE path = ?",
                arguments: [canonicalTrackPath]
            ) else {
                throw LibraryDatabaseError.missingTrack(trackPath)
            }
            let rootID: Int64 = row["rootId"]
            guard let rootPath = try Self.rootPath(forID: rootID, db: database) else {
                throw LibraryDatabaseError.missingRoot(String(rootID))
            }
            let validatedTrackPath = try Self.canonicalPath(trackPath, underRoot: rootPath)
            let validatedLyricPath = try Self.canonicalPath(lyricURL.path, underRoot: rootPath)
            let storedKey: String = row["lyricsKey"]
            let trackKey = storedKey.isEmpty ? validatedTrackPath : storedKey
            try database.execute(
                sql: """
                INSERT INTO lyricFiles (rootId, path, lyricsKey) VALUES (?, ?, ?)
                ON CONFLICT(rootId, path) DO UPDATE SET lyricsKey = excluded.lyricsKey
                """,
                arguments: [rootID, validatedLyricPath, trackKey]
            )
        }
    }

    /// Returns lyric file URLs associated with a track path.
    public func lyricFiles(forTrackPath trackPath: String) throws -> [URL] {
        try writer.read { database in
            let canonicalTrackPath = try Self.resolveRootPath(trackPath)
            guard let key = try String.fetchOne(
                database,
                sql: "SELECT lyricsKey FROM tracks WHERE path = ?",
                arguments: [canonicalTrackPath]
            ), !key.isEmpty else {
                return []
            }
            return try Self.lyricURLs(matchingKey: key, db: database)
        }
    }

    /// Returns lyric file URLs matching an association key.
    public func lyricFiles(matchingKey key: String) throws -> [URL] {
        try writer.read { database in
            try Self.lyricURLs(matchingKey: key, db: database)
        }
    }

    private static func lyricURLs(matchingKey key: String, db database: Database) throws -> [URL] {
        guard !key.isEmpty else { return [] }
        let rows = try Row.fetchAll(
            database,
            sql: "SELECT path FROM lyricFiles WHERE lyricsKey = ? ORDER BY path COLLATE NOCASE, path, id LIMIT ?",
            arguments: [key, Self.maximumLyricCandidateCount + 1]
        )
        guard rows.count <= Self.maximumLyricCandidateCount else { return [] }
        return rows.map { URL(fileURLWithPath: $0["path"]) }
    }

}
