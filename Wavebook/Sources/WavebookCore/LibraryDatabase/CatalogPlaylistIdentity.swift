import GRDB

extension LibraryDatabase {
    static func preservePlaylistItemIdentity(forTrackID trackID: Int64, db database: Database) throws {
        try database.execute(
            sql: """
                UPDATE playlistItems
                SET sourceVolumeIdentifier = (SELECT fileVolumeIdentifier FROM tracks WHERE id = ?),
                    sourceResourceIdentifier = (SELECT fileResourceIdentifier FROM tracks WHERE id = ?)
                WHERE trackID = ?
                  AND sourceVolumeIdentifier IS NULL
                  AND sourceResourceIdentifier IS NULL
                """,
            arguments: [trackID, trackID, trackID]
        )
    }

    static func deleteTrackPreservingPlaylistIdentity(trackID: Int64, db database: Database) throws {
        try preservePlaylistItemIdentity(forTrackID: trackID, db: database)
        try database.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [trackID])
    }

    static func reattachOrphanedPlaylistItems(db database: Database) throws {
        try Self.checkCatalogCancellation()
        try database.execute(
            sql: """
                WITH uniqueTracks AS (
                    SELECT fileVolumeIdentifier AS volumeIdentifier,
                           fileResourceIdentifier AS resourceIdentifier,
                           MIN(id) AS trackID
                    FROM tracks
                    WHERE fileVolumeIdentifier IS NOT NULL
                      AND fileResourceIdentifier IS NOT NULL
                    GROUP BY fileVolumeIdentifier, fileResourceIdentifier
                    HAVING COUNT(*) = 1
                )
                UPDATE playlistItems
                SET trackID = (
                    SELECT uniqueTracks.trackID
                    FROM uniqueTracks
                    WHERE uniqueTracks.volumeIdentifier = playlistItems.sourceVolumeIdentifier
                      AND uniqueTracks.resourceIdentifier = playlistItems.sourceResourceIdentifier
                )
                WHERE playlistItems.trackID IS NULL
                  AND playlistItems.sourceVolumeIdentifier IS NOT NULL
                  AND playlistItems.sourceResourceIdentifier IS NOT NULL
                  AND EXISTS (
                      SELECT 1
                      FROM uniqueTracks
                      WHERE uniqueTracks.volumeIdentifier = playlistItems.sourceVolumeIdentifier
                        AND uniqueTracks.resourceIdentifier = playlistItems.sourceResourceIdentifier
                  )
                """
        )
        try Self.checkCatalogCancellation()
    }
}
