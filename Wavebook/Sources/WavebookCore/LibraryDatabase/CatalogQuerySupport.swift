import Foundation
import GRDB
import SQLite3

public final class LibraryDatabaseCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var interrupt: (() -> Void)?

    public init() {}

    func install(interrupt: @escaping () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            interrupt()
        } else {
            self.interrupt = interrupt
            lock.unlock()
        }
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        interrupt?()
        lock.unlock()
    }

    func removeInterrupt() {
        lock.lock()
        interrupt = nil
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func checkCancellation() throws {
        try Task.checkCancellation()
        if isCancelled { throw CancellationError() }
    }
}

private enum CatalogCancellationContext {
    @TaskLocal static var token: LibraryDatabaseCancellationToken?
}
public enum CatalogSearchField: Sendable {
    case all
    case title
    case artist
    case album
    case genre
}

extension LibraryDatabase {
    static func checkCatalogCancellation() throws {
        try Task.checkCancellation()
        if let token = CatalogCancellationContext.token {
            try token.checkCancellation()
        }
    }

    /// Runs an operation with a task-local catalog cancellation token.
    public static func withCatalogCancellationToken<T: Sendable>(
        _ token: LibraryDatabaseCancellationToken,
        operation: @escaping @Sendable () throws -> T
    ) rethrows -> T {
        try CatalogCancellationContext.$token.withValue(token) {
            try operation()
        }
    }
    static func pageBounds(limit: Int, offset: Int) -> (limit: Int, offset: Int) {
        (min(max(limit, 0), maximumTrackPageSize), max(offset, 0))
    }

    static func pageOffset(for rank: Int, limit: Int) -> Int {
        guard limit > 0 else { return 0 }
        return (max(rank, 0) / limit) * limit
    }

    static func searchPredicate(
        query: String,
        alias: String,
        field: CatalogSearchField = .all
    ) -> (clause: String, arguments: StatementArguments) {
        let tokens = SearchNormalizer.tokens(query)
        guard !tokens.isEmpty else { return ("1 = 1", StatementArguments()) }

        switch field {
        case .all:
            var arguments = StatementArguments()
            let predicates = tokens.map { token -> String in
                if token.unicodeScalars.count >= 3 {
                    let quote = "\""
                    let matchToken = quote + token.replacingOccurrences(of: quote, with: quote + quote) + quote
                    arguments += [matchToken]
                    // Let SQLite enumerate FTS matches before fetching tracks instead of probing FTS per track.
                    return "\(alias).id IN (SELECT rowid FROM trackSearch WHERE trackSearch MATCH ?)"
                }

                arguments += ["%\(token)%"]
                return "\(alias).searchText LIKE ?"
            }
            return (predicates.joined(separator: " AND "), arguments)
        case .title:
            return normalizedSearchPredicate(tokens: tokens, column: "\(alias).titleSearchText")
        case .album:
            return normalizedSearchPredicate(tokens: tokens, column: "\(alias).albumSearchText")
        case .artist:
            let namePredicate = normalizedSearchPredicate(tokens: tokens, column: "artistNames.searchText")
            return (
                """
                EXISTS (
                    SELECT 1 FROM trackArtists
                    JOIN artistNames ON artistNames.id = trackArtists.artistId
                    WHERE trackArtists.trackId = \(alias).id AND \(namePredicate.clause)
                )
                """,
                namePredicate.arguments
            )
        case .genre:
            let namePredicate = normalizedSearchPredicate(tokens: tokens, column: "genreNames.searchText")
            return (
                """
                EXISTS (
                    SELECT 1 FROM trackGenres
                    JOIN genreNames ON genreNames.id = trackGenres.genreId
                    WHERE trackGenres.trackId = \(alias).id AND \(namePredicate.clause)
                )
                """,
                namePredicate.arguments
            )
        }
    }

    static func nameSearchPredicate(
        query: String,
        alias: String
    ) -> (clause: String, arguments: StatementArguments) {
        normalizedSearchPredicate(tokens: SearchNormalizer.tokens(query), column: "\(alias).searchText")
    }

