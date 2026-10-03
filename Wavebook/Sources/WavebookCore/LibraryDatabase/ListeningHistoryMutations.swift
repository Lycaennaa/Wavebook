import Foundation
import GRDB

extension LibraryDatabase {
    private struct BeginListeningEventRequest {
        let eventID: UUID
        let expectedGeneration: Int64
        let snapshotID: Int64
        let source: ListeningPlaybackSource
        let startedAtUTC: Date
        let startedUTCOffsetSeconds: Int
        let startPosition: TimeInterval
    }
    struct CheckpointListeningEventRequest {
        let eventID: UUID
        let expectedGeneration: Int64
        let checkpointAtUTC: Date
        let renderedPosition: TimeInterval
        let daySlices: [ListeningDaySlice]
        let qualification: ListeningEventOccurrence?
        let checkpointUTCOffsetSeconds: Int
        let forceRebase: Bool
        let checkpointSequence: Int64
    }
    /// Reads the current listening-history state.
    public func listeningHistoryState() throws -> ListeningHistoryState {
        try writer.read { database in
            try Self.listeningHistoryState(db: database)
        }
    }

    /// Reads health metrics for listening history persistence.
    public func listeningHistoryHealth() throws -> ListeningHistoryHealth {
        try writer.read { database in
            let state = try Self.listeningHistoryState(db: database)
            let openEventCount = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM listeningEvents WHERE endedAtUTC IS NULL"
            ) ?? 0
            let eventCount = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM listeningEvents") ?? 0
            let snapshotCount = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM listeningMediaSnapshots") ?? 0
            return ListeningHistoryHealth(
                state: state,
                openEventCount: openEventCount,
                eventCount: eventCount,
                snapshotCount: snapshotCount
            )
        }
    }

    /// Enables or disables private listening-history mode.
    @discardableResult
    public func saveListeningHistoryPrivateMode(_ isPrivate: Bool) throws -> ListeningHistoryState {
        try writer.write { database in
            let current = try Self.listeningHistoryState(db: database)
            var generation = current.generation
            if current.isPrivate != isPrivate {
                guard generation < Int64.max else { throw LibraryDatabaseError.invalidListeningEvent }
                generation += 1
            }
            if isPrivate {
                try database.execute(
                    sql: """
                    UPDATE listeningEvents
                    SET endedAtUTC = COALESCE(lastDurableCheckpointAtUTC, startedAtUTC),
                        endedUTCOffsetSeconds = COALESCE(
                            lastDurableCheckpointUTCOffsetSeconds,
                            startedUTCOffsetSeconds
                        ),
                        endPosition = COALESCE(endPosition, startPosition),
                        endReason = ?
                    WHERE endedAtUTC IS NULL
                    """,
                    arguments: [ListeningEventEndReason.privateModeBoundary.rawValue]
                )
                try database.execute(
                    sql: """
                    DELETE FROM listeningMediaSnapshots
                    WHERE NOT EXISTS (
                        SELECT 1 FROM listeningEvents
                        WHERE listeningEvents.snapshotId = listeningMediaSnapshots.id
                    )
                    """
                )
            }
            try database.execute(
                sql: "UPDATE listeningHistoryState SET generation = ?, isPrivate = ? WHERE id = 1",
                arguments: [generation, isPrivate]
            )
            return try Self.listeningHistoryState(db: database)
        }
    }

    /// Sets private listening-history mode.
    @discardableResult
    public func setListeningHistoryPrivate(_ isPrivate: Bool) throws -> ListeningHistoryState {
        try saveListeningHistoryPrivateMode(isPrivate)
    }

    /// Creates or reuses a persisted listening-media snapshot.
    public func createOrReuseListeningSnapshot(
        _ snapshot: ListeningMediaSnapshot,
        expectedGeneration: Int64
    ) throws -> ListeningMediaSnapshot {
        return try writer.write { database in
            try Self.createOrReuseListeningSnapshot(
                snapshot,
                expectedGeneration: expectedGeneration,
                database: database
            )
        }
    }

    private static func createOrReuseListeningSnapshot(
        _ snapshot: ListeningMediaSnapshot,
        expectedGeneration: Int64,
        database: Database
    ) throws -> ListeningMediaSnapshot {
        let state = try Self.listeningHistoryState(db: database)
        guard state.generation == expectedGeneration else {
            throw LibraryDatabaseError.staleListeningGeneration(expectedGeneration)
        }
        guard !state.isPrivate else {
            throw LibraryDatabaseError.privateListeningHistory
        }
        guard snapshot.id != nil || snapshot.liveTrackID != nil else {
            throw LibraryDatabaseError.invalidListeningSnapshot
        }
        if let snapshotID = snapshot.id {
            return try existingListeningSnapshot(id: snapshotID, snapshot: snapshot, database: database)
        }
        if let liveTrackID = snapshot.liveTrackID,
           let row = try Row.fetchOne(
               database,
               sql: "SELECT * FROM listeningMediaSnapshots WHERE liveTrackId = ? AND metadataSignature = ? LIMIT 1",
               arguments: [liveTrackID, snapshot.metadataSignature]
           ) {
            return try Self.listeningSnapshot(from: row, db: database)
        }
        return try insertListeningSnapshot(snapshot, database: database)
    }

    private static func existingListeningSnapshot(
        id: Int64,
        snapshot: ListeningMediaSnapshot,
        database: Database
    ) throws -> ListeningMediaSnapshot {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT * FROM listeningMediaSnapshots WHERE id = ?",
            arguments: [id]
        ) else {
            throw LibraryDatabaseError.invalidListeningSnapshot
        }
        let storedSignature: String = row["metadataSignature"]
        guard storedSignature == snapshot.metadataSignature else {
            throw LibraryDatabaseError.invalidListeningSnapshot
        }
        return try Self.listeningSnapshot(from: row, db: database)
    }

    private static func insertListeningSnapshot(
        _ snapshot: ListeningMediaSnapshot,
        database: Database
    ) throws -> ListeningMediaSnapshot {
        try database.execute(
            sql: """
            INSERT INTO listeningMediaSnapshots (
                liveTrackId, metadataSignature, title, artistDisplay, albumTitle, albumOwner,
                genreDisplay, openedDuration, format, createdAtUTC
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                snapshot.liveTrackID,
                snapshot.metadataSignature,
                snapshot.title,
                snapshot.artistDisplay,
                snapshot.albumTitle,
                snapshot.albumOwner,
                snapshot.genreDisplay,
                snapshot.openedDuration,
                snapshot.format,
                Self.databaseTimestamp(snapshot.createdAtUTC) ?? 0
            ]
        )
        let snapshotID = database.lastInsertedRowID
        for (ordinal, value) in snapshot.artists.enumerated() {
            try database.execute(
                sql: "INSERT INTO listeningSnapshotArtists (snapshotId, ordinal, displayValue) VALUES (?, ?, ?)",
                arguments: [snapshotID, ordinal, value]
            )
        }
        for (ordinal, value) in snapshot.genres.enumerated() {
            try database.execute(
                sql: "INSERT INTO listeningSnapshotGenres (snapshotId, ordinal, displayValue) VALUES (?, ?, ?)",
                arguments: [snapshotID, ordinal, value]
            )
        }
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT * FROM listeningMediaSnapshots WHERE id = ?",
            arguments: [snapshotID]
        ) else {
            throw LibraryDatabaseError.invalidListeningSnapshot
        }
        return try Self.listeningSnapshot(from: row, db: database)
    }

    /// Creates or reuses a snapshot from a library track.
    public func createOrReuseListeningSnapshot(
        track: Track,
        openedDuration: TimeInterval,
        openedFormat: String,
        createdAtUTC: Date = Date(),
        expectedGeneration: Int64
    ) throws -> ListeningMediaSnapshot {
        guard let snapshot = ListeningMediaSnapshot(
            liveTrackID: track.id,
            track: track,
            openedDuration: openedDuration,
            openedFormat: openedFormat,
            createdAtUTC: createdAtUTC
        ) else {
            throw LibraryDatabaseError.invalidListeningSnapshot
        }
        return try createOrReuseListeningSnapshot(snapshot, expectedGeneration: expectedGeneration)
    }

    /// Starts a listening event for a persisted snapshot.
    @discardableResult
    public func beginListeningEvent(
        eventID: UUID = UUID(),
        expectedGeneration: Int64,
        snapshotID: Int64,
        source: ListeningPlaybackSource = ListeningPlaybackSource(kind: .library),
        startedAtUTC: Date = Date(),
        startedUTCOffsetSeconds: Int = 0,
        startPosition: TimeInterval = 0
    ) throws -> ListeningHistoryMutationResult {
        let request = BeginListeningEventRequest(
            eventID: eventID,
            expectedGeneration: expectedGeneration,
            snapshotID: snapshotID,
            source: source,
            startedAtUTC: startedAtUTC,
            startedUTCOffsetSeconds: startedUTCOffsetSeconds,
            startPosition: startPosition
        )
        guard request.startedAtUTC.timeIntervalSinceReferenceDate.isFinite,
              request.startPosition.isFinite,
              Self.isValidListeningUTCOffset(request.startedUTCOffsetSeconds) else {
            throw LibraryDatabaseError.invalidListeningEvent
        }

        return try writer.write { database in
            try Self.beginListeningEvent(request: request, database: database)
        }
    }

    private static func beginListeningEvent(
        request: BeginListeningEventRequest,
        database: Database
    ) throws -> ListeningHistoryMutationResult {
        let state = try Self.listeningHistoryState(db: database)
        guard state.generation == request.expectedGeneration else { return .staleGeneration }
        guard !state.isPrivate else { return .privateMode }
        guard try Int64.fetchOne(
            database,
            sql: "SELECT id FROM listeningMediaSnapshots WHERE id = ?",
            arguments: [request.snapshotID]
        ) != nil else {
            throw LibraryDatabaseError.invalidListeningSnapshot
        }

        if let row = try Row.fetchOne(
            database,
            sql: "SELECT * FROM listeningEvents WHERE id = ?",
            arguments: [request.eventID.uuidString]
        ) {
            guard Self.eventStartMatches(
                row: row,
                generation: request.expectedGeneration,
                snapshotID: request.snapshotID,
                source: request.source,
                startedAtUTC: request.startedAtUTC,
                startedUTCOffsetSeconds: request.startedUTCOffsetSeconds,
                startPosition: request.startPosition
            ) else {
                throw LibraryDatabaseError.listeningEventIDCollision(request.eventID)
            }
            return .applied
        }

        try Self.insertListeningEvent(request: request, database: database)
        return .applied
    }

    private static func insertListeningEvent(
        request: BeginListeningEventRequest,
        database: Database
    ) throws {
        try database.execute(
            sql: """
            INSERT INTO listeningEvents (
                id, historyGeneration, snapshotId, sourceKind, sourcePersistentID, sourceName,
                startedAtUTC, startedUTCOffsetSeconds, startPosition
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                request.eventID.uuidString,
                request.expectedGeneration,
                request.snapshotID,
                request.source.kind.rawValue,
                request.source.persistentID,
                request.source.sourceName,
                Self.databaseTimestamp(request.startedAtUTC) ?? 0,
                request.startedUTCOffsetSeconds,
                max(request.startPosition, 0)
            ]
        )
    }

    /// Persists a checkpoint for an active listening event.
    @discardableResult
    public func checkpointListeningEvent(
        eventID: UUID,
        expectedGeneration: Int64,
        checkpointAtUTC: Date,
        renderedPosition: TimeInterval,
        daySlices: [ListeningDaySlice],
        qualification: ListeningEventOccurrence? = nil,
        checkpointUTCOffsetSeconds: Int = 0,
        forceRebase: Bool = false,
        checkpointSequence: Int64 = 0
    ) throws -> ListeningHistoryMutationResult {
        let request = CheckpointListeningEventRequest(
            eventID: eventID,
            expectedGeneration: expectedGeneration,
            checkpointAtUTC: checkpointAtUTC,
            renderedPosition: renderedPosition,
            daySlices: daySlices,
            qualification: qualification,
            checkpointUTCOffsetSeconds: checkpointUTCOffsetSeconds,
            forceRebase: forceRebase,
            checkpointSequence: checkpointSequence
        )
        guard request.checkpointAtUTC.timeIntervalSinceReferenceDate.isFinite,
              request.renderedPosition.isFinite,
              request.checkpointSequence >= 0,
              Self.isValidListeningUTCOffset(request.checkpointUTCOffsetSeconds) else {
            throw LibraryDatabaseError.invalidListeningEvent
        }
        return try Self.checkpointListeningEvent(request: request, writer: writer)
    }

    /// Finalizes abandoned listening events for a generation.
    @discardableResult
    public func recoverAbandonedListeningEvents(
        expectedGeneration: Int64? = nil,
        at _: Date = Date()
    ) throws -> ListeningHistoryRecoveryResult {
        let generation = try listeningHistoryState().generation
        guard expectedGeneration == nil || expectedGeneration == generation else { return .staleGeneration }
        return try writer.write { database in
            guard try Self.listeningHistoryState(db: database).generation == generation else { return .staleGeneration }
            try database.execute(
                sql: """
                UPDATE listeningEvents
                SET endedAtUTC = COALESCE(lastDurableCheckpointAtUTC, startedAtUTC),
                    endedUTCOffsetSeconds = COALESCE(lastDurableCheckpointUTCOffsetSeconds, startedUTCOffsetSeconds),
                    endPosition = COALESCE(endPosition, startPosition),
                    endReason = ?
                WHERE endedAtUTC IS NULL AND historyGeneration = ?
                """,
                arguments: [ListeningEventEndReason.abandoned.rawValue, generation]
            )
            return .finalized(database.changesCount)
        }
    }

    /// Resets listening history and advances its generation.
    public func resetListeningHistory(at timestamp: Date = Date()) throws -> ListeningHistoryState {
        guard timestamp.timeIntervalSinceReferenceDate.isFinite else {
            throw LibraryDatabaseError.invalidListeningEvent
        }
        return try writer.write { database in
            let current = try Self.listeningHistoryState(db: database)
            guard current.generation < Int64.max else {
                throw LibraryDatabaseError.invalidListeningEvent
            }
            try database.execute(sql: "DELETE FROM listeningEventDays")
            try database.execute(sql: "DELETE FROM listeningEvents")
            try database.execute(sql: "DELETE FROM listeningMediaSnapshots")
            try database.execute(
                sql: "UPDATE listeningHistoryState SET generation = ?, trackingStartedAtUTC = ? WHERE id = 1",
                arguments: [current.generation + 1, Self.databaseTimestamp(timestamp) ?? 0]
            )
            return try Self.listeningHistoryState(db: database)
        }
    }

    /// Loads a listening snapshot by identifier.
    public func listeningSnapshot(id: Int64) throws -> ListeningMediaSnapshot? {
        try writer.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM listeningMediaSnapshots WHERE id = ?",
                arguments: [id]
            ) else {
                return nil
            }
            return try Self.listeningSnapshot(from: row, db: database)
        }
    }

    /// Loads a listening event by identifier.
    public func listeningEvent(id: UUID) throws -> ListeningEvent? {
        try writer.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM listeningEvents WHERE id = ?",
                arguments: [id.uuidString]
            ) else {
                return nil
            }
            return try Self.listeningEvent(from: row, db: database)
        }
    }
}

