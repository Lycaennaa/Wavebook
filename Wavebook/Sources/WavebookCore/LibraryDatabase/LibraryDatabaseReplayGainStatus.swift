import Foundation
import GRDB

struct ReplayGainAnalysisDatabaseSnapshot: Sendable {
    let counts: ReplayGainAnalysisStatusCounts
    let progress: ReplayGainAnalysisProgress
}

extension LibraryDatabase {
    func replayGainAnalysisStatusSnapshot() throws -> ReplayGainAnalysisDatabaseSnapshot {
        try writer.read { database in
            guard let row = try Row.fetchOne(database, sql: """
                SELECT
                    COALESCE(SUM(CASE WHEN analysisState = ? THEN 1 ELSE 0 END), 0) AS pending,
                    COALESCE(SUM(CASE WHEN analysisState = ? THEN 1 ELSE 0 END), 0) AS running,
                    COALESCE(SUM(CASE WHEN analysisState = ? THEN 1 ELSE 0 END), 0) AS ready,
                    COALESCE(SUM(CASE WHEN analysisState = ? THEN 1 ELSE 0 END), 0) AS failed,
                    COUNT(*) AS total,
                    COALESCE(SUM(CASE
                        WHEN trackGainDB IS NOT NULL AND trackPeak IS NOT NULL THEN 1 ELSE 0
                    END), 0) AS trackCompleted,
                    COALESCE(SUM(CASE
                        WHEN albumGainDB IS NOT NULL AND albumPeak IS NOT NULL THEN 1 ELSE 0
                    END), 0) AS albumCompleted
                FROM replayGainAnalysis
                """, arguments: [
                    ReplayGainAnalysisState.pending.rawValue,
                    ReplayGainAnalysisState.running.rawValue,
                    ReplayGainAnalysisState.ready.rawValue,
                    ReplayGainAnalysisState.failed.rawValue
                ]) else {
                return ReplayGainAnalysisDatabaseSnapshot(
                    counts: ReplayGainAnalysisStatusCounts(),
                    progress: ReplayGainAnalysisProgress()
                )
            }
            return ReplayGainAnalysisDatabaseSnapshot(
                counts: ReplayGainAnalysisStatusCounts(
                    pending: row["pending"],
                    running: row["running"],
                    ready: row["ready"],
                    failed: row["failed"]
                ),
                progress: ReplayGainAnalysisProgress(
                    total: row["total"],
                    trackCompleted: row["trackCompleted"],
                    albumCompleted: row["albumCompleted"]
                )
            )
        }
    }

    /// Returns replay-gain analysis counts by state.
    public func replayGainStatusCounts() throws -> ReplayGainAnalysisStatusCounts {
        try replayGainAnalysisStatusSnapshot().counts
    }

    /// Returns track and album completion progress.
    public func replayGainAnalysisProgress() throws -> ReplayGainAnalysisProgress {
        try replayGainAnalysisStatusSnapshot().progress
    }
}

extension LibraryDatabase {
    /// Returns replay-gain failures ordered by time.
    public func replayGainFailures(limit: Int = 100) throws -> [ReplayGainAnalysisFailure] {
        let limit = min(max(0, limit), 1_000)
        return try writer.read { database in
            try Row.fetchAll(database, sql: """
                SELECT tracks.id, tracks.path, replayGainAnalysis.errorReason, replayGainAnalysis.errorAt
                FROM replayGainAnalysis
                JOIN tracks ON tracks.id = replayGainAnalysis.trackId
                WHERE replayGainAnalysis.analysisState = ?
                  AND replayGainAnalysis.errorReason IS NOT NULL
                  AND replayGainAnalysis.errorAt IS NOT NULL
                ORDER BY replayGainAnalysis.errorAt DESC, tracks.id
                LIMIT ?
                """, arguments: [ReplayGainAnalysisState.failed.rawValue, limit]).map { row in
                    ReplayGainAnalysisFailure(
                        trackID: row["id"],
                        path: row["path"],
                        reason: row["errorReason"],
                        timestamp: row["errorAt"]
                    )
                }
        }
    }
}
