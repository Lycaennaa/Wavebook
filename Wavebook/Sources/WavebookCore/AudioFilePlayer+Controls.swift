import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

extension AudioFilePlayer {
    /// Seeks playback to a position in the current file.
    @discardableResult
    public func seek(to seconds: TimeInterval, bypassAutomaticSkips: Bool = false) throws -> Bool {
        guard let currentURL, currentDuration > 0 else { return false }
        let validatedFile: AVAudioFile?
        if bypassAutomaticSkips {
            validatedFile = try AVAudioFile(forReading: currentURL)
        } else {
            validatedFile = nil
        }
        if bypassAutomaticSkips {
            automaticSkipsDisabledForPlayback = true
        }
        if silenceAnalysisTask != nil, !automaticSkipsDisabledForPlayback {
            let requestedPosition = seconds.isFinite
                ? min(max(seconds, 0), currentDuration)
                : 0
            playbackID += 1
            silenceAnalysisTask?.cancel()
            silenceAnalysisTask = nil
            stopScheduledPlayback()
            currentPlaybackRange = nil
            accumulatedElapsed = requestedPosition
            renderBaselineSampleTime = nil
            playbackStartedAt = nil
            startSilenceAnalysis(
                for: currentURL,
                requestedStartTime: requestedPosition,
                playbackID: playbackID
            )
            return true
        }
        if silenceAnalysisTask != nil {
            playbackID += 1
            silenceAnalysisTask?.cancel()
            silenceAnalysisTask = nil
            stopScheduledPlayback()
            currentPlaybackRange = nil
            renderBaselineSampleTime = nil
            playbackStartedAt = nil
        }

        let file: AVAudioFile
        if let validatedFile {
            file = validatedFile
        } else {
            file = try AVAudioFile(forReading: currentURL)
        }

        playbackID += 1
        let seekState = playbackStateToken
        let plan = makePlaybackPlan(for: file, url: currentURL, requestedStartTime: seconds)
        notifySilentSegmentsDetected(
            leadingDuration: plan.leadingSilenceSkippedDuration,
            trailingDuration: plan.trailingSilenceDuration
        )
        guard isCurrent(seekState) else { return true }
        try schedulePlaybackPlan(plan, for: file, url: currentURL)
        return true
    }

    /// Pauses playback while preserving the current position.
    public func pause() {
        let elapsed = elapsedTime
        let sampleTime = currentRenderSampleTime
        let audibleOffset = self.audibleElapsed(forSourcePosition: elapsed)
        if silenceAnalysisTask != nil {
            playbackID += 1
            silenceAnalysisTask?.cancel()
            silenceAnalysisTask = nil
        }
        accumulatedElapsed = elapsed
        renderBaselineSampleTime = sampleTime
        audibleElapsedAtRenderBaseline = audibleOffset
        audibleElapsedAtPlaybackStart = audibleOffset
        player.pause()
        engine.stop()
        shouldBePlaying = false
        playbackStartedAt = nil
    }

    /// Resumes playback from the current position.
    public func resume() throws {
        guard let url = currentURL else { return }
        if silenceAnalysisTask != nil {
            shouldBePlaying = true
            playbackStartedAt = nil
            return
        }
        guard currentPlaybackRange != nil else {
            if skipSilentSegments, !automaticSkipsDisabledForPlayback {
                shouldBePlaying = true
                playbackStartedAt = nil
                startSilenceAnalysis(for: url, requestedStartTime: accumulatedElapsed, playbackID: playbackID)
                return
            }
            let file = try AVAudioFile(forReading: url)
            let plan = makePlaybackPlan(
                for: file,
                url: url,
                requestedStartTime: accumulatedElapsed,
                analyzeSilence: false
            )
            shouldBePlaying = true
            do {
                try schedulePlaybackPlan(plan, for: file, url: url)
            onSilenceAnalysisCompleted?(false, nil)
            } catch {
                shouldBePlaying = false
                throw error
            }
            return
        }
        if !engine.isRunning { try engine.start() }
        player.play()
        shouldBePlaying = true
        playbackStartedAt = ProcessInfo.processInfo.systemUptime
    }