extension LibraryDatabase {
    /// Reads the listened duration for an event-day slice.
    public func listeningEventDaySlice(
        eventID: UUID,
        localDay: ListeningLocalDay,
        utcOffsetSeconds: Int
    ) throws -> TimeInterval? {
        guard Self.isValidListeningUTCOffset(utcOffsetSeconds) else {
            throw LibraryDatabaseError.invalidListeningEvent
        }
        return try writer.read { database in
            try Double.fetchOne(
                database,
                sql: """
                SELECT actualListenedSeconds
                FROM listeningEventDays
                WHERE eventId = ? AND localDay = ? AND utcOffsetSeconds = ?
                """,
                arguments: [eventID.uuidString, localDay.rawValue, utcOffsetSeconds]
            )
        }
    }

    /// Persists the listened duration for an event-day slice.
    @discardableResult
    public func upsertListeningEventDaySlice(
        eventID: UUID,
        expectedGeneration: Int64,
        localDay: ListeningLocalDay,
        utcOffsetSeconds: Int,
        actualListenedSeconds: TimeInterval
    ) throws -> ListeningHistoryMutationResult {
        guard actualListenedSeconds.isFinite,
              actualListenedSeconds >= 0,
              Self.isValidListeningUTCOffset(utcOffsetSeconds) else {
            throw LibraryDatabaseError.invalidListeningEvent
        }
        return try writer.write { database in
            let state = try Self.listeningHistoryState(db: database)
            guard state.generation == expectedGeneration else { return .staleGeneration }
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT historyGeneration, endedAtUTC FROM listeningEvents WHERE id = ?",
                arguments: [eventID.uuidString]
            ) else {
                return .missingEvent
            }
            guard (row["historyGeneration"] as Int64) == expectedGeneration else {
                return .staleGeneration
            }
            if row["endedAtUTC"] != nil {
                throw LibraryDatabaseError.listeningEventAlreadyFinished(eventID)
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
                arguments: [eventID.uuidString, localDay.rawValue, utcOffsetSeconds, actualListenedSeconds]
            )
            return .applied
        }
    }
}
