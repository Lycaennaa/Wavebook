import Foundation
import GRDB

private enum PlaylistNamePolicy {
    static let reservedNames = Set(
        SystemPlaylistKind.allCases.map { normalizedKey($0.displayName) }
    )

    static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedKey(_ name: String) -> String {
        trimmed(name)
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

extension LibraryDatabase {
    static let playlistSelection = "id, name, kind, createdAtUTC, rulesJSON, sortField, sortDescending"

    static func fetchPlaylistRow(id: Int64, db database: Database) throws -> Row? {
        try Row.fetchOne(
            database,
            sql: "SELECT \(playlistSelection) FROM playlists WHERE id = ?",
            arguments: [id]
        )
    }
}

extension LibraryDatabase {
    /// Validates a playlist definition before persistence.
    public static func validatePlaylistDefinition(_ definition: PlaylistDefinition) throws {
        switch definition {
        case .manual:
            return
        case let .smart(rulesJSON, _, _):
            do {
                _ = try PlaylistRuleValidator.parse(rulesJSON)
            } catch let error as PlaylistRuleValidationError {
                throw LibraryDatabaseError.invalidSmartPlaylistRules(error)
            }
        }
    }
    /// Validates a user-playlist definition before persistence.
    public func validatePlaylist(definition: PlaylistDefinition) throws {
        try Self.validatePlaylistDefinition(definition)
    }

    static func playlistName(
        _ name: String,
        excludingID: Int64?,
        db database: Database
    ) throws -> String {
        let trimmed = PlaylistNamePolicy.trimmed(name)
        guard !trimmed.isEmpty else { throw LibraryDatabaseError.invalidPlaylistName }
        let key = PlaylistNamePolicy.normalizedKey(trimmed)
        let isReservedName = PlaylistNamePolicy.reservedNames.contains(key)
        let preservesExistingReservedName: Bool
        if isReservedName,
           let excludingID,
           let existingName = try String.fetchOne(
               database,
               sql: "SELECT name FROM playlists WHERE id = ?",
               arguments: [excludingID]
           ) {
            preservesExistingReservedName = PlaylistNamePolicy.normalizedKey(existingName) == key
        } else {
            preservesExistingReservedName = false
        }
        guard !isReservedName || preservesExistingReservedName else {
            throw LibraryDatabaseError.reservedPlaylistName(trimmed)
        }
        let rows = try Row.fetchAll(database, sql: "SELECT id, name FROM playlists")
        for row in rows {
            let id: Int64 = row["id"]
            guard id != excludingID else { continue }
            let existing: String = row["name"]
            if PlaylistNamePolicy.normalizedKey(existing) == key {
                throw LibraryDatabaseError.duplicatePlaylistName(trimmed)
            }
        }
        return trimmed
    }

    static func playlist(from row: Row) throws -> Playlist {
        let name: String = row["name"]
        guard PlaylistNamePolicy.trimmed(name) == name, !name.isEmpty else {
            throw LibraryDatabaseError.invalidPlaylistName
        }
        guard let kind = PlaylistKind(rawValue: row["kind"]),
              let createdAtUTC = Self.date(from: row, column: "createdAtUTC") else {
            throw LibraryDatabaseError.invalidPlaylistDefinition("playlist row has invalid kind or creation date")
        }
        let rulesJSON: String? = row["rulesJSON"]
        let sortFieldRaw: String? = row["sortField"]
        let sortDescending: Bool = row["sortDescending"]
        let definition: PlaylistDefinition
        switch kind {
        case .manual:
            guard rulesJSON == nil, sortFieldRaw == nil, !sortDescending else {
                throw LibraryDatabaseError.invalidPlaylistDefinition("manual playlist has smart-only state")
            }
            definition = .manual
        case .smart:
            guard let rulesJSON,
                  let sortFieldRaw,
                  let sortField = PlaylistSortField(rawValue: sortFieldRaw),
                  !rulesJSON.isEmpty else {
                throw LibraryDatabaseError.invalidPlaylistDefinition("smart playlist has invalid definition")
            }
            do {
                _ = try PlaylistRuleValidator.parse(rulesJSON)
            } catch let error as PlaylistRuleValidationError {
                 throw LibraryDatabaseError.invalidSmartPlaylistRules(error)
            }
            definition = .smart(
                rulesJSON: rulesJSON,
                sortField: sortField,
                sortDescending: sortDescending
            )
        }
        return Playlist(id: row["id"], name: name, createdAtUTC: createdAtUTC, definition: definition)
    }

    /// Compatibility spelling for playlist listing.
    public func listPlaylists() throws -> [Playlist] {
        try playlists()
    }
    /// Returns all user playlists in case-insensitive alphabetical order.
    public func playlists() throws -> [Playlist] {
        try readCatalog { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT \(Self.playlistSelection)
                    FROM playlists
                    ORDER BY name COLLATE NOCASE ASC, name ASC, id ASC
                    """
            ).map(Self.playlist)
        }
    }

    /// Compatibility spelling for listing user playlists.
    public func userPlaylists() throws -> [Playlist] {
        try playlists()
    }

    /// Returns one validated user playlist.
    public func playlist(id: Int64) throws -> Playlist? {
        try readCatalog { database in
            guard let row = try Self.fetchPlaylistRow(id: id, db: database) else { return nil }
            return try Self.playlist(from: row)
        }
    }

    /// Validates a proposed user-playlist name without changing the database.
    @discardableResult
    public func validatePlaylistName(_ name: String, excludingID: Int64? = nil) throws -> String {
        try readCatalog { database in
            try Self.playlistName(name, excludingID: excludingID, db: database)
        }
    }

    /// Returns the normalized key used for user-playlist name comparisons.
    public static func normalizedPlaylistName(_ name: String) -> String {
        PlaylistNamePolicy.normalizedKey(name)
    }

    /// Creates an empty manual or smart user playlist.
    @discardableResult
    public func createPlaylist(
        name: String,
        definition: PlaylistDefinition,
        createdAtUTC: Date = Date()
    ) throws -> Playlist {
        guard createdAtUTC.timeIntervalSinceReferenceDate.isFinite else {
            throw LibraryDatabaseError.invalidPlaylistDefinition("creation date is not finite")
        }
        try Self.validatePlaylistDefinition(definition)
        return try writeCatalog { database in
            let name = try Self.playlistName(name, excludingID: nil, db: database)
            let rulesJSON = definition.rulesJSON
            let sortField = definition.sortField?.rawValue
            try database.execute(
                sql: """
                    INSERT INTO playlists (
                        name, kind, createdAtUTC, rulesJSON, sortField, sortDescending
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    name,
                    definition.kind.rawValue,
                    Self.databaseTimestamp(createdAtUTC) ?? 0,
                    rulesJSON,
                    sortField,
                    definition.sortDescending ? 1 : 0
                ]
            )
            let id = database.lastInsertedRowID
            guard id > 0 else {
                throw LibraryDatabaseError.invalidPlaylistDefinition("playlist insert did not return an ID")
            }
            guard let row = try Self.fetchPlaylistRow(id: id, db: database) else {
                throw LibraryDatabaseError.missingPlaylist(id)
            }
            return try Self.playlist(from: row)
        }
    }

    /// Creates a user playlist from its kind-specific fields.
    @discardableResult
    public func createPlaylist(
        name: String,
        kind: PlaylistKind,
        rulesJSON: String? = nil,
        sortField: PlaylistSortField? = nil,
        sortDescending: Bool = false,
        createdAtUTC: Date = Date()
    ) throws -> Playlist {
        let definition: PlaylistDefinition
        switch kind {
        case .manual:
            guard rulesJSON == nil, sortField == nil, !sortDescending else {
                throw LibraryDatabaseError.invalidPlaylistDefinition("manual playlist cannot have smart-only state")
            }
            definition = .manual
        case .smart:
            guard let rulesJSON, let sortField else {
                throw LibraryDatabaseError.invalidPlaylistDefinition("smart playlist requires rules and sort field")
            }
            definition = .smart(
                rulesJSON: rulesJSON,
                sortField: sortField,
                sortDescending: sortDescending
            )
        }
        return try createPlaylist(name: name, definition: definition, createdAtUTC: createdAtUTC)
    }

    /// Renames a user playlist while preserving its ID and kind.
    @discardableResult
    public func renamePlaylist(id: Int64, to name: String) throws -> Playlist {
        try writeCatalog { database in
            guard try Int64.fetchOne(
                database,
                sql: "SELECT id FROM playlists WHERE id = ?",
                arguments: [id]
            ) != nil else {
                throw LibraryDatabaseError.missingPlaylist(id)
            }
            let name = try Self.playlistName(name, excludingID: id, db: database)
            try database.execute(
                sql: "UPDATE playlists SET name = ? WHERE id = ?",
                arguments: [name, id]
            )
            guard let row = try Self.fetchPlaylistRow(id: id, db: database) else {
                throw LibraryDatabaseError.missingPlaylist(id)
            }
            return try Self.playlist(from: row)
        }
    }

    /// Compatibility spelling for renaming a playlist.
    @discardableResult
    public func renamePlaylist(id: Int64, name: String) throws -> Playlist {
        try renamePlaylist(id: id, to: name)
    }
    /// Deletes a user playlist and its ordered items.
    public func deletePlaylist(id: Int64) throws {
        try writeCatalog { database in
            guard try Int64.fetchOne(
                database,
                sql: "SELECT id FROM playlists WHERE id = ?",
                arguments: [id]
            ) != nil else {
                throw LibraryDatabaseError.missingPlaylist(id)
            }
            try database.execute(sql: "DELETE FROM playlists WHERE id = ?", arguments: [id])
        }
    }

    /// Atomically updates a smart playlist's validated rules and sort.
    @discardableResult
    public func updateSmartPlaylist(
        id: Int64,
        rulesJSON: String,
        sortField: PlaylistSortField,
        sortDescending: Bool
    ) throws -> Playlist {
        let definition = PlaylistDefinition.smart(
            rulesJSON: rulesJSON,
            sortField: sortField,
            sortDescending: sortDescending
        )
        try Self.validatePlaylistDefinition(definition)
        return try writeCatalog { database in
            guard let existingKind = try String.fetchOne(
                database,
                sql: "SELECT kind FROM playlists WHERE id = ?",
                arguments: [id]
            ) else {
                throw LibraryDatabaseError.missingPlaylist(id)
            }
            guard existingKind == PlaylistKind.smart.rawValue else {
                throw LibraryDatabaseError.playlistKindMismatch(id)
            }
            try database.execute(
                sql: """
                    UPDATE playlists
                    SET rulesJSON = ?, sortField = ?, sortDescending = ?
                    WHERE id = ? AND kind = ?
                    """,
                arguments: [
                    rulesJSON.trimmingCharacters(in: .whitespacesAndNewlines),
                    sortField.rawValue,
                    sortDescending ? 1 : 0,
                    id,
                    PlaylistKind.smart.rawValue
                ]
            )
            guard let row = try Self.fetchPlaylistRow(id: id, db: database) else {
                throw LibraryDatabaseError.missingPlaylist(id)
            }
            return try Self.playlist(from: row)
        }
    }

    /// Compatibility spelling for smart-playlist updates.
    @discardableResult
    public func updateSmartPlaylist(
        id: Int64,
        rules: [PlaylistRule],
        sortField: PlaylistSortField,
        sortDescending: Bool
    ) throws -> Playlist {
        try updateSmartPlaylist(
            id: id,
            rulesJSON: try PlaylistRuleValidator.encode(rules),
            sortField: sortField,
            sortDescending: sortDescending
        )
    }
}
