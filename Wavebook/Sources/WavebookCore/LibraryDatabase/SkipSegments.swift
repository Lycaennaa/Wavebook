import Foundation
import GRDB

extension LibraryDatabase {
    static let maximumSkipSegmentCount = 256

    /// Returns skip segments for a track path.
    public func skipSegments(forTrackPath path: String) throws -> [AudioSkipSegment] {
        try writer.read { database in
            try Row.fetchAll(
                database,
                sql: """
                SELECT id, startTime, endTime
                FROM trackSkipSegments
                WHERE trackId = (SELECT id FROM tracks WHERE path = ?)
                ORDER BY startTime, id
                """,
                arguments: [path]
            ).map { row in
                let rawID: String = row["id"]
                guard let id = UUID(uuidString: rawID) else {
                    throw LibraryDatabaseError.invalidSchema("Skip segment has an invalid identifier")
                }
                return AudioSkipSegment(id: id, startTime: row["startTime"], endTime: row["endTime"])
            }
        }
    }

    /// Replaces skip segments for a track path.
    public func saveSkipSegments(_ segments: [AudioSkipSegment], forTrackPath path: String) throws {
        try Self.validateSkipSegments(segments)
        let sortedSegments = segments.sorted {
            $0.startTime == $1.startTime ? $0.endTime < $1.endTime : $0.startTime < $1.startTime
        }
        try writer.write { database in
            guard let trackID = try Int64.fetchOne(
                database,
                sql: "SELECT id FROM tracks WHERE path = ?",
                arguments: [path]
            ) else {
                throw LibraryDatabaseError.missingTrack(path)
            }
            try database.execute(
                sql: "DELETE FROM trackSkipSegments WHERE trackId = ?",
                arguments: [trackID]
            )
            for segment in sortedSegments {
                try database.execute(
                    sql: "INSERT INTO trackSkipSegments (id, trackId, startTime, endTime) VALUES (?, ?, ?, ?)",
                    arguments: [segment.id.uuidString, trackID, segment.startTime, segment.endTime]
                )
            }
        }
    }

    private static func validateSkipSegments(_ segments: [AudioSkipSegment]) throws {
        guard segments.count <= maximumSkipSegmentCount else {
            throw LibraryDatabaseError.invalidSkipSegment(
                "no more than \(maximumSkipSegmentCount) segments are supported"
            )
        }
        var identifiers = Set<UUID>()
        let sortedSegments = segments.sorted {
            $0.startTime == $1.startTime ? $0.endTime < $1.endTime : $0.startTime < $1.startTime
        }
        for segment in sortedSegments {
            guard segment.startTime.isFinite,
                  segment.endTime.isFinite,
                  segment.startTime >= 0,
                  segment.endTime > segment.startTime else {
                throw LibraryDatabaseError.invalidSkipSegment(
                    "each segment must have a finite nonnegative start before its end"
                )
            }
            guard identifiers.insert(segment.id).inserted else {
                throw LibraryDatabaseError.invalidSkipSegment("segment identifiers must be unique")
            }
        }
        for pair in zip(sortedSegments, sortedSegments.dropFirst()) {
            guard pair.0.endTime <= pair.1.startTime else {
                throw LibraryDatabaseError.invalidSkipSegment("segments must not overlap")
            }
        }
    }
}
