import Foundation
import GRDB

extension LibraryDatabase {
    static func eventStartMatches(
        row: Row,
        generation: Int64,
        snapshotID: Int64,
        source: ListeningPlaybackSource,
        startedAtUTC: Date,
        startedUTCOffsetSeconds: Int = 0,
        startPosition: TimeInterval = 0
    ) -> Bool {
        let storedGeneration: Int64 = row["historyGeneration"]
        let storedSnapshotID: Int64 = row["snapshotId"]
        let storedSourceKind: String = row["sourceKind"]
        let storedPersistentID: Int64? = row["sourcePersistentID"]
        let storedSourceName: String? = row["sourceName"]
        let storedStartedOffset: Int = row["startedUTCOffsetSeconds"]
        let storedStartPosition: TimeInterval = row["startPosition"]
        return storedGeneration == generation
            && storedSnapshotID == snapshotID
            && storedSourceKind == source.kind.rawValue
            && storedPersistentID == source.persistentID
            && storedSourceName == source.sourceName
            && Self.date(from: row, column: "startedAtUTC") == startedAtUTC
            && storedStartedOffset == startedUTCOffsetSeconds
            && storedStartPosition == max(startPosition, 0)
    }

    struct NormalizedListeningSlice {
        let localDay: String
        let utcOffsetSeconds: Int
        let actualListenedSeconds: Double
    }

    static func normalizedListeningSlices(
        _ daySlices: [ListeningDaySlice],
        eventID: UUID
    ) throws -> [NormalizedListeningSlice] {
        var values: [String: NormalizedListeningSlice] = [:]
        for slice in daySlices {
            guard slice.eventID == eventID,
                  slice.isValid,
                  Self.isValidListeningUTCOffset(slice.utcOffsetSeconds) else {
                throw LibraryDatabaseError.invalidListeningEvent
            }
            let seconds = slice.actualListenedSeconds
            guard seconds.isFinite, seconds >= 0 else {
                throw LibraryDatabaseError.invalidListeningEvent
            }
            let key = "\(slice.localDay.rawValue)\u{1F}\(slice.utcOffsetSeconds)"
            let normalized = NormalizedListeningSlice(
                localDay: slice.localDay.rawValue,
                utcOffsetSeconds: slice.utcOffsetSeconds,
                actualListenedSeconds: seconds
            )
            if let existing = values[key] {
                values[key] = NormalizedListeningSlice(
                    localDay: existing.localDay,
                    utcOffsetSeconds: existing.utcOffsetSeconds,
                    actualListenedSeconds: max(existing.actualListenedSeconds, seconds)
                )
            } else {
                values[key] = normalized
            }
        }
        return values.values.sorted {
            if $0.localDay == $1.localDay { return $0.utcOffsetSeconds < $1.utcOffsetSeconds }
            return $0.localDay < $1.localDay
        }
    }

    static func upsertListeningSlices(
        _ slices: [NormalizedListeningSlice],
        eventID: UUID,
        db database: Database
    ) throws {
        for slice in slices {
            guard ListeningLocalDay(slice.localDay) != nil else {
                throw LibraryDatabaseError.invalidListeningEvent
            }
            try database.execute(
                sql: """
                INSERT INTO listeningEventDays (eventId, localDay, utcOffsetSeconds, actualListenedSeconds)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(eventId, localDay, utcOffsetSeconds) DO UPDATE SET
                    actualListenedSeconds = MAX(
                        listeningEventDays.actualListenedSeconds,
                        excluded.actualListenedSeconds
                    )
                """,
                arguments: [eventID.uuidString, slice.localDay, slice.utcOffsetSeconds, slice.actualListenedSeconds]
            )
        }
    }

    static func validateListeningOccurrence(
        _ occurrence: ListeningEventOccurrence?,
        endReason: ListeningEventEndReason,
        listenedSeconds: Double,
        hasPersistedSkip: Bool
    ) throws {
        guard listenedSeconds.isFinite, listenedSeconds >= 0 else {
            throw LibraryDatabaseError.invalidListeningEvent
        }
        let skipRequired = endReason.isExplicitTrackDeparture
            && listenedSeconds >= ListeningHistoryThresholds.skipSeconds
        guard !skipRequired || occurrence != nil || hasPersistedSkip else {
            throw LibraryDatabaseError.invalidListeningOccurrence
        }
        guard occurrence != nil else { return }
        guard endReason.isExplicitTrackDeparture, listenedSeconds >= ListeningHistoryThresholds.skipSeconds else {
            throw LibraryDatabaseError.invalidListeningOccurrence
        }
    }

