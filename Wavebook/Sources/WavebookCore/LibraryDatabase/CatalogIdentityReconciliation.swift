import Foundation
import GRDB

struct CatalogResourceIdentity: Hashable {
    let volumeIdentifier: String
    let resourceIdentifier: String

    init?(volumeIdentifier: String?, resourceIdentifier: String?) {
        guard let volumeIdentifier = Self.canonicalComponent(volumeIdentifier),
              let resourceIdentifier = Self.canonicalComponent(resourceIdentifier) else { return nil }
        self.volumeIdentifier = volumeIdentifier
        self.resourceIdentifier = resourceIdentifier
    }

    static func canonicalComponent(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    init?(track: Track) {
        self.init(
            volumeIdentifier: track.fileVolumeIdentifier,
            resourceIdentifier: track.fileResourceIdentifier
        )
    }

    init?(row: Row) {
        let volumeIdentifier: String? = row["fileVolumeIdentifier"]
        let resourceIdentifier: String? = row["fileResourceIdentifier"]
        self.init(volumeIdentifier: volumeIdentifier, resourceIdentifier: resourceIdentifier)
    }
    init?(url: URL) {
        guard let resourceValues = try? url.resourceValues(
            forKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey]
        ) else { return nil }
        self.init(
            volumeIdentifier: Self.identifierString(resourceValues.volumeIdentifier),
            resourceIdentifier: Self.identifierString(resourceValues.fileResourceIdentifier)
        )
    }

    private static func identifierString(_ value: Any?) -> String? {
        guard let value else { return nil }
        let string: String
        if let value = value as? String {
            string = value
        } else if let value = value as? NSNumber {
            string = value.stringValue
        } else {
            string = String(describing: value)
        }
        return canonicalComponent(string)
    }

}

struct CatalogStoredTrack {
    let id: Int64
    let path: String
    let identity: CatalogResourceIdentity?
    let albumKey: AlbumKey?
}

struct CatalogIdentityReconciliationResult {
    let tracks: [Track]
    let changedAlbumKeys: Set<AlbumKey>
}

enum CatalogIdentityReconciliation {
    private static func fetchStoredTracks(
        for tracks: [Track],
        rootID: Int64,
        database: Database
    ) throws -> [CatalogStoredTrack] {
        var storedTracksByID: [Int64: CatalogStoredTrack] = [:]
        let paths = Array(Set(tracks.map(\.path))).sorted()
        try appendTracks(matchingPaths: paths, rootID: rootID, database: database, to: &storedTracksByID)
        let identities = Array(Set(tracks.compactMap { CatalogResourceIdentity(track: $0) }))
            .sorted {
                if $0.volumeIdentifier != $1.volumeIdentifier {
                    return $0.volumeIdentifier < $1.volumeIdentifier
                }
                return $0.resourceIdentifier < $1.resourceIdentifier
            }
        try appendTracks(
            matchingIdentities: identities,
            rootID: rootID,
            database: database,
            to: &storedTracksByID
        )
        return storedTracksByID.values.sorted { $0.id < $1.id }
    }

    private static func appendStoredTracks(
        from rows: [Row],
        to storedTracksByID: inout [Int64: CatalogStoredTrack]
    ) throws {
        for row in rows {
            try LibraryDatabase.checkCatalogCancellation()
            let storedTrack = CatalogStoredTrack(
                id: row["id"],
                path: row["path"],
                identity: CatalogResourceIdentity(row: row),
                albumKey: LibraryDatabase.albumKey(from: row)
            )
            storedTracksByID[storedTrack.id] = storedTrack
        }
    }

