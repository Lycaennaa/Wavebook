import Foundation
import GRDB

extension LibraryDatabase {
    /// Deletes finalized qualified-play events and returns in-memory data for Undo.
    public func deleteQualifiedListeningHistory(
        on day: ListeningLocalDay,
        eventIDs: [UUID],
        timeZone: TimeZone = .current
    ) throws -> ListeningHistoryDeletion {
        let requestedIDs = Array(Set(eventIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !requestedIDs.isEmpty else { throw LibraryDatabaseError.invalidListeningEvent }

        return try writer.write { database in
            var events: [ListeningEvent] = []
            var snapshotsByID: [Int64: ListeningMediaSnapshot] = [:]
            for eventID in requestedIDs {
                events.append(try Self.deletableListeningEvent(
                    id: eventID,
                    on: day,
                    timeZone: timeZone,
                    database: database,
                    snapshotsByID: &snapshotsByID
                ))
            }

            for event in events {
                try database.execute(
                    sql: "DELETE FROM listeningEvents WHERE id = ?",
                    arguments: [event.id.uuidString]
                )
                guard database.changesCount == 1 else {
                    throw LibraryDatabaseError.missingListeningEvent(event.id)
                }
            }

            for snapshotID in snapshotsByID.keys.sorted() {
                try database.execute(
                    sql: """
                    DELETE FROM listeningMediaSnapshots
                    WHERE id = ? AND NOT EXISTS (
                        SELECT 1 FROM listeningEvents WHERE snapshotId = listeningMediaSnapshots.id
                    )
                    """,
                    arguments: [snapshotID]
                )
            }

            return ListeningHistoryDeletion(
                events: events,
                snapshots: snapshotsByID.keys.sorted().compactMap { snapshotsByID[$0] }
            )
        }
    }

    private static func deletableListeningEvent(
        id: UUID,
        on day: ListeningLocalDay,
        timeZone: TimeZone,
        database: Database,
        snapshotsByID: inout [Int64: ListeningMediaSnapshot]
    ) throws -> ListeningEvent {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT * FROM listeningEvents WHERE id = ?",
            arguments: [id.uuidString]
        ) else {
            throw LibraryDatabaseError.missingListeningEvent(id)
        }
        guard row["endedAtUTC"] != nil, row["qualifiedAtUTC"] != nil else {
            throw LibraryDatabaseError.invalidListeningEvent
        }

        let event = try Self.listeningEvent(from: row, db: database)
        guard event.endedAtUTC != nil,
              let qualifiedAtUTC = event.qualification?.timestampUTC,
              let timelineDay = ListeningLocalDay(date: qualifiedAtUTC, timeZone: timeZone),
              timelineDay == day else {
            throw LibraryDatabaseError.invalidListeningEvent
        }
        if snapshotsByID[event.snapshotID] == nil {
            guard let snapshotRow = try Row.fetchOne(
                database,
                sql: "SELECT * FROM listeningMediaSnapshots WHERE id = ?",
                arguments: [event.snapshotID]
            ) else {
                throw LibraryDatabaseError.invalidListeningSnapshot
            }
            snapshotsByID[event.snapshotID] = try Self.listeningSnapshot(from: snapshotRow, db: database)
        }
        return event
    }

    /// Restores a previously deleted batch of listening-history events.
    public func restoreListeningHistory(_ deletion: ListeningHistoryDeletion) throws {
        guard !deletion.events.isEmpty else { throw LibraryDatabaseError.invalidListeningEvent }

        try writer.write { database in
            let snapshotsByID = try Self.validatedRestorationSnapshots(deletion, database: database)
            try Self.restoreListeningSnapshots(snapshotsByID, database: database)
            for event in deletion.events {
                try Self.restoreListeningEvent(event, database: database)
            }
        }
    }

    private static func validatedRestorationSnapshots(
        _ deletion: ListeningHistoryDeletion,
        database: Database
    ) throws -> [Int64: ListeningMediaSnapshot] {
        var seenEventIDs = Set<UUID>()
        for event in deletion.events {
            guard event.endedAtUTC != nil, event.qualification != nil,
                  seenEventIDs.insert(event.id).inserted else {
                throw LibraryDatabaseError.invalidListeningEvent
            }
            if try Row.fetchOne(
                database,
                sql: "SELECT id FROM listeningEvents WHERE id = ?",
                arguments: [event.id.uuidString]
            ) != nil {
                throw LibraryDatabaseError.listeningEventIDCollision(event.id)
            }
        }

        var snapshotsByID: [Int64: ListeningMediaSnapshot] = [:]
        for snapshot in deletion.snapshots {
            guard let id = snapshot.id, snapshotsByID[id] == nil else {
                throw LibraryDatabaseError.invalidListeningSnapshot
            }
            snapshotsByID[id] = snapshot
        }
        for event in deletion.events where snapshotsByID[event.snapshotID] == nil {
            throw LibraryDatabaseError.invalidListeningSnapshot
        }
        return snapshotsByID
    }

    private static func restoreListeningSnapshots(
        _ snapshotsByID: [Int64: ListeningMediaSnapshot],
        database: Database
    ) throws {
        for snapshotID in snapshotsByID.keys.sorted() {
            guard let snapshot = snapshotsByID[snapshotID] else { continue }
            if let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM listeningMediaSnapshots WHERE id = ?",
                arguments: [snapshotID]
            ) {
                let existing = try Self.listeningSnapshot(from: row, db: database)
                guard existing.metadataSignature == snapshot.metadataSignature else {
                    throw LibraryDatabaseError.invalidListeningSnapshot
                }
            } else {
                try Self.restoreListeningSnapshot(snapshot, database: database)
            }
        }
    }

