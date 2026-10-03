import Foundation
import GRDB

extension LibraryDatabase {
    /// Returns all tracks matching a query.
    public func tracks(matching query: String = "") throws -> [Track] {
        try allTracks(matching: query)
    }

    /// Returns a page of all tracks with an explicit limit.
    public func tracks(matching query: String = "", limit: Int, offset: Int = 0) throws -> [Track] {
        try trackPage(matching: query, limit: limit, offset: offset).tracks
    }

    /// Returns the first page of all tracks.
    public func trackPage(
        matching query: String = "",
        limit: Int = LibraryDatabase.defaultTrackPageSize,
        offset: Int = 0
    ) throws -> LibraryTrackPage {
        try trackPage(for: .all, matching: query, limit: limit, offset: offset)
    }

    /// Returns a page of tracks for a library scope.
    public func trackPage(
        for scope: LibraryTrackScope,
        matching query: String = "",
        limit: Int = LibraryDatabase.defaultTrackPageSize,
        offset: Int = 0
    ) throws -> LibraryTrackPage {
        let predicate = Self.trackPredicate(scope: scope, query: query, alias: "tracks")
        return try fetchTracksPage(
            whereClause: predicate.clause,
            arguments: predicate.arguments,
            limit: limit,
            offset: offset
        )
    }
    /// Returns a page of tracks matching the selected catalog field.
    public func trackPage(
        for scope: LibraryTrackScope,
        matching query: String = "",
        searchField: CatalogSearchField,
        limit: Int = LibraryDatabase.defaultTrackPageSize,
        offset: Int = 0
    ) throws -> LibraryTrackPage {
        let predicate = Self.trackPredicate(scope: scope, query: query, alias: "tracks", field: searchField)
        return try fetchTracksPage(
            whereClause: predicate.clause,
            arguments: predicate.arguments,
            limit: limit,
            offset: offset
        )
    }

    /// Visits matching tracks in bounded pages without aggregating the result.
    /// Return `false` from the callback to stop reading.
    public func forEachTrackPage(
        for scope: LibraryTrackScope,
        matching query: String = "",
        limit: Int = LibraryDatabase.defaultTrackPageSize,
        _ body: ([Track]) throws -> Bool
    ) throws {
        try forEachTrackPage(
            for: scope,
            matching: query,
            searchField: .all,
            limit: limit,
            body
        )
    }

    /// Visits matching tracks in bounded pages for one metadata field.
    /// Return `false` from the callback to stop reading.
    public func forEachTrackPage(
        for scope: LibraryTrackScope,
        matching query: String = "",
        searchField: CatalogSearchField,
        limit: Int = LibraryDatabase.defaultTrackPageSize,
        _ body: ([Track]) throws -> Bool
    ) throws {
        let predicate = Self.trackPredicate(scope: scope, query: query, alias: "tracks", field: searchField)
        let pageSize = min(max(limit, 1), LibraryDatabase.maximumTrackPageSize)
        try readCatalog { database in
            let sql = [
                "SELECT \(Self.trackSelection)",
                "FROM tracks",
                "WHERE \(predicate.clause)",
                "ORDER BY title COLLATE NOCASE, id"
            ].joined(separator: " ")
            let rows = try Row.fetchCursor(
                database,
                sql: sql,
                arguments: predicate.arguments
            )
            var page: [Track] = []
            page.reserveCapacity(pageSize)
            while let row = try rows.next() {
                try Task.checkCancellation()
                page.append(Self.track(from: row))
                guard page.count == pageSize else { continue }
                if try !body(page) { return }
                page.removeAll(keepingCapacity: true)
            }
            if !page.isEmpty {
                _ = try body(page)
            }
        }
    }

    /// Returns unpaged tracks for a library scope.
    public func unpagedTracks(for scope: LibraryTrackScope, matching query: String = "") throws -> [Track] {
        let predicate = Self.trackPredicate(scope: scope, query: query, alias: "tracks")
        return try fetchAllTracks(whereClause: predicate.clause, arguments: predicate.arguments)
    }

    /// Returns all tracks matching a query.
    public func allTracks(matching query: String = "") throws -> [Track] {
        try unpagedTracks(for: .all, matching: query)
    }

    /// Returns tracks filtered by an artist.
    public func tracks(artist: String, matching query: String = "") throws -> [Track] {
        try unpagedTracks(for: .artist(artist), matching: query)
    }

    /// Returns a page of tracks for an artist.
    public func tracks(artist: String, matching query: String = "", limit: Int, offset: Int = 0) throws -> [Track] {
        try trackPage(for: .artist(artist), matching: query, limit: limit, offset: offset).tracks
    }

    /// Returns all tracks filtered by an artist.
    public func allTracks(artist: String, matching query: String = "") throws -> [Track] {
        try unpagedTracks(for: .artist(artist), matching: query)
    }

    /// Returns tracks filtered by an album.
    public func tracks(album key: AlbumKey, matching query: String = "") throws -> [Track] {
        try unpagedTracks(for: .album(key), matching: query)
    }

    /// Returns a page of tracks for an album.
    public func tracks(
        album key: AlbumKey,
        matching query: String = "",
        limit: Int,
        offset: Int = 0
    ) throws -> [Track] {
        try trackPage(for: .album(key), matching: query, limit: limit, offset: offset).tracks
    }

    /// Returns all tracks filtered by an album.
    public func allTracks(album key: AlbumKey, matching query: String = "") throws -> [Track] {
        try unpagedTracks(for: .album(key), matching: query)
    }

    /// Returns tracks filtered by a genre.
    public func tracks(genre: String, matching query: String = "") throws -> [Track] {
        try unpagedTracks(for: .genre(genre), matching: query)
    }

    /// Returns a page of tracks for a genre.
    public func tracks(genre: String, matching query: String = "", limit: Int, offset: Int = 0) throws -> [Track] {
        try trackPage(for: .genre(genre), matching: query, limit: limit, offset: offset).tracks
    }

    /// Returns all tracks for a genre.
    public func allTracks(genre: String, matching query: String = "") throws -> [Track] {
        try unpagedTracks(for: .genre(genre), matching: query)
    }
}
