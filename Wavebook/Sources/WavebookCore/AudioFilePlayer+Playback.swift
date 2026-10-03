import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

extension AudioFilePlayer {
    /// Returns whether silence analysis is pending.
    public var isSilenceAnalysisPending: Bool {
        silenceAnalysisTask != nil
    }

    /// Returns whether playback is active.
    public var isPlaying: Bool {
        shouldBePlaying
    }

    /// Returns or sets player volume.
    public var volume: Float {
        get { player.volume }
        set { player.volume = min(max(newValue, 0), 1) }
    }

    /// Returns the current normalization gain.
    public var normalizationGainDB: Double {
        currentNormalizationGainDB
    }

    var effectiveNormalizationGainDB: Double {
        Double(normalizationGain.globalGain)
    }

    /// Sets normalization gain with an optional ramp.
    public func setNormalizationGainDB(_ decibels: Double, rampDuration: TimeInterval = 0) {
        let target = Self.normalizationGainDB(decibels)
        normalizationRampTask?.cancel()
        normalizationRampTask = nil
        currentNormalizationGainDB = target

        let start = Double(normalizationGain.globalGain)
        guard rampDuration.isFinite, rampDuration > 0, engine.isRunning, currentURL != nil, start != target else {
            normalizationGain.globalGain = Float(target)
            return
        }

        let duration = min(rampDuration, 1)
        let playbackID = playbackID
        let startedAt = ProcessInfo.processInfo.systemUptime
        normalizationRampTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.playbackID == playbackID {
                let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                let progress = min(max(elapsed / duration, 0), 1)
                self.normalizationGain.globalGain = Float(start + (target - start) * progress)
                guard progress < 1 else { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    /// Returns the current file duration.
    public var duration: TimeInterval {
        currentDuration
    }

    /// Returns elapsed playback time.
    public var elapsedTime: TimeInterval {
        guard shouldBePlaying, silenceAnalysisTask == nil else { return accumulatedElapsed }
        let position = renderedElapsedTime ?? wallClockElapsedTime
        drainAutomaticSkips(upTo: position)
        return position
    }

    internal func configureAudioEngine() {
        engine.attach(player)
        engine.attach(normalizationGain)
        engine.attach(equalizer)
        engine.connect(player, to: normalizationGain, format: nil)
        engine.connect(normalizationGain, to: equalizer, format: nil)
        engine.connect(equalizer, to: engine.mainMixerNode, format: nil)
        configureEqualizerBands()
        player.volume = 1
        setNormalizationGainDB(0)
        apply(equalizerProfile: .flat())
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(engineConfigurationChanged),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    internal func configureEqualizerBands() {
        for (index, band) in equalizer.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = Float(EqualizerProfile.frequencies[index])
            band.bandwidth = 1 / 3
        }
    }

    internal func restoreEqualizerProfileAfterEngineConfiguration() {
        let profile = appliedEqualizerProfile ?? .flat()
        appliedEqualizerProfile = nil
        configureEqualizerBands()
        apply(equalizerProfile: profile)
    }

    /// Starts monitoring default output-device changes.
    public func startMonitoringDefaultOutputDevice() throws {
        guard defaultOutputDeviceListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleDefaultOutputDeviceChanged()
            }
        }
        var address = defaultOutputDeviceAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            listener
        )
        guard status == noErr else { throw OutputDeviceError.audioHardware(status) }
        defaultOutputDeviceListener = listener
    }

    func handleDefaultOutputDeviceChanged() {
        onDefaultOutputDeviceChanged?()
    }

    /// Applies an equalizer profile.
    public func apply(equalizerProfile profile: EqualizerProfile) {
        let previous = appliedEqualizerProfile
        let globalGain = profile.isBypassed ? Float(0) : Float(profile.preamp)
        if previous.map({ $0.isBypassed ? Float(0) : Float($0.preamp) }) != globalGain {
            equalizer.globalGain = globalGain
        }

        for (index, band) in equalizer.bands.enumerated() {
            let gain = profile.bandGains[index]
            if previous?.bandGains[index] != gain {
                band.gain = Float(gain)
            }
            if previous?.isBypassed != profile.isBypassed {
                band.bypass = profile.isBypassed
            }
        }
        appliedEqualizerProfile = profile
    }