    static func validateListeningQualification(
        _ occurrence: ListeningEventOccurrence?,
        eventID: UUID,
        db database: Database
    ) throws {
        guard let openedDuration = try Double.fetchOne(
            database,
            sql: """
                SELECT s.openedDuration
                FROM listeningEvents e
                JOIN listeningMediaSnapshots s ON s.id = e.snapshotId
                WHERE e.id = ?
                """,
            arguments: [eventID.uuidString]
        ) else {
            throw LibraryDatabaseError.invalidListeningEvent
        }
        let listenedSeconds = try Double.fetchOne(
            database,
            sql: "SELECT COALESCE(SUM(actualListenedSeconds), 0) FROM listeningEventDays WHERE eventId = ?",
            arguments: [eventID.uuidString]
        ) ?? 0
        guard listenedSeconds.isFinite, openedDuration.isFinite else {
            throw LibraryDatabaseError.invalidListeningEvent
        }
        let hasPersistedQualification = try Bool.fetchOne(
            database,
            sql: "SELECT qualifiedAtUTC IS NOT NULL FROM listeningEvents WHERE id = ?",
            arguments: [eventID.uuidString]
        ) ?? false
        let thresholdReached = ListeningPlayThreshold(openedDuration: openedDuration).isReached(after: listenedSeconds)
        guard !thresholdReached || occurrence != nil || hasPersistedQualification else {
            throw LibraryDatabaseError.invalidListeningOccurrence
        }
        if occurrence != nil, !thresholdReached {
            throw LibraryDatabaseError.invalidListeningOccurrence
        }
    }

    static func finishedMutationMatches(
        row: Row,
        eventID: UUID,
        daySlices: [ListeningDaySlice],
        qualification: ListeningEventOccurrence?,
        skip: ListeningEventOccurrence? = nil,
        endedAtUTC: Date? = nil,
        endedUTCOffsetSeconds: Int? = nil,
        endPosition: TimeInterval? = nil,
        db database: Database
    ) throws -> Bool {
        let slices = try Self.normalizedListeningSlices(daySlices, eventID: eventID)
        guard try finishedSlicesMatch(slices, eventID: eventID, database: database) else { return false }
        guard finishedMetadataMatches(
            row,
            endedAtUTC: endedAtUTC,
            endedUTCOffsetSeconds: endedUTCOffsetSeconds,
            endPosition: endPosition
        ) else {
            return false
        }
        return try finishedOccurrencesMatch(
            row,
            qualification: qualification,
            skip: skip
        )
    }

    private static func finishedSlicesMatch(
        _ slices: [NormalizedListeningSlice],
        eventID: UUID,
        database: Database
    ) throws -> Bool {
        for slice in slices {
            let stored = try Double.fetchOne(
                database,
                sql: """
                SELECT actualListenedSeconds
                FROM listeningEventDays
                WHERE eventId = ? AND localDay = ? AND utcOffsetSeconds = ?
                """,
                arguments: [eventID.uuidString, slice.localDay, slice.utcOffsetSeconds]
            ) ?? 0
            guard stored >= slice.actualListenedSeconds else { return false }
        }
        return true
    }

    private static func finishedMetadataMatches(
        _ row: Row,
        endedAtUTC: Date?,
        endedUTCOffsetSeconds: Int?,
        endPosition: TimeInterval?
    ) -> Bool {
        if let endedAtUTC, Self.date(from: row, column: "endedAtUTC") != endedAtUTC { return false }
        if let endedUTCOffsetSeconds,
           (row["endedUTCOffsetSeconds"] as Int?) != endedUTCOffsetSeconds {
            return false
        }
        if let endPosition, (row["endPosition"] as Double?) != max(endPosition, 0) {
            return false
        }
        return true
    }

    private static func finishedOccurrencesMatch(
        _ row: Row,
        qualification: ListeningEventOccurrence?,
        skip: ListeningEventOccurrence?
    ) throws -> Bool {
        if let qualification {
            let stored = try Self.occurrence(
                from: row,
                timestampColumn: "qualifiedAtUTC",
                localDayColumn: "qualifiedLocalDay",
                offsetColumn: "qualifiedUTCOffsetSeconds"
            )
            guard stored == qualification else { return false }
        }
        if let skip {
            let stored = try Self.occurrence(
                from: row,
                timestampColumn: "skipAtUTC",
                localDayColumn: "skipLocalDay",
                offsetColumn: "skipUTCOffsetSeconds"
            )
            guard stored == skip else { return false }
        }
        return true
    }
}