    private static func normalizedSearchPredicate(
        tokens: [String],
        column: String
    ) -> (clause: String, arguments: StatementArguments) {
        guard !tokens.isEmpty else { return ("1 = 1", StatementArguments()) }
        var arguments = StatementArguments()
        let predicates = tokens.map { token -> String in
            arguments += ["%\(token)%"]
            return "\(column) LIKE ?"
        }
        return (predicates.joined(separator: " AND "), arguments)
    }

    static func trackScopePredicate(
        _ scope: LibraryTrackScope,
        alias: String
    ) -> (clause: String, arguments: [String]) {
        switch scope {
        case .all:
            return ("1 = 1", [])
        case let .artist(artist):
            let normalizedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedArtist.isEmpty else {
                return (
                    """
                    NOT EXISTS (
                        SELECT 1 FROM trackArtists WHERE trackArtists.trackId = \(alias).id
                    )
                    """,
                    []
                )
            }
            return (
                """
                EXISTS (
                    SELECT 1 FROM trackArtists
                    JOIN artistNames ON artistNames.id = trackArtists.artistId
                    WHERE trackArtists.trackId = \(alias).id AND artistNames.name = ?
                )
                """,
                [normalizedArtist]
            )
        case let .album(key):
            let ownerExpression = albumOwnerExpression(alias: alias)
            return (
                "\(alias).albumTitle = ? AND (\(ownerExpression)) = ?",
                [key.title, key.owner]
            )
        case let .genre(genre):
            let normalizedGenre = genre.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedGenre.isEmpty else {
                return (
                    """
                    NOT EXISTS (
                        SELECT 1 FROM trackGenres WHERE trackGenres.trackId = \(alias).id
                    )
                    """,
                    []
                )
            }
            return (
                """
                EXISTS (
                    SELECT 1 FROM trackGenres
                    JOIN genreNames ON genreNames.id = trackGenres.genreId
                    WHERE trackGenres.trackId = \(alias).id AND genreNames.name = ?
                )
                """,
                [normalizedGenre]
            )
        }
    }

    static func trackPredicate(
        scope: LibraryTrackScope,
        query: String,
        alias: String,
        field: CatalogSearchField = .all
    ) -> (clause: String, arguments: StatementArguments) {
        let search = searchPredicate(query: query, alias: alias, field: field)
        let scopePredicate = trackScopePredicate(scope, alias: alias)
        var values = search.arguments
        for argument in scopePredicate.arguments {
            values += [argument]
        }
        return ("\(search.clause) AND \(scopePredicate.clause)", values)
    }

    static func albumOwnerExpression(alias: String) -> String {
        let firstArtist = "ltrim(replace(\(alias).artistDisplay, ',', ';'), ' ;')"
        return """
        CASE
            WHEN trim(\(alias).albumArtist) <> '' THEN trim(\(alias).albumArtist)
            WHEN instr(\(firstArtist), ';') > 0 THEN trim(substr(\(firstArtist), 1, instr(\(firstArtist), ';') - 1))
            ELSE trim(\(firstArtist))
        END
        """
    }

    func readCatalog<T>(_ operation: (Database) throws -> T) throws -> T {
        let cancellation = CatalogCancellationContext.token
        do {
            return try writer.read { database in
                cancellation?.install(interrupt: {
                    if let connection = database.sqliteConnection {
                        sqlite3_interrupt(connection)
                    }
                })
                defer { cancellation?.removeInterrupt() }

                do {
                    try Task.checkCancellation()
                    if let cancellation { try cancellation.checkCancellation() }
                    let result = try operation(database)
                    try Task.checkCancellation()
                    if let cancellation { try cancellation.checkCancellation() }
                    return result
                } catch {
                    if cancellation?.isCancelled == true { throw CancellationError() }
                    throw error
                }
            }
        } catch {
            if cancellation?.isCancelled == true { throw CancellationError() }
            throw error
        }
    }

