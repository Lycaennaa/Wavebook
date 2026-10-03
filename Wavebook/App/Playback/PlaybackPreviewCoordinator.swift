import Foundation
import WavebookCore

@MainActor
final class PlaybackPreviewCoordinator {
    private let history: PlaybackHistoryController
    private var pendingHistory = PlaybackPreviewHistoryContext()
    private var previewHadTrackedSession = false

    init(history: PlaybackHistoryController) {
        self.history = history
    }

    func beginSegmentEditorPreview() {
        if !history.isUntrackedPreviewActive {
            previewHadTrackedSession = history.tracker?.activeEventID != nil
        }
        history.beginUntrackedPreview()
    }

    func endSegmentEditorPreview(
        restoringPendingHistory: Bool,
        currentTrack: Track?,
        hasAudioSource: Bool,
        elapsed: TimeInterval,
        source: ListeningPlaybackSource,
        preservePendingHistory: Bool = false
    ) {
        let wasPreviewActive = history.isUntrackedPreviewActive
        let shouldStartNormalHistory = wasPreviewActive && !previewHadTrackedSession
        previewHadTrackedSession = false
        history.endUntrackedPreview()

        guard restoringPendingHistory else {
            if !preservePendingHistory {
                discardPendingHistory()
            }
            return
        }
        if let pending = pendingHistory.takeAwaitingPreview() {
            guard currentTrack?.path == pending.track.path, hasAudioSource else { return }
            _ = history.startPlayback(
                for: pending.track,
                source: pending.source,
                initialPosition: elapsed
            )
            return
        }
        guard shouldStartNormalHistory,
              let track = currentTrack,
              hasAudioSource,
              history.tracker?.activeEventID == nil,
              history.tracker?.isPrivateMode != true else { return }
        _ = history.startPlayback(for: track, source: source, initialPosition: elapsed)
    }

    func restoreAfterCanceledTermination(
        currentTrack: Track?,
        hasAudioSource: Bool,
        elapsed: TimeInterval,
        source: ListeningPlaybackSource
    ) {
        if let pending = pendingHistory.takeAwaitingPreview() {
            guard currentTrack?.path == pending.track.path, hasAudioSource else { return }
            _ = history.startPlayback(
                for: pending.track,
                source: pending.source,
                initialPosition: elapsed
            )
            return
        }
        guard !pendingHistory.hasPending,
              let track = currentTrack,
              hasAudioSource,
              history.tracker?.activeEventID == nil,
              history.tracker?.isPrivateMode != true else { return }
        _ = history.startPlayback(for: track, source: source, initialPosition: elapsed)
    }

    func discardPendingHistory() {
        pendingHistory.clear()
    }

    func setPendingHistoryStart(
        _ track: Track,
        source: ListeningPlaybackSource
    ) {
        pendingHistory.setAwaitingAnalysis(for: track, source: source)
    }

    func silenceAnalysisCompleted(successfully: Bool, at position: TimeInterval?) {
        guard let pending = pendingHistory.resolveAnalysis(
            successfully: successfully,
            position: position,
            whilePreviewing: history.isUntrackedPreviewActive
        ) else { return }
        _ = history.startPlayback(
            for: pending.track,
            source: pending.source,
            initialPosition: pending.position
        )
    }

    @discardableResult
    func restorePendingHistoryAfterSeek(at position: TimeInterval) -> Bool {
        guard let pending = pendingHistory.takePending() else { return false }
        _ = history.startPlayback(
            for: pending.track,
            source: pending.source,
            initialPosition: position
        )
        return true

    }

}