    /// Stops playback and clears active state.
    public func stop() {
        _ = elapsedTime
        playbackID += 1
        shouldBePlaying = false
        stopScheduledPlayback()
        engine.stop()
        clearPlaybackState()
    }
    internal func finishPlayback(at endPosition: TimeInterval) {
        let finishingState = playbackStateToken
        drainAutomaticSkips(upTo: endPosition)
        guard isCurrent(finishingState) else { return }
        silenceAnalysisTask?.cancel()
        silenceAnalysisTask = nil
        playbackID += 1
        stopScheduledPlayback()
        engine.stop()
        setNormalizationGainDB(0)
        lastPlaybackPosition = endPosition
        if currentTrailingSilenceDuration > 0.01 {
            let completionState = playbackStateToken
            onSilentSegmentSkipped?(currentTrailingSilenceDuration)
            guard isCurrent(completionState) else { return }
        }
        accumulatedElapsed = currentDuration
        currentPlaybackRange = nil
        currentPlaybackSchedule = .empty
        automaticSkipBoundaryIndex = 0
        currentTrailingSilenceDuration = 0
        audibleElapsedAtRenderBaseline = 0
        audibleElapsedAtPlaybackStart = 0
        currentURL = nil
        shouldBePlaying = false
        playbackStartedAt = nil
        automaticSkipsDisabledForPlayback = false
        onPlaybackFinished?()
    }

    internal func clearPlaybackState() {
        silenceAnalysisTask?.cancel()
        silenceAnalysisTask = nil
        currentURL = nil
        lastPlaybackPosition = nil
        accumulatedElapsed = 0
        renderBaselineSampleTime = nil
        currentDuration = 0
        currentPlaybackRange = nil
        currentPlaybackSchedule = .empty
        automaticSkipBoundaryIndex = 0
        currentTrailingSilenceDuration = 0
        audibleElapsedAtRenderBaseline = 0
        audibleElapsedAtPlaybackStart = 0
        cachedSilenceAnalysis = nil
        shouldBePlaying = false
        setNormalizationGainDB(0)
    }

    internal func sourcePosition(forAudibleElapsed audibleElapsed: TimeInterval) -> TimeInterval {
        guard currentPlaybackSchedule.rangeCount > 0 else {
            return min(currentDuration, max(accumulatedElapsed, 0))
        }
        return currentPlaybackSchedule.sourcePosition(forAudibleElapsed: audibleElapsed)
    }

    internal func audibleElapsed(forSourcePosition sourcePosition: TimeInterval) -> TimeInterval {
        guard currentPlaybackSchedule.rangeCount > 0 else { return 0 }
        return currentPlaybackSchedule.audibleElapsed(forSourcePosition: sourcePosition)
    }

    internal func drainAutomaticSkips(upTo position: TimeInterval) {
        guard !automaticSkipsDisabledForPlayback, !isDrainingAutomaticSkips else { return }
        let drainingState = playbackStateToken
        isDrainingAutomaticSkips = true
        defer { isDrainingAutomaticSkips = false }
        while automaticSkipBoundaryIndex + 1 < currentPlaybackSchedule.rangeCount {
            let previousRange = currentPlaybackSchedule.range(at: automaticSkipBoundaryIndex)
            let nextRange = currentPlaybackSchedule.range(at: automaticSkipBoundaryIndex + 1)
            guard nextRange.startTime > previousRange.endTime else {
                automaticSkipBoundaryIndex += 1
                continue
            }
            guard position >= nextRange.startTime else { return }
            automaticSkipBoundaryIndex += 1
            onAutomaticSkip?(previousRange.endTime, nextRange.startTime)
            guard isCurrent(drainingState) else { return }
        }
    }