    private static func restoreListeningSnapshot(
        _ snapshot: ListeningMediaSnapshot,
        database: Database
    ) throws {
        guard let id = snapshot.id,
              let createdAtUTC = databaseTimestamp(snapshot.createdAtUTC) else {
            throw LibraryDatabaseError.invalidListeningSnapshot
        }
        let liveTrackID: Int64?
        if let candidate = snapshot.liveTrackID,
           try Int64.fetchOne(database, sql: "SELECT id FROM tracks WHERE id = ?", arguments: [candidate]) != nil {
            liveTrackID = candidate
        } else {
            liveTrackID = nil
        }

        try database.execute(
            sql: """
            INSERT INTO listeningMediaSnapshots (
                id, liveTrackId, metadataSignature, title, artistDisplay, albumTitle, albumOwner,
                genreDisplay, openedDuration, format, createdAtUTC
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                id,
                liveTrackID,
                snapshot.metadataSignature,
                snapshot.title,
                snapshot.artistDisplay,
                snapshot.albumTitle,
                snapshot.albumOwner,
                snapshot.genreDisplay,
                snapshot.openedDuration,
                snapshot.format,
                createdAtUTC
            ]
        )
        for (ordinal, value) in snapshot.artists.enumerated() {
            try database.execute(
                sql: "INSERT INTO listeningSnapshotArtists (snapshotId, ordinal, displayValue) VALUES (?, ?, ?)",
                arguments: [id, ordinal, value]
            )
        }
        for (ordinal, value) in snapshot.genres.enumerated() {
            try database.execute(
                sql: "INSERT INTO listeningSnapshotGenres (snapshotId, ordinal, displayValue) VALUES (?, ?, ?)",
                arguments: [id, ordinal, value]
            )
        }
    }

    private static func restoreListeningEvent(_ event: ListeningEvent, database: Database) throws {
        guard let startedAtUTC = databaseTimestamp(event.startedAtUTC),
              let endedAtUTC = event.endedAtUTC.flatMap(databaseTimestamp) else {
            throw LibraryDatabaseError.invalidListeningEvent
        }
        let qualification = event.qualification
        let skip = event.skip
        try database.execute(
            sql: """
            INSERT INTO listeningEvents (
                id, historyGeneration, snapshotId, sourceKind, sourcePersistentID, sourceName,
                startedAtUTC, startedUTCOffsetSeconds, endedAtUTC, endedUTCOffsetSeconds,
                startPosition, endPosition, lastDurableCheckpointAtUTC,
                lastDurableCheckpointUTCOffsetSeconds, lastDurableCheckpointSequence, endReason,
                qualifiedAtUTC, qualifiedLocalDay, qualifiedUTCOffsetSeconds,
                skipAtUTC, skipLocalDay, skipUTCOffsetSeconds
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                event.id.uuidString,
                event.historyGeneration,
                event.snapshotID,
                event.source.kind.rawValue,
                event.source.persistentID,
                event.source.sourceName,
                startedAtUTC,
                event.startedUTCOffsetSeconds,
                endedAtUTC,
                event.endedUTCOffsetSeconds,
                event.startPosition,
                event.endPosition,
                event.lastDurableCheckpointAtUTC.flatMap(databaseTimestamp),
                event.lastDurableCheckpointUTCOffsetSeconds,
                event.lastDurableCheckpointSequence,
                event.endReason?.rawValue,
                qualification.flatMap { databaseTimestamp($0.timestampUTC) },
                qualification?.localDay.rawValue,
                qualification?.utcOffsetSeconds,
                skip.flatMap { databaseTimestamp($0.timestampUTC) },
                skip?.localDay.rawValue,
                skip?.utcOffsetSeconds
            ]
        )

        for slice in event.daySlices {
            guard slice.eventID == event.id, slice.isValid else {
                throw LibraryDatabaseError.invalidListeningEvent
            }
            try database.execute(
                sql: """
                INSERT INTO listeningEventDays (eventId, localDay, utcOffsetSeconds, actualListenedSeconds)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [
                    event.id.uuidString,
                    slice.localDay.rawValue,
                    slice.utcOffsetSeconds,
                    slice.actualListenedSeconds
                ]
            )
        }
    }
}
