import Foundation
import GRDB

extension LibraryDatabase {
    /// Values that are recorded when the event finishes.
    public struct FinishListeningEventDetails {
        /// UTC offset, in seconds, at the end of the event.
        public let endedUTCOffsetSeconds: Int
        /// Final rendered playback position.
        public let endPosition: TimeInterval
        /// Listening time attributed to each local day.
        public let daySlices: [ListeningDaySlice]
        /// The qualification occurrence, if the event qualified.
        public let qualification: ListeningEventOccurrence?
        /// The skip occurrence, if the event was skipped.
        public let skip: ListeningEventOccurrence?

        /// Creates the values recorded when an event finishes.
        public init(
            endedUTCOffsetSeconds: Int = 0,
            endPosition: TimeInterval = 0,
            daySlices: [ListeningDaySlice],
            qualification: ListeningEventOccurrence? = nil,
            skip: ListeningEventOccurrence? = nil
        ) {
            self.endedUTCOffsetSeconds = endedUTCOffsetSeconds
            self.endPosition = endPosition
            self.daySlices = daySlices
            self.qualification = qualification
            self.skip = skip
        }
    }

    /// Describes values used to finish a listening event.
    public struct FinishListeningEventRequest {

        /// Identifier of the event being finished.
        public let eventID: UUID
        /// Generation that must still be active for the write to apply.
        public let expectedGeneration: Int64
        /// UTC timestamp at which the event finished.
        public let endedAtUTC: Date
        /// UTC offset and occurrences recorded at event completion.
        public let endedUTCOffsetSeconds: Int
        /// Final rendered playback position.
        public let endPosition: TimeInterval
        /// Reason the event ended.
        public let endReason: ListeningEventEndReason
        /// Listening time attributed to each local day.
        public let daySlices: [ListeningDaySlice]
        /// The qualification occurrence, if the event qualified.
        public let qualification: ListeningEventOccurrence?
        /// The skip occurrence, if the event was skipped.
        public let skip: ListeningEventOccurrence?

        /// Creates a request to finish a listening event.
        public init(
            eventID: UUID,
            expectedGeneration: Int64,
            endedAtUTC: Date,
            endReason: ListeningEventEndReason,
            details: FinishListeningEventDetails
        ) {
            self.eventID = eventID
            self.expectedGeneration = expectedGeneration
            self.endedAtUTC = endedAtUTC
            self.endedUTCOffsetSeconds = details.endedUTCOffsetSeconds
            self.endPosition = details.endPosition
            self.endReason = endReason
            self.daySlices = details.daySlices
            self.qualification = details.qualification
            self.skip = details.skip
        }
    }

    /// Finishes an active listening event and persists its results.
    @discardableResult
    public func finishListeningEvent(
        request: FinishListeningEventRequest
    ) throws -> ListeningHistoryMutationResult {
        guard request.endedAtUTC.timeIntervalSinceReferenceDate.isFinite,
              request.endPosition.isFinite,
              Self.isValidListeningUTCOffset(request.endedUTCOffsetSeconds) else {
            throw LibraryDatabaseError.invalidListeningEvent
        }

        return try writer.write { database in
            try Self.finishListeningEvent(request: request, database: database)
        }
    }

    private static func finishExistingListeningEvent(
        row: Row,
        request: FinishListeningEventRequest,
        existingEndReason: String,
        database: Database
    ) throws -> ListeningHistoryMutationResult {
        guard existingEndReason == request.endReason.rawValue else {
            throw LibraryDatabaseError.listeningEventAlreadyFinished(request.eventID)
        }
        return try Self.finishedMutationMatches(
            row: row,
            eventID: request.eventID,
            daySlices: request.daySlices,
            qualification: request.qualification,
            skip: request.skip,
            endedAtUTC: request.endedAtUTC,
            endedUTCOffsetSeconds: request.endedUTCOffsetSeconds,
            endPosition: request.endPosition,
            db: database
        ) ? .applied : .alreadyFinished
    }

    private static func applyFinishedListeningEvent(
        request: FinishListeningEventRequest,
        row: Row,
        database: Database
    ) throws -> ListeningHistoryMutationResult {
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
        try Self.validateListeningQualification(request.qualification, eventID: request.eventID, db: database)
        try Self.validateListeningOccurrence(
            request.skip,
            endReason: request.endReason,
            listenedSeconds: listenedSeconds,
            hasPersistedSkip: row["skipAtUTC"] != nil
        )
        try Self.updateListeningEvent(
            db: database,
            eventID: request.eventID,
            checkpointAtUTC: request.endedAtUTC,
            renderedPosition: request.endPosition,
            checkpointUTCOffsetSeconds: request.endedUTCOffsetSeconds,
            forceProgress: listenedSeconds > previousListenedSeconds,
            checkpointSequence: nil,
            endReason: request.endReason,
            endedUTCOffsetSeconds: request.endedUTCOffsetSeconds,
            qualification: request.qualification,
            skip: request.skip,
            finish: true
        )
        return .applied
    }

    private static func finishListeningEvent(
        request: FinishListeningEventRequest,
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
        guard (row["historyGeneration"] as Int64) == request.expectedGeneration else {
            return .staleGeneration
        }
        if let existingEndReason: String = row["endReason"] {
            return try Self.finishExistingListeningEvent(
                row: row,
                request: request,
                existingEndReason: existingEndReason,
                database: database
            )
        }
        return try Self.applyFinishedListeningEvent(request: request, row: row, database: database)
    }
}

extension LibraryDatabase.FinishListeningEventRequest {
    /// Backward-compatible name for finish-event details.
    public typealias Details = LibraryDatabase.FinishListeningEventDetails
}