    internal var currentRenderSampleTime: AVAudioFramePosition? {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return nil }
        return playerTime.sampleTime
    }

    internal var renderedElapsedTime: TimeInterval? {
        guard let renderBaselineSampleTime,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0,
              currentPlaybackSchedule.rangeCount > 0 else { return nil }
        let renderedFrames = max(playerTime.sampleTime - renderBaselineSampleTime, 0)
        let audibleElapsed = audibleElapsedAtRenderBaseline + Double(renderedFrames) / playerTime.sampleRate
        return sourcePosition(forAudibleElapsed: audibleElapsed)
    }

    internal var wallClockElapsedTime: TimeInterval {
        wallClockElapsedTime(at: ProcessInfo.processInfo.systemUptime)
    }

    internal func wallClockElapsedTime(at uptime: TimeInterval) -> TimeInterval {
        guard let playbackStartedAt else { return accumulatedElapsed }
        guard currentPlaybackSchedule.rangeCount > 0 else {
            return min(currentDuration, accumulatedElapsed + max(uptime - playbackStartedAt, 0))
        }
        let audibleElapsed = audibleElapsedAtPlaybackStart + max(uptime - playbackStartedAt, 0)
        return sourcePosition(forAudibleElapsed: audibleElapsed)
    }

    @objc nonisolated internal func engineConfigurationChanged() {
        let changeTime = ProcessInfo.processInfo.systemUptime
        Task { @MainActor [weak self] in
            self?.handleEngineConfigurationChanged(changeTime: changeTime)
        }
    }

    func handleEngineConfigurationChanged() {
        handleEngineConfigurationChanged(changeTime: ProcessInfo.processInfo.systemUptime)
    }

    internal func handleEngineConfigurationChanged(changeTime _: TimeInterval) {
        guard let url = currentURL else {
            restoreEqualizerProfileAfterEngineConfiguration()
            return
        }
        let wasPlaying = shouldBePlaying
        let shouldContinuePlayback = wasPlaying && autoContinuePlaybackAfterOutputChange
        let wasAnalyzingSilence = silenceAnalysisTask != nil
        let restartTime = elapsedTime
        playbackID += 1
        silenceAnalysisTask?.cancel()
        silenceAnalysisTask = nil
        stopScheduledPlayback()
        engine.stop()
        restoreEqualizerProfileAfterEngineConfiguration()
        setNormalizationGainDB(currentNormalizationGainDB)
        if !shouldContinuePlayback {
            shouldBePlaying = false
        }
        do {
            let file = try AVAudioFile(forReading: url)
            let boundedRestartTime = min(max(restartTime, 0), Double(file.length) / file.processingFormat.sampleRate)
            if wasAnalyzingSilence, skipSilentSegments, !automaticSkipsDisabledForPlayback {
                currentPlaybackRange = nil
                currentPlaybackSchedule = .empty
                automaticSkipBoundaryIndex = 0
                currentTrailingSilenceDuration = 0
                accumulatedElapsed = boundedRestartTime
                renderBaselineSampleTime = nil
                playbackStartedAt = nil
                if shouldContinuePlayback {
                    startSilenceAnalysis(
                        for: url,
                        requestedStartTime: accumulatedElapsed,
                        playbackID: playbackID
                    )
                } else if wasPlaying {
                    onPlaybackPausedAfterOutputChange?()
                }
                return
            }

            let plan = makePlaybackPlan(
                for: file,
                url: url,
                requestedStartTime: boundedRestartTime,
                analyzeSilence: false
            )
            if plan.startTime > boundedRestartTime {
                let callbackState = playbackStateToken
                onAutomaticSkip?(boundedRestartTime, plan.startTime)
                guard isCurrent(callbackState) else { return }
            }
            try schedulePlaybackPlan(plan, for: file, url: url)
            if wasPlaying, !shouldContinuePlayback {
                onPlaybackPausedAfterOutputChange?()
            }
        } catch {
            let failedTrackElapsed = min(max(restartTime, 0), currentDuration)
            clearPlaybackState()
            onPlaybackFailed?(error, failedTrackElapsed)
        }
    }

    internal static func normalizationGainDB(_ decibels: Double) -> Double {
        guard decibels.isFinite else { return 0 }
        return min(max(decibels, -96), ReplayGain.maximumBoostDB)
    }

    internal func readOutputDeviceID(_ audioUnit: AudioUnit) throws -> AudioDeviceID {
        var actual = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &actual,
            &size
        )
        guard status == noErr else { throw OutputDeviceError.audioHardware(status) }
        return actual
    }

}
