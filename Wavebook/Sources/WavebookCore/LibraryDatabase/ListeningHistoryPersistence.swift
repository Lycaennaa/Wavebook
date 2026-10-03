import Foundation
import GRDB

extension LibraryDatabase {
    private struct ListeningEventUpdateRequest {
        let eventID: UUID
        let checkpointAtUTC: Date
        let checkpointTimestamp: Double
        let renderedPosition: TimeInterval
        let checkpointUTCOffsetSeconds: Int
        let forceProgress: Bool
        let checkpointSequence: Int64?
        let endReason: ListeningEventEndReason?
        let endedUTCOffsetSeconds: Int?
        let qualification: ListeningEventOccurrence?
        let skip: ListeningEventOccurrence?
        let finish: Bool
    }

    static func updateListeningEvent(
        db database: Database,
        eventID: UUID,
        checkpointAtUTC: Date,
        renderedPosition: TimeInterval,
        checkpointUTCOffsetSeconds: Int,
        forceProgress: Bool = false,
        checkpointSequence: Int64? = nil,
        endReason: ListeningEventEndReason? = nil,
        endedUTCOffsetSeconds: Int? = nil,
        qualification: ListeningEventOccurrence? = nil,
        skip: ListeningEventOccurrence? = nil,
        finish: Bool = false
    ) throws {
        guard let checkpointTimestamp = Self.databaseTimestamp(checkpointAtUTC) else {
            throw LibraryDatabaseError.invalidListeningEvent
        }
        let request = ListeningEventUpdateRequest(
            eventID: eventID,
            checkpointAtUTC: checkpointAtUTC,
            checkpointTimestamp: checkpointTimestamp,
            renderedPosition: renderedPosition,
            checkpointUTCOffsetSeconds: checkpointUTCOffsetSeconds,
            forceProgress: forceProgress,
            checkpointSequence: checkpointSequence,
            endReason: endReason,
            endedUTCOffsetSeconds: endedUTCOffsetSeconds,
            qualification: qualification,
            skip: skip,
            finish: finish
        )
        try writeListeningCheckpoint(request: request, database: database)
        if let qualification {
            try writeListeningQualification(eventID: eventID, occurrence: qualification, database: database)
        }
        if let skip {
            try writeListeningSkip(eventID: eventID, occurrence: skip, database: database)
        }
        if finish {
            try writeFinishedListeningEvent(request: request, database: database)
        }
    }

    private static func writeListeningCheckpoint(
        request: ListeningEventUpdateRequest,
        database: Database
    ) throws {
        try database.execute(
            sql: """
            UPDATE listeningEvents
            SET lastDurableCheckpointSequence = CASE
                    WHEN ? IS NULL THEN lastDurableCheckpointSequence
                    WHEN lastDurableCheckpointSequence < ? THEN ?
                    ELSE lastDurableCheckpointSequence
                END,
                lastDurableCheckpointAtUTC = CASE
                    WHEN lastDurableCheckpointAtUTC IS NULL OR lastDurableCheckpointAtUTC < ? OR ? = 1 THEN ?
                    ELSE lastDurableCheckpointAtUTC
                END,
                lastDurableCheckpointUTCOffsetSeconds = CASE
                    WHEN lastDurableCheckpointAtUTC IS NULL OR lastDurableCheckpointAtUTC < ? OR ? = 1
                        OR (? = 1 AND lastDurableCheckpointAtUTC <= ?) THEN ?
                    ELSE lastDurableCheckpointUTCOffsetSeconds
                END,
                endPosition = CASE
                    WHEN lastDurableCheckpointAtUTC IS NULL OR lastDurableCheckpointAtUTC < ? OR ? = 1
                        OR (? = 1 AND lastDurableCheckpointAtUTC <= ?) THEN ?
                    ELSE endPosition
                END
            WHERE id = ?
            """,
            arguments: [
                request.checkpointSequence,
                request.checkpointSequence,
                request.checkpointSequence,
                request.checkpointTimestamp,
                request.forceProgress ? 1 : 0,
                request.checkpointTimestamp,
                request.checkpointTimestamp,
                request.forceProgress ? 1 : 0,
                request.finish ? 1 : 0,
                request.checkpointTimestamp,
                request.checkpointUTCOffsetSeconds,
                request.checkpointTimestamp,
                request.forceProgress ? 1 : 0,
                request.finish ? 1 : 0,
                request.checkpointTimestamp,
                max(request.renderedPosition, 0),
                request.eventID.uuidString
            ]
        )
    }

    private static func writeListeningQualification(
        eventID: UUID,
        occurrence: ListeningEventOccurrence,
        database: Database
    ) throws {
        guard let timestamp = Self.databaseTimestamp(occurrence.timestampUTC) else {
            throw LibraryDatabaseError.invalidListeningEvent
        }
        try database.execute(
            sql: """
            UPDATE listeningEvents
            SET qualifiedAtUTC = COALESCE(qualifiedAtUTC, ?),
                qualifiedLocalDay = COALESCE(qualifiedLocalDay, ?),
                qualifiedUTCOffsetSeconds = COALESCE(qualifiedUTCOffsetSeconds, ?)
            WHERE id = ?
            """,
            arguments: [timestamp, occurrence.localDay.rawValue, occurrence.utcOffsetSeconds, eventID.uuidString]
        )
    }