    /// Returns the current output device identifier.
    public func outputDeviceID() throws -> AudioDeviceID {
        guard let audioUnit = engine.outputNode.audioUnit else { throw OutputDeviceError.unavailable }
        return try readOutputDeviceID(audioUnit)
    }

    /// Plays a file from its beginning.
    public func play(_ url: URL) throws {
        try self.play(url, start: .automatic, normalizationGainDB: 0, bypassAutomaticSkips: false)
    }

    /// Plays a file with a normalization gain.
    public func play(_ url: URL, normalizationGainDB: Double) throws {
        try self.play(
            url,
            start: .automatic,
            normalizationGainDB: normalizationGainDB,
            bypassAutomaticSkips: false
        )
    }

    /// Plays a file from an explicit position.
    public func play(_ url: URL, from seconds: TimeInterval) throws {
        try self.play(
            url,
            start: .explicit(seconds),
            normalizationGainDB: currentNormalizationGainDB,
            bypassAutomaticSkips: false
        )
    }

    /// Plays from a position with optional normalization and skip bypassing.
    public func play(
        _ url: URL,
        from seconds: TimeInterval,
        normalizationGainDB: Double,
        bypassAutomaticSkips: Bool = false
    ) throws {
        try self.play(
            url,
            start: .explicit(seconds),
            normalizationGainDB: normalizationGainDB,
            bypassAutomaticSkips: bypassAutomaticSkips
        )
    }