    private static func appendTracks(
        matchingPaths paths: [String],
        rootID: Int64,
        database: Database,
        to storedTracksByID: inout [Int64: CatalogStoredTrack]
    ) throws {
        let pathChunkSize = max(1, DatabaseQueryLimits.maximumSQLiteArgumentCount - 1)
        var pathStart = 0
        while pathStart < paths.count {
            try LibraryDatabase.checkCatalogCancellation()
            let pathEnd = min(pathStart + pathChunkSize, paths.count)
            let pathChunk = paths[pathStart..<pathEnd]
            let placeholders = pathChunk.map { _ in "?" }.joined(separator: ", ")
            var arguments = StatementArguments([rootID])
            arguments += StatementArguments(Array(pathChunk))
            try appendStoredTracks(
                from: Row.fetchAll(
                    database,
                    sql: """
                        SELECT id, path, fileVolumeIdentifier, fileResourceIdentifier,
                               albumTitle, albumArtist, artistDisplay
                        FROM tracks
                        WHERE rootId = ? AND path IN (\(placeholders))
                        """,
                    arguments: arguments
                ),
                to: &storedTracksByID
            )
            pathStart = pathEnd
        }
    }

    private static func appendTracks(
        matchingIdentities identities: [CatalogResourceIdentity],
        rootID: Int64,
        database: Database,
        to storedTracksByID: inout [Int64: CatalogStoredTrack]
    ) throws {
        let identityChunkSize = max(1, (DatabaseQueryLimits.maximumSQLiteArgumentCount - 1) / 2)
        var identityStart = 0
        while identityStart < identities.count {
            try LibraryDatabase.checkCatalogCancellation()
            let identityEnd = min(identityStart + identityChunkSize, identities.count)
            let identityChunk = identities[identityStart..<identityEnd]
            let values = identityChunk.map { _ in "(?, ?)" }.joined(separator: ", ")
            var arguments = StatementArguments()
            for identity in identityChunk {
                arguments += [identity.volumeIdentifier, identity.resourceIdentifier]
            }
            arguments += [rootID]
            try appendStoredTracks(
                from: Row.fetchAll(
                    database,
                    sql: """
                        WITH requested(volumeIdentifier, resourceIdentifier) AS (VALUES \(values)),
                        ranked AS (
                            SELECT tracks.id, tracks.path, tracks.fileVolumeIdentifier, tracks.fileResourceIdentifier,
                                   tracks.albumTitle, tracks.albumArtist, tracks.artistDisplay,
                                   ROW_NUMBER() OVER (
                                       PARTITION BY tracks.fileVolumeIdentifier, tracks.fileResourceIdentifier
                                       ORDER BY tracks.id
                                   ) AS identityRank
                            FROM tracks
                            JOIN requested
                              ON requested.volumeIdentifier = tracks.fileVolumeIdentifier
                             AND requested.resourceIdentifier = tracks.fileResourceIdentifier
                            WHERE tracks.rootId = ?
                        )
                        SELECT id, path, fileVolumeIdentifier, fileResourceIdentifier,
                               albumTitle, albumArtist, artistDisplay
                        FROM ranked
                        WHERE identityRank <= 2
                        """,
                    arguments: arguments
                ),
                to: &storedTracksByID
            )
            identityStart = identityEnd
        }
    }
    static func reconcile(
        tracks: [Track],
        rootID: Int64,
        protectedIdentityPaths: Set<String>,
        database: Database
    ) throws -> CatalogIdentityReconciliationResult {
        let tracks = try canonicalTracks(tracks)
        let storedTracks = try fetchStoredTracks(for: tracks, rootID: rootID, database: database)
        let indexes = try storedTrackIndexes(
            from: storedTracks,
            protectedIdentityPaths: protectedIdentityPaths
        )
        let identityCounts = try incomingIdentityCounts(for: tracks)
        var matches = try matchUniqueIdentities(
            tracks,
            indexes: indexes,
            identityCounts: identityCounts
        )
        try matchTracksWithStoredIdentities(tracks, indexes: indexes, matches: &matches)
        try matchTracksWithoutIdentities(tracks, indexes: indexes, matches: &matches)
        let changedAlbumKeys = try deleteReplacementTracks(
            tracks,
            storedTracksByPath: indexes.byPath,
            matchedIDs: matches.storedIDs,
            database: database
        )
        try updateMatchedTracks(tracks, matches: matches, rootID: rootID, database: database)
        return CatalogIdentityReconciliationResult(tracks: tracks, changedAlbumKeys: changedAlbumKeys)
    }