    private static func writeListeningSkip(
        eventID: UUID,
        occurrence: ListeningEventOccurrence,
        database: Database
    ) throws {
        guard let timestamp = Self.databaseTimestamp(occurrence.timestampUTC) else {
            throw LibraryDatabaseError.invalidListeningEvent
        }
        try database.execute(
            sql: """
            UPDATE listeningEvents
            SET skipAtUTC = COALESCE(skipAtUTC, ?),
                skipLocalDay = COALESCE(skipLocalDay, ?),
                skipUTCOffsetSeconds = COALESCE(skipUTCOffsetSeconds, ?)
            WHERE id = ?
            """,
            arguments: [timestamp, occurrence.localDay.rawValue, occurrence.utcOffsetSeconds, eventID.uuidString]
        )
    }

    private static func writeFinishedListeningEvent(
        request: ListeningEventUpdateRequest,
        database: Database
    ) throws {
        guard let endReason = request.endReason,
              let endedUTCOffsetSeconds = request.endedUTCOffsetSeconds else {
            throw LibraryDatabaseError.invalidListeningEvent
        }
        try database.execute(
            sql: """
            UPDATE listeningEvents
            SET endedAtUTC = ?,
                endedUTCOffsetSeconds = ?,
                endPosition = ?,
                endReason = ?
            WHERE id = ? AND endedAtUTC IS NULL
            """,
            arguments: [
                request.checkpointTimestamp,
                endedUTCOffsetSeconds,
                max(request.renderedPosition, 0),
                endReason.rawValue,
                request.eventID.uuidString
            ]
        )
    }

    static func checkpointListeningEvent(
        request: CheckpointListeningEventRequest,
        writer: any DatabaseWriter
    ) throws -> ListeningHistoryMutationResult {
        try writer.write { database in
            try Self.applyCheckpoint(request: request, database: database)
        }
    }

    private static func applyCheckpoint(
        request: CheckpointListeningEventRequest,
        database: Database
    ) throws -> ListeningHistoryMutationResult {
        let state = try Self.listeningHistoryState(db: database)
        guard state.generation == request.expectedGeneration else { return .staleGeneration }
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT * FROM listeningEvents WHERE id = ?",
            arguments: [request.eventID.uuidString]
        ) else {
            return .missingEvent
        }
        let eventGeneration: Int64 = row["historyGeneration"]
        guard eventGeneration == request.expectedGeneration else { return .staleGeneration }
        let lastCheckpointSequence: Int64 = row["lastDurableCheckpointSequence"]
        if row["endedAtUTC"] != nil {
            return try Self.finishedMutationMatches(
                row: row,
                eventID: request.eventID,
                daySlices: request.daySlices,
                qualification: request.qualification,
                skip: nil,
                db: database
            ) ? .applied : .alreadyFinished
        }
        if request.checkpointSequence < lastCheckpointSequence
            || (request.forceRebase && request.checkpointSequence <= lastCheckpointSequence) {
            return .staleCheckpointSequence
        }
        return try Self.writeActiveCheckpoint(
            request: request,
            database: database,
            lastCheckpointSequence: lastCheckpointSequence
        )
    }

    private static func writeActiveCheckpoint(
        request: CheckpointListeningEventRequest,
        database: Database,
        lastCheckpointSequence: Int64
    ) throws -> ListeningHistoryMutationResult {
        let shouldForceRebase = request.forceRebase && request.checkpointSequence > lastCheckpointSequence
        let previousListenedSeconds = try Double.fetchOne(
            database,
            sql: "SELECT COALESCE(SUM(actualListenedSeconds), 0) FROM listeningEventDays WHERE eventId = ?",
            arguments: [request.eventID.uuidString]
        ) ?? 0
        let slices = try Self.normalizedListeningSlices(request.daySlices, eventID: request.eventID)
        try Self.upsertListeningSlices(slices, eventID: request.eventID, db: database)
        let listenedSeconds = try Double.fetchOne(
            database,
            sql: "SELECT COALESCE(SUM(actualListenedSeconds), 0) FROM listeningEventDays WHERE eventId = ?",
            arguments: [request.eventID.uuidString]
        ) ?? 0
        try Self.validateListeningQualification(
            request.qualification,
            eventID: request.eventID,
            db: database
        )
        try Self.updateListeningEvent(
            db: database,
            eventID: request.eventID,
            checkpointAtUTC: request.checkpointAtUTC,
            renderedPosition: request.renderedPosition,
            checkpointUTCOffsetSeconds: request.checkpointUTCOffsetSeconds,
            forceProgress: listenedSeconds > previousListenedSeconds || shouldForceRebase,
            checkpointSequence: request.checkpointSequence,
            endReason: nil,
            endedUTCOffsetSeconds: nil,
            qualification: request.qualification,
            skip: nil,
            finish: false
        )
        return .applied
    }

}