    nonisolated internal static func audioFileIdentity(for file: AVAudioFile, url: URL) -> AudioFileIdentity? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let fileSize = values.fileSize,
              let modificationDate = values.contentModificationDate else { return nil }
        return AudioFileIdentity(
            url: url,
            frameLength: file.length,
            fileSize: fileSize,
            modificationDate: modificationDate,
            sampleRate: file.processingFormat.sampleRate,
            channelCount: file.processingFormat.channelCount
        )
    }

    internal func stopScheduledPlayback() {
        playbackScheduler.invalidate()
        player.stop()
    }

    internal func replanAfterSkipSegmentsChanged() {
        guard let currentURL, !automaticSkipsDisabledForPlayback else { return }
        let currentPosition = elapsedTime
        playbackID += 1
        silenceAnalysisTask?.cancel()
        silenceAnalysisTask = nil
        stopScheduledPlayback()
        currentPlaybackRange = nil
        currentTrailingSilenceDuration = 0
        accumulatedElapsed = min(max(currentPosition, 0), currentDuration)
        renderBaselineSampleTime = nil
        playbackStartedAt = nil

        if skipSilentSegments {
            startSilenceAnalysis(
                for: currentURL,
                requestedStartTime: accumulatedElapsed,
                playbackID: playbackID
            )
            return
        }

        do {
            let file = try AVAudioFile(forReading: currentURL)
            let plan = makePlaybackPlan(
                for: file,
                url: currentURL,
                requestedStartTime: accumulatedElapsed,
                analyzeSilence: false
            )
            if plan.startTime > currentPosition {
                let callbackState = playbackStateToken
                onAutomaticSkip?(currentPosition, plan.startTime)
                guard isCurrent(callbackState) else { return }
            }
            try schedulePlaybackPlan(plan, for: file, url: currentURL)
        } catch {
            let position = accumulatedElapsed
            clearPlaybackState()
            onPlaybackFailed?(error, position)
        }
    }

    internal func makePlaybackPlan(
        for file: AVAudioFile,
        url: URL,
        requestedStartTime: TimeInterval,
        analyzeSilence: Bool = true
    ) -> AudioPlaybackPlan {
        let automaticSkipsEnabled = !automaticSkipsDisabledForPlayback
        let shouldUseSilenceSkipping = skipSilentSegments && automaticSkipsEnabled
        let identity = shouldUseSilenceSkipping ? Self.audioFileIdentity(for: file, url: url) : nil
        let cachedBoundaries: AudioSilenceBoundaries?
        if let identity, cachedSilenceAnalysis?.identity == identity {
            cachedBoundaries = cachedSilenceAnalysis?.boundaries
        } else {
            cachedBoundaries = nil
        }
        let shouldAnalyzeSilence = shouldUseSilenceSkipping && (analyzeSilence || cachedBoundaries != nil)
        let plan = AudioPlaybackPlanner().plan(
            for: file,
            requestedStartTime: requestedStartTime,
            skipSilentSegments: shouldAnalyzeSilence,
            options: AudioPlaybackPlanner.Options(
                precomputedBoundaries: cachedBoundaries,
                skipSegments: automaticSkipsEnabled ? skipSegments : [],
                onAnalysisError: { error in
                    let errorDescription = error.localizedDescription
                    Self.logger.warning(
                        "Could not analyze silent segments for playback: \(errorDescription, privacy: .public)"
                    )
                }
            )
        )
        if let identity, cachedBoundaries == nil, analyzeSilence {
            cachedSilenceAnalysis = (identity: identity, boundaries: plan.boundaries)
        }
        return plan
    }

    internal func notifySilentSegmentsDetected(leadingDuration: TimeInterval, trailingDuration: TimeInterval) {
        guard leadingDuration > 0.01 || trailingDuration > 0.01 else { return }
        onSilentSegmentsDetected?(leadingDuration, trailingDuration)
    }

    internal func startSilenceAnalysis(for url: URL, requestedStartTime: TimeInterval, playbackID id: Int) {
        silenceAnalysisTask?.cancel()
        let customSkipSegments = automaticSkipsDisabledForPlayback ? [] : skipSegments
        silenceAnalysisTask = Task { [weak self] in
            let detachedTask = Task.detached(priority: .utility) { () -> SilenceAnalysisResult? in
                guard !Task.isCancelled else { return nil }
                do {
                    let file = try AVAudioFile(forReading: url)
                    guard let sourceIdentity = Self.audioFileIdentity(for: file, url: url) else { return nil }
                    let boundaries = try AudioSilenceDetector().boundaries(
                        for: file,
                        shouldCancel: { Task.isCancelled }
                    )
                    try Task.checkCancellation()
                    return SilenceAnalysisResult(
                        plan: AudioPlaybackPlanner().plan(
                            for: file,
                            requestedStartTime: requestedStartTime,
                            skipSilentSegments: true,
                            options: AudioPlaybackPlanner.Options(
                                precomputedBoundaries: boundaries,
                                skipSegments: customSkipSegments
                            )
                        ),
                        sourceIdentity: sourceIdentity
                    )
                } catch {
                    return nil
                }
            }
            let result = await withTaskCancellationHandler {
                await detachedTask.value
            } onCancel: {
                detachedTask.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            self.applySilenceAnalysis(result, for: url, playbackID: id)
        }
    }

    internal func applySilenceAnalysis(
        _ result: SilenceAnalysisResult?,
        for url: URL,
        playbackID id: Int
    ) {
        guard playbackID == id, currentURL == url else { return }
        silenceAnalysisTask = nil
        guard skipSilentSegments, !automaticSkipsDisabledForPlayback else { return }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            let position = elapsedTime
            clearPlaybackState()
            onPlaybackFailed?(error, position)
            return
        }

        let currentPosition = min(max(accumulatedElapsed, 0), currentDuration)
        guard let result,
              let currentIdentity = Self.audioFileIdentity(for: file, url: url),
              currentIdentity == result.sourceIdentity else {
            applyFallbackSilenceAnalysis(for: file, url: url, currentPosition: currentPosition)
            return
        }
        applyValidatedSilenceAnalysis(
            result,
            for: file,
            url: url,
            currentPosition: currentPosition,
            identity: currentIdentity
        )
    }

    private func applyFallbackSilenceAnalysis(
        for file: AVAudioFile,
        url: URL,
        currentPosition: TimeInterval
    ) {
        do {
            let fallbackPlan = makePlaybackPlan(
                for: file,
                url: url,
                requestedStartTime: currentPosition,
                analyzeSilence: false
            )
            if fallbackPlan.startTime > currentPosition {
                let callbackState = playbackStateToken
                onAutomaticSkip?(currentPosition, fallbackPlan.startTime)
                guard isCurrent(callbackState) else { return }
            }
            try schedulePlaybackPlan(fallbackPlan, for: file, url: url)
            onSilenceAnalysisCompleted?(false, nil)
        } catch {
            clearPlaybackState()
            onPlaybackFailed?(error, currentPosition)
        }
    }

    private func applyValidatedSilenceAnalysis(
        _ result: SilenceAnalysisResult,
        for file: AVAudioFile,
        url: URL,
        currentPosition: TimeInterval,
        identity: AudioFileIdentity
    ) {
        cachedSilenceAnalysis = (identity: identity, boundaries: result.plan.boundaries)
        let plan = makePlaybackPlan(
            for: file,
            url: url,
            requestedStartTime: currentPosition,
            analyzeSilence: false
        )
        let callbackState = playbackStateToken
        notifySilentSegmentsDetected(
            leadingDuration: plan.leadingSilenceSkippedDuration,
            trailingDuration: plan.trailingSilenceDuration
        )
        guard isCurrent(callbackState) else { return }
        if plan.startTime > currentPosition {
            let skipState = playbackStateToken
            onAutomaticSkip?(currentPosition, plan.startTime)
            guard isCurrent(skipState) else { return }
        }
        do {
            try schedulePlaybackPlan(plan, for: file, url: url)
            onSilenceAnalysisCompleted?(true, accumulatedElapsed)
        } catch {
            clearPlaybackState()
            onPlaybackFailed?(error, currentPosition)
        }
    }

    internal func play(
        _ url: URL,
        start: PlaybackStart,
        normalizationGainDB: Double,
        bypassAutomaticSkips: Bool
    ) throws {
        silenceAnalysisTask?.cancel()
        silenceAnalysisTask = nil
        playbackID += 1
        stopScheduledPlayback()
        automaticSkipsDisabledForPlayback = bypassAutomaticSkips
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            engine.stop()
            clearPlaybackState()
            throw error
        }

        let requestedStartTime: TimeInterval
        switch start {
        case .automatic:
            requestedStartTime = 0
        case let .explicit(seconds):
            requestedStartTime = seconds
        }
        let plan = makePlaybackPlan(for: file, url: url, requestedStartTime: requestedStartTime, analyzeSilence: false)

        try startPlayback(plan: plan, file: file, url: url, normalizationGainDB: normalizationGainDB)
    }

    private func startPlayback(
        plan: AudioPlaybackPlan,
        file: AVAudioFile,
        url: URL,
        normalizationGainDB: Double
    ) throws {
        setNormalizationGainDB(normalizationGainDB)
        currentDuration = plan.duration
        currentPlaybackRange = nil
        currentTrailingSilenceDuration = 0
        accumulatedElapsed = plan.startTime
        renderBaselineSampleTime = nil
        currentURL = url
        lastPlaybackPosition = nil
        shouldBePlaying = true
        playbackStartedAt = nil
        if skipSilentSegments, !automaticSkipsDisabledForPlayback {
            startSilenceAnalysis(for: url, requestedStartTime: plan.requestedStartTime, playbackID: playbackID)
        } else {
            do {
                try schedulePlaybackPlan(plan, for: file, url: url)
            } catch {
                engine.stop()
                clearPlaybackState()
                throw error
            }
        }
    }
}
