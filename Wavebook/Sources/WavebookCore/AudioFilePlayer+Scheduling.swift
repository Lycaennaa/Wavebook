import AVFoundation
import Foundation

extension AudioFilePlayer {
    internal func schedulePlaybackPlan(
        _ plan: AudioPlaybackPlan,
        for file: AVAudioFile,
        url: URL
    ) throws {
        stopScheduledPlayback()
        currentDuration = plan.duration
        currentTrailingSilenceDuration = plan.trailingSilenceDuration
        currentPlaybackSchedule = .empty
        automaticSkipBoundaryIndex = 0
        accumulatedElapsed = plan.startTime
        renderBaselineSampleTime = 0
        audibleElapsedAtRenderBaseline = 0
        audibleElapsedAtPlaybackStart = 0
        currentPlaybackRange = currentPlaybackSchedule.firstRange
        if plan.ranges.isEmpty {
            accumulatedElapsed = plan.duration
            guard shouldBePlaying else { return }
            let id = playbackID
            Task { @MainActor [weak self] in
                guard let self,
                      self.playbackID == id,
                      self.currentURL == url,
                      self.shouldBePlaying else { return }
                self.finishPlayback(at: plan.duration)
            }
            return
        }
        if shouldBePlaying, !engine.isRunning {
            try engine.start()
        }
        let scheduledPlayback = playbackScheduler.schedule(
            file: file,
            url: url,
            ranges: plan.ranges,
            playbackID: playbackID
        )
        currentPlaybackSchedule = scheduledPlayback
        currentPlaybackRange = scheduledPlayback.firstRange
        if shouldBePlaying {
            player.play()
            playbackStartedAt = ProcessInfo.processInfo.systemUptime
        } else {
            playbackStartedAt = nil
        }
    }
}