    private struct StoredTrackIndexes {
        let byPath: [String: CatalogStoredTrack]
        let byIdentity: [CatalogResourceIdentity: [CatalogStoredTrack]]
        let protectedIdentityPaths: Set<String>
    }

    private struct TrackMatches {
        var byIncomingIndex = [Int: CatalogStoredTrack]()
        var storedIDs = Set<Int64>()
        var backfilledIdentities = [Int64: CatalogResourceIdentity]()
    }

    private static func canonicalTracks(_ tracks: [Track]) throws -> [Track] {
        var tracksWithIdentities: [Track] = []
        tracksWithIdentities.reserveCapacity(tracks.count)
        for originalTrack in tracks {
            try LibraryDatabase.checkCatalogCancellation()
            var track = originalTrack
            track.fileVolumeIdentifier = CatalogResourceIdentity.canonicalComponent(track.fileVolumeIdentifier)
            track.fileResourceIdentifier = CatalogResourceIdentity.canonicalComponent(track.fileResourceIdentifier)
            if track.fileVolumeIdentifier == nil,
               track.fileResourceIdentifier == nil,
               let filesystemIdentity = CatalogResourceIdentity(url: URL(fileURLWithPath: track.path)) {
                track.fileVolumeIdentifier = filesystemIdentity.volumeIdentifier
                track.fileResourceIdentifier = filesystemIdentity.resourceIdentifier
            }
            tracksWithIdentities.append(track)
        }
        return tracksWithIdentities
    }

    private static func storedTrackIndexes(
        from storedTracks: [CatalogStoredTrack],
        protectedIdentityPaths: Set<String>
    ) throws -> StoredTrackIndexes {
        var tracksByPath: [String: CatalogStoredTrack] = [:]
        var tracksByIdentity: [CatalogResourceIdentity: [CatalogStoredTrack]] = [:]
        for storedTrack in storedTracks {
            try LibraryDatabase.checkCatalogCancellation()
            tracksByPath[storedTrack.path] = storedTrack
            if let identity = storedTrack.identity {
                tracksByIdentity[identity, default: []].append(storedTrack)
            }
        }
        return StoredTrackIndexes(
            byPath: tracksByPath,
            byIdentity: tracksByIdentity,
            protectedIdentityPaths: protectedIdentityPaths
        )
    }

    private static func incomingIdentityCounts(for tracks: [Track]) throws -> [CatalogResourceIdentity: Int] {
        var counts: [CatalogResourceIdentity: Int] = [:]
        for track in tracks {
            try LibraryDatabase.checkCatalogCancellation()
            if let identity = CatalogResourceIdentity(track: track) {
                counts[identity, default: 0] += 1
            }
        }
        return counts
    }

    private static func matchUniqueIdentities(
        _ tracks: [Track],
        indexes: StoredTrackIndexes,
        identityCounts: [CatalogResourceIdentity: Int]
    ) throws -> TrackMatches {
        var matches = TrackMatches()
        for (index, track) in tracks.enumerated() {
            try LibraryDatabase.checkCatalogCancellation()
            guard let identity = CatalogResourceIdentity(track: track),
                  identityCounts[identity] == 1,
                  let candidates = indexes.byIdentity[identity],
                  candidates.count == 1,
                  let storedTrack = candidates.first,
                  !indexes.protectedIdentityPaths.contains(storedTrack.path),
                  matches.storedIDs.insert(storedTrack.id).inserted else { continue }
            matches.byIncomingIndex[index] = storedTrack
        }
        return matches
    }

