import Foundation
import GRDB

private extension LibraryDatabase {
    static func uniqueTrackIDs(_ trackIDs: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        return trackIDs.filter { seen.insert($0).inserted }
    }

    static func toggleFavoriteBatch(
        trackIDs: [Int64],
        db database: Database
    ) throws -> [PlaylistFavoriteChange] {
        let uniqueIDs = uniqueTrackIDs(trackIDs)
        var currentStates: [(id: Int64, isFavorite: Bool)] = []
        currentStates.reserveCapacity(uniqueIDs.count)
        for trackID in uniqueIDs {
            try checkCatalogCancellation()
            guard let isFavorite = try Bool.fetchOne(
                database,
                sql: "SELECT isFavorite FROM tracks WHERE id = ?",
                arguments: [trackID]
            ) else {
                throw LibraryDatabaseError.missingTrack(String(trackID))
            }
            currentStates.append((trackID, isFavorite))
        }
        var changes: [PlaylistFavoriteChange] = []
        changes.reserveCapacity(currentStates.count)
        for state in currentStates {
            try checkCatalogCancellation()
            let newValue = !state.isFavorite
            try database.execute(
                sql: "UPDATE tracks SET isFavorite = ? WHERE id = ?",
                arguments: [newValue ? 1 : 0, state.id]
            )
            changes.append(PlaylistFavoriteChange(trackID: state.id, isFavorite: newValue))
        }
        return changes
    }

    static func setFavoriteBatch(
        trackIDs: [Int64],
        isFavorite: Bool,
        db database: Database
    ) throws -> [PlaylistFavoriteChange] {
        let uniqueIDs = uniqueTrackIDs(trackIDs)
        for trackID in uniqueIDs {
            try checkCatalogCancellation()
            guard try Int64.fetchOne(
                database,
                sql: "SELECT id FROM tracks WHERE id = ?",
                arguments: [trackID]
            ) != nil else {
                throw LibraryDatabaseError.missingTrack(String(trackID))
            }
        }
        for trackID in uniqueIDs {
            try checkCatalogCancellation()
            try database.execute(
                sql: "UPDATE tracks SET isFavorite = ? WHERE id = ?",
                arguments: [isFavorite ? 1 : 0, trackID]
            )
        }
        return uniqueIDs.map { PlaylistFavoriteChange(trackID: $0, isFavorite: isFavorite) }
    }
}

extension LibraryDatabase {
    /// Toggles one live track's favorite state atomically.
    @discardableResult
    public func toggleFavorite(trackID: Int64) throws -> Bool {
        let changes = try writeCatalog { database in
            try Self.toggleFavoriteBatch(trackIDs: [trackID], db: database)
        }
        guard let change = changes.first else {
            throw LibraryDatabaseError.missingTrack(String(trackID))
        }
        return change.isFavorite
    }

    /// Toggles many live tracks in one transaction, preserving input order.
    @discardableResult
    public func toggleFavorite(trackIDs: [Int64]) throws -> [PlaylistFavoriteChange] {
        try writeCatalog { database in
            try Self.toggleFavoriteBatch(trackIDs: trackIDs, db: database)
        }
    }

    /// Compatibility spelling for a multi-track favorite toggle.
    @discardableResult
    public func toggleFavorites(trackIDs: [Int64]) throws -> [PlaylistFavoriteChange] {
        try toggleFavorite(trackIDs: trackIDs)
    }

    /// Sets one live track's favorite state atomically.
    @discardableResult
    public func setFavorite(trackID: Int64, isFavorite: Bool) throws -> PlaylistFavoriteChange {
        let changes = try writeCatalog { database in
            try Self.setFavoriteBatch(trackIDs: [trackID], isFavorite: isFavorite, db: database)
        }
        guard let change = changes.first else {
            throw LibraryDatabaseError.missingTrack(String(trackID))
        }
        return change
    }

    /// Sets many live tracks' favorite state in one transaction.
    @discardableResult
    public func setFavorite(
        trackIDs: [Int64],
        isFavorite: Bool
    ) throws -> [PlaylistFavoriteChange] {
        try writeCatalog { database in
            try Self.setFavoriteBatch(trackIDs: trackIDs, isFavorite: isFavorite, db: database)
        }
    }
}
