import Foundation
import GRDB

extension LibraryDatabase {
    static func listeningHistoryState(db database: Database) throws -> ListeningHistoryState {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT generation, trackingStartedAtUTC, isPrivate FROM listeningHistoryState WHERE id = 1"
        ),
        let trackingStartedAtUTC = Self.date(from: row, column: "trackingStartedAtUTC") else {
            throw LibraryDatabaseError.invalidListeningEvent
        }
        let generation: Int64 = row["generation"]
        let isPrivate: Bool = row["isPrivate"]
        return ListeningHistoryState(
            generation: generation,
            trackingStartedAtUTC: trackingStartedAtUTC,
            isPrivate: isPrivate
        )
    }

    static func listeningSnapshot(from row: Row, db database: Database) throws -> ListeningMediaSnapshot {
        let snapshotID: Int64 = row["id"]
        let artists = try Row.fetchAll(
            database,
            sql: "SELECT displayValue FROM listeningSnapshotArtists WHERE snapshotId = ? ORDER BY ordinal",
            arguments: [snapshotID]
        ).map { row in
            let value: String = row["displayValue"]
            return value
        }
        let genres = try Row.fetchAll(
            database,
            sql: "SELECT displayValue FROM listeningSnapshotGenres WHERE snapshotId = ? ORDER BY ordinal",
            arguments: [snapshotID]
        ).map { row in
            let value: String = row["displayValue"]
            return value
        }
        guard let createdAtUTC = Self.date(from: row, column: "createdAtUTC") else {
            throw LibraryDatabaseError.invalidListeningSnapshot
        }
        guard let snapshot = ListeningMediaSnapshot(
            id: snapshotID,
            liveTrackID: row["liveTrackId"],
            title: row["title"],
            artistDisplay: row["artistDisplay"],
            albumTitle: row["albumTitle"],
            albumOwner: row["albumOwner"],
            genreDisplay: row["genreDisplay"],
            artists: artists,
            genres: genres,
            openedDuration: row["openedDuration"],
            format: row["format"],
            createdAtUTC: createdAtUTC
        ) else {
            throw LibraryDatabaseError.invalidListeningSnapshot
        }
        return snapshot
    }

    static func occurrence(
        from row: Row,
        timestampColumn: String,
        localDayColumn: String,
        offsetColumn: String
    ) throws -> ListeningEventOccurrence? {
        let timestamp = Self.date(from: row, column: timestampColumn)
        let localDay: String? = row[localDayColumn]
        let offset: Int? = row[offsetColumn]
        guard timestamp != nil || localDay != nil || offset != nil else { return nil }
        guard let timestamp, let localDay, let offset,
              let occurrence = ListeningEventOccurrence(
                  timestampUTC: timestamp,
                  localDay: localDay,
                  utcOffsetSeconds: offset
              ) else {
            throw LibraryDatabaseError.invalidListeningEvent
        }
        return occurrence
    }

    static func listeningEvent(from row: Row, db database: Database) throws -> ListeningEvent {
        guard
            let idString: String = row["id"],
            let id = UUID(uuidString: idString),
            let startedAtUTC = Self.date(from: row, column: "startedAtUTC"),
            let sourceKind = ListeningPlaybackSourceKind(rawValue: row["sourceKind"] as String)
        else {
            throw LibraryDatabaseError.invalidListeningEvent
        }
        let endReasonRaw: String? = row["endReason"]
        let endReason = endReasonRaw.flatMap(ListeningEventEndReason.init(rawValue:))
        if endReasonRaw != nil, endReason == nil { throw LibraryDatabaseError.invalidListeningEvent }
        let qualification = try Self.occurrence(
            from: row,
            timestampColumn: "qualifiedAtUTC",
            localDayColumn: "qualifiedLocalDay",
            offsetColumn: "qualifiedUTCOffsetSeconds"
        )
        let skip = try Self.occurrence(
            from: row,
            timestampColumn: "skipAtUTC",
            localDayColumn: "skipLocalDay",
            offsetColumn: "skipUTCOffsetSeconds"
        )
        let eventID = id.uuidString
        let slices = try listeningDaySlices(eventID: eventID, identifier: id, database: database)
        let generation: Int64 = row["historyGeneration"]
        let snapshotID: Int64 = row["snapshotId"]
        let source = ListeningPlaybackSource(
            kind: sourceKind,
            persistentID: row["sourcePersistentID"],
            sourceName: row["sourceName"]
        )
        return ListeningEvent(
            id: id,
            historyGeneration: generation,
            snapshotID: snapshotID,
            source: source,
            startedAtUTC: startedAtUTC,
            startedUTCOffsetSeconds: row["startedUTCOffsetSeconds"],
            endedAtUTC: Self.date(from: row, column: "endedAtUTC"),
            endedUTCOffsetSeconds: row["endedUTCOffsetSeconds"],
            startPosition: row["startPosition"],
            endPosition: row["endPosition"],
            lastDurableCheckpointAtUTC: Self.date(from: row, column: "lastDurableCheckpointAtUTC"),
            lastDurableCheckpointUTCOffsetSeconds: row["lastDurableCheckpointUTCOffsetSeconds"],
            lastDurableCheckpointSequence: row["lastDurableCheckpointSequence"],
            endReason: endReason,
            qualification: qualification,
            skip: skip,
            daySlices: slices
        )
    }

    private static func listeningDaySlices(
        eventID: String,
        identifier: UUID,
        database: Database
    ) throws -> [ListeningDaySlice] {
        try Row.fetchAll(
            database,
            sql: """
            SELECT localDay, utcOffsetSeconds, actualListenedSeconds
            FROM listeningEventDays
            WHERE eventId = ?
            ORDER BY localDay, utcOffsetSeconds
            """,
            arguments: [eventID]
        ).map { row -> ListeningDaySlice in
            let localDay: String = row["localDay"]
            guard let slice = ListeningDaySlice(
                eventID: identifier,
                localDay: localDay,
                utcOffsetSeconds: row["utcOffsetSeconds"],
                actualListenedSeconds: row["actualListenedSeconds"]
            ) else {
                throw LibraryDatabaseError.invalidListeningEvent
            }
            return slice
        }
    }
}
