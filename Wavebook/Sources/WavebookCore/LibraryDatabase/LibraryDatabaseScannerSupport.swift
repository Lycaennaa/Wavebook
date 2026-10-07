import Foundation
import GRDB

struct LibraryScanReuseEntry: Sendable {
    let track: Track
    let fingerprint: ReplayGainFileFingerprint
}

extension LibraryDatabase {
    func scanReuseEntries(rootPath: String) throws -> [String: LibraryScanReuseEntry] {
        try readCatalog { database in
            guard let rootID = try Self.rootID(matching: rootPath, db: database) else { return [:] }
            let rows = try Row.fetchCursor(
                database,
                sql: """
                    SELECT \(Self.trackSelection)
                    FROM tracks
                    WHERE tracks.rootId = ?
                    """,
                arguments: [rootID]
            )
            var entries: [String: LibraryScanReuseEntry] = [:]
            while let row = try rows.next() {
                try Self.checkCatalogCancellation()
                let path: String = row["path"]
                let fingerprint = ReplayGainFileFingerprint(
                    modificationDate: Self.date(from: row, column: "mtime"),
                    fileSize: row["fileSize"]
                )
                entries[path] = LibraryScanReuseEntry(track: Self.track(from: row), fingerprint: fingerprint)
            }
            return entries
        }
    }

    func matchedLyricTrackCount(rootPath: String) throws -> Int {
        try readCatalog { database in
            guard let rootID = try Self.rootID(matching: rootPath, db: database) else { return 0 }
            return try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*)
                    FROM tracks
                    WHERE tracks.rootId = ?
                      AND EXISTS (
                          SELECT 1 FROM lyricFiles WHERE lyricFiles.lyricsKey = tracks.lyricsKey
                      )
                    """,
                arguments: [rootID]
            ) ?? 0
        }
    }

    func completeUnchangedScan(rootPath: String, lyricFiles: [URL]) throws -> Bool {
        let requestedRootPath = try Self.resolveRootPath(rootPath)
        let discoveredLyricPaths = try Set(lyricFiles.map { url in
            try Self.canonicalPath(url.path, underRoot: requestedRootPath)
        })
        return try writer.write { database in
            guard let rootID = try Self.rootID(matching: requestedRootPath, db: database) else { return false }
            let storedLyricPaths = Set(try String.fetchAll(
                database,
                sql: "SELECT path FROM lyricFiles WHERE rootId = ?",
                arguments: [rootID]
            ))
            guard storedLyricPaths == discoveredLyricPaths else { return false }
            try Self.checkCatalogCancellation()
            try database.execute(
                sql: "UPDATE roots SET lastScanAt = ? WHERE id = ?",
                arguments: [Date(), rootID]
            )
            CatalogReconcileTesting.checkpoint(.unchangedScanTimestampUpdated)
            try Self.checkCatalogCancellation()
            return true
        }
    }

    func reconcileFailedCandidates(rootPath: String, paths: Set<String>) throws -> Set<String> {
        guard !paths.isEmpty else { return [] }

        let requestedRootPath = try Self.resolveRootPath(rootPath)
        let candidatePaths = try Set(paths.map { path in
                return try Self.canonicalPathPreservingUnresolvedLeaf(path, underRoot: requestedRootPath)
        })
        var fingerprints: [String: ReplayGainFileFingerprint] = [:]
        fingerprints.reserveCapacity(candidatePaths.count)
        for path in candidatePaths {
            try Self.checkCatalogCancellation()
            fingerprints[path] = Self.fileFingerprint(path: path)
            try Self.checkCatalogCancellation()
        }
        let reconciledPaths = try writer.write { database in
            try Self.reconcileFailedCandidates(
                rootPath: requestedRootPath,
                candidatePaths: candidatePaths,
                fingerprints: fingerprints,
                database: database
            )
        }
        try invalidateChangedReplayGainFiles(
            expected: fingerprints,
            ignoringCancellation: true
        )
        try Self.checkCatalogCancellation()
        return reconciledPaths
    }

    private static func reconcileFailedCandidates(
        rootPath: String,
        candidatePaths: Set<String>,
        fingerprints: [String: ReplayGainFileFingerprint],
        database: Database
    ) throws -> Set<String> {
        guard let rootID = try Self.rootID(matching: rootPath, db: database),
              let storedRootPath = try Self.rootPath(forID: rootID, db: database) else {
            return []
        }
        let rows = try Row.fetchCursor(database, sql: """
            SELECT tracks.id, tracks.path, tracks.albumTitle, tracks.albumArtist, tracks.artistDisplay,
                   replayGainAnalysis.trackId AS analysisTrackID,
                   replayGainAnalysis.sourceMtime, replayGainAnalysis.sourceFileSize,
                   replayGainAnalysis.sourceContentFingerprint
            FROM tracks
            LEFT JOIN replayGainAnalysis ON replayGainAnalysis.trackId = tracks.id
            WHERE tracks.rootId = ?
            """, arguments: [rootID])

        var preservedPaths = Set<String>()
        while let row = try rows.next() {
            try Self.checkCatalogCancellation()
            let path: String = row["path"]
            let canonicalPath = try Self.canonicalPathPreservingUnresolvedLeaf(path, underRoot: storedRootPath)
            guard candidatePaths.contains(canonicalPath) else { continue }
            preservedPaths.insert(canonicalPath)

            let analysisTrackID: Int64? = row["analysisTrackID"]
            guard analysisTrackID != nil else { continue }

            guard let currentFingerprint = fingerprints[canonicalPath],
                  !Self.fingerprintsMatch(currentFingerprint, Self.fingerprint(from: row)) else { continue }
            try Self.invalidateReplayGainForFileChange(
                trackID: row["id"],
                currentFingerprint: currentFingerprint,
                row: row,
                db: database
            )
        }
        return preservedPaths
    }
}