    func writeCatalog<T>(_ operation: (Database) throws -> T) throws -> T {
        let cancellation = CatalogCancellationContext.token
        do {
            return try writer.write { database in
                cancellation?.install(interrupt: {
                    if let connection = database.sqliteConnection {
                        sqlite3_interrupt(connection)
                    }
                })
                defer { cancellation?.removeInterrupt() }

                do {
                    try Self.checkCatalogCancellation()
                    let result = try operation(database)
                    try Self.checkCatalogCancellation()
                    return result
                } catch {
                    if cancellation?.isCancelled == true { throw CancellationError() }
                    throw error
                }
            }
        } catch {
            if cancellation?.isCancelled == true { throw CancellationError() }
            throw error
        }
    }

    func fetchTracksPage(
        whereClause: String,
        arguments: StatementArguments,
        limit: Int,
        offset: Int
    ) throws -> LibraryTrackPage {
        try Task.checkCancellation()
        let bounds = Self.pageBounds(limit: limit, offset: offset)
        guard bounds.limit > 0 else {
            return LibraryTrackPage(tracks: [], offset: bounds.offset, limit: bounds.limit, hasMore: false)
        }
        return try readCatalog { database in
            var queryArguments = arguments
            queryArguments += [bounds.limit + 1, bounds.offset]
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT \(Self.trackSelection)
                    FROM tracks
                    WHERE \(whereClause)
                    ORDER BY title COLLATE NOCASE, id LIMIT ? OFFSET ?
                    """,
                arguments: queryArguments
            )
            var tracks: [Track] = []
            tracks.reserveCapacity(min(rows.count, bounds.limit))
            for row in rows.prefix(bounds.limit) {
                try Task.checkCancellation()
                tracks.append(Self.track(from: row))
            }
            return LibraryTrackPage(
                tracks: tracks,
                offset: bounds.offset,
                limit: bounds.limit,
                hasMore: rows.count > bounds.limit
            )
        }
    }

    func fetchAllTracks(whereClause: String, arguments: StatementArguments) throws -> [Track] {
        try Task.checkCancellation()
        return try readCatalog { database in
            let rows = try Row.fetchCursor(
                database,
                sql: "SELECT \(Self.trackSelection) FROM tracks WHERE \(whereClause) ORDER BY title COLLATE NOCASE, id",
                arguments: arguments
            )
            var tracks: [Track] = []
            while let row = try rows.next() {
                try Task.checkCancellation()
                tracks.append(Self.track(from: row))
            }
            return tracks
        }
    }

    static func splitNames(_ value: String) -> [String] {
        MetadataParser.splitList(value).flatMap { name in
            name.split(separator: "&", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }

    static func sortArtistAlbumSummaries(_ lhs: LibraryArtistAlbumSummary, _ rhs: LibraryArtistAlbumSummary) -> Bool {
        let titleComparison = CatalogFacetOrdering.localizedNameComparison(lhs.key.title, rhs.key.title)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }
        let ownerComparison = CatalogFacetOrdering.localizedNameComparison(lhs.key.owner, rhs.key.owner)
        return ownerComparison == .orderedAscending
    }

    static func track(from row: Row) -> Track {
        Track(
            id: row["id"],
            path: row["path"],
            title: row["title"],
            artistDisplay: row["artistDisplay"],
            albumTitle: row["albumTitle"],
            albumArtist: row["albumArtist"],
            genreDisplay: row["genreDisplay"],
            duration: row["duration"],
            format: row["format"],
            hasLyrics: row["hasLyrics"],
            firstSeenAtUTC: Track.normalizedFirstSeenAtUTC(Self.date(from: row, column: "firstSeenAtUTC") ?? Date()),
            fileResourceIdentifier: row["fileResourceIdentifier"],
            fileVolumeIdentifier: row["fileVolumeIdentifier"],
            isFavorite: row["isFavorite"]
        )
    }
}