    private static func matchTracksWithStoredIdentities(
        _ tracks: [Track],
        indexes: StoredTrackIndexes,
        matches: inout TrackMatches
    ) throws {
        for (index, track) in tracks.enumerated() where matches.byIncomingIndex[index] == nil {
            try LibraryDatabase.checkCatalogCancellation()
            guard let identity = CatalogResourceIdentity(track: track),
                  let storedTrack = indexes.byPath[track.path],
                  storedTrack.identity == nil,
                  matches.storedIDs.insert(storedTrack.id).inserted else { continue }
            matches.byIncomingIndex[index] = storedTrack
            matches.backfilledIdentities[storedTrack.id] = identity
        }
    }

    private static func matchTracksWithoutIdentities(
        _ tracks: [Track],
        indexes: StoredTrackIndexes,
        matches: inout TrackMatches
    ) throws {
        for (index, track) in tracks.enumerated() where matches.byIncomingIndex[index] == nil {
            try LibraryDatabase.checkCatalogCancellation()
            guard CatalogResourceIdentity(track: track) == nil,
                  let storedTrack = indexes.byPath[track.path],
                  matches.storedIDs.insert(storedTrack.id).inserted else { continue }
            matches.byIncomingIndex[index] = storedTrack
        }
    }

    private static func deleteReplacementTracks(
        _ tracks: [Track],
        storedTracksByPath: [String: CatalogStoredTrack],
        matchedIDs: Set<Int64>,
        database: Database
    ) throws -> Set<AlbumKey> {
        let replacementTracks = tracks.compactMap { storedTracksByPath[$0.path] }
            .filter { !matchedIDs.contains($0.id) }
        var replacementIDs = Set<Int64>()
        var changedAlbumKeys = Set<AlbumKey>()
        for storedTrack in replacementTracks where replacementIDs.insert(storedTrack.id).inserted {
            try LibraryDatabase.checkCatalogCancellation()
            CatalogReconcileTesting.checkpoint(.deleting)
            try LibraryDatabase.checkCatalogCancellation()
            if let albumKey = storedTrack.albumKey {
                changedAlbumKeys.insert(albumKey)
            }
            try LibraryDatabase.deleteTrackPreservingPlaylistIdentity(trackID: storedTrack.id, db: database)
        }
        return changedAlbumKeys
    }

    private static func updateMatchedTracks(
        _ tracks: [Track],
        matches: TrackMatches,
        rootID: Int64,
        database: Database
    ) throws {
        let pathChanges = matches.byIncomingIndex.filter { index, storedTrack in
            tracks[index].path != storedTrack.path
        }.sorted { lhs, rhs in
            lhs.value.id < rhs.value.id
        }
        for (_, storedTrack) in pathChanges {
            try LibraryDatabase.checkCatalogCancellation()
            let temporaryPath = "__musicplayer_reconcile_\(UUID().uuidString)_\(storedTrack.id)"
            try database.execute(
                sql: "UPDATE tracks SET path = ? WHERE id = ?",
                arguments: [temporaryPath, storedTrack.id]
            )
        }

        for (index, storedTrack) in matches.byIncomingIndex.sorted(by: { $0.key < $1.key }) {
            let track = tracks[index]
            if track.path != storedTrack.path {
                try LibraryDatabase.checkCatalogCancellation()
                try database.execute(
                    sql: "UPDATE tracks SET path = ?, rootId = ? WHERE id = ?",
                    arguments: [track.path, rootID, storedTrack.id]
                )
            }
            if let identity = matches.backfilledIdentities[storedTrack.id] {
                try database.execute(
                    sql: """
                        UPDATE tracks
                        SET fileVolumeIdentifier = ?, fileResourceIdentifier = ?
                        WHERE id = ?
                        """,
                    arguments: [identity.volumeIdentifier, identity.resourceIdentifier, storedTrack.id]
                )
            }
        }
    }

}
