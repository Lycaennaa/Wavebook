import AppKit
import Foundation
import MediaPlayer
import WavebookCore

private enum PlaybackTransportError: LocalizedError {
    case databaseUnavailable

    var errorDescription: String? {
        "Playback settings database is unavailable"
    }
}

@MainActor
final class PlaybackTransportController: PlaybackQueueTransport {
    let audioPlayer: AudioFilePlayer
    private let databaseProvider: () -> LibraryDatabase?
    let replayGain: PlaybackReplayGainController
    let history: PlaybackHistoryController
    let preview: PlaybackPreviewCoordinator
    let lyrics: LyricsCoordinator
    var skipSegmentEditor: SkipSegmentEditorCoordinator?
    let artwork: PlaybackArtworkController
    let progress: PlaybackProgressController

    private var currentPlayback: PlaybackTrackContext?
    var currentTrack: Track? {
        get { currentPlayback?.track }
        set {
            guard let newValue else {
                currentPlayback = nil
                return
            }
            currentPlayback = PlaybackTrackContext(
                track: newValue,
                source: currentPlayback?.source ?? ListeningPlaybackSource(kind: .library)
            )
        }
    }

    var currentPlaybackSource: ListeningPlaybackSource {
        get { currentPlayback?.source ?? ListeningPlaybackSource(kind: .library) }
        set {
            guard let currentPlayback else { return }
            self.currentPlayback = PlaybackTrackContext(
                track: currentPlayback.track,
                source: newValue
            )
        }
    }
    var presentationSuppressionDepth = 0
    var onPresentationChanged: (() -> Void)?
    var onPlaybackFinished: (() -> Void)?
    var onPlaybackFailed: (() -> Void)?
    var onEvent: ((PlaybackSessionEvent) -> Void)?
    var onVolumeChanged: ((Float) -> Void)?
    private var bluetoothDisconnectResumeTracker = BluetoothDisconnectResumeTracker()

    init(
        databaseProvider: @escaping () -> LibraryDatabase?,
        audioPlayer: AudioFilePlayer,
        replayGain: PlaybackReplayGainController,
        history: PlaybackHistoryController
    ) {
        self.audioPlayer = audioPlayer
        self.databaseProvider = databaseProvider
        self.replayGain = replayGain
        self.history = history
        self.preview = PlaybackPreviewCoordinator(history: history)
        lyrics = LyricsCoordinator(
            databaseProvider: databaseProvider,
            loader: LRCLyricsLoader(),
            downloader: LRCLIBLyricsDownloader()
        )
        artwork = PlaybackArtworkController()
        progress = PlaybackProgressController()
        history.setRenderedPositionProvider { [weak self] in
            self?.readElapsedTime(notify: true) ?? 0
        }
        audioPlayer.onAutomaticSkip = { [weak self] from, destinationTime in
            guard let self else { return }
            self.history.rebaseAfterAutomaticSkip(from: from, to: destinationTime)
            self.lyrics.update(elapsed: destinationTime)
            self.lyrics.setPlaybackPosition(destinationTime)
            self.skipSegmentEditor?.setPlaybackState(
                destinationTime,
                isPlaying: self.audioPlayer.isPlaying
            )
        }

        lyrics.onSeek = { [weak self] seconds in
            _ = self?.seek(to: seconds, bypassAutomaticSkips: true)
        }
        lyrics.playbackPositionProvider = { [weak self] in
            guard let self else { return (0, nil) }
            return (self.readElapsedTime(), self.currentTrack?.path)
        }
        lyrics.onStateChanged = { [weak self] in
            self?.emitPresentationChanged()
        }
        lyrics.onLibraryChanged = { [weak self] in
            self?.onEvent?(.libraryContentChanged)
        }
        audioPlayer.onPlaybackFinished = { [weak self] in
            self?.playbackFinished()
        }
        audioPlayer.onPlaybackFailed = { [weak self] error, renderedPosition in
            self?.playbackFailed(error, renderedPosition: renderedPosition)
        }
        configureOutputChangePlaybackCallback()
        audioPlayer.onSilentSegmentsDetected = { [weak self] leadingDuration, trailingDuration in
            self?.presentSilentSkip(leadingDuration: leadingDuration, trailingDuration: trailingDuration)
        }
        audioPlayer.onSilentSegmentSkipped = { [weak self] duration in
            self?.presentSilentSkipCompleted(duration)
        }
        audioPlayer.onSilenceAnalysisCompleted = { [weak self] successfully, position in
            self?.silenceAnalysisCompleted(successfully: successfully, at: position)
        }
        replayGain.onEvent = { [weak self] event in
            self?.onEvent?(event)
        }
    }

    func readElapsedTime(notify: Bool = false) -> TimeInterval {
        let previousPreview = lyrics.preview
        let elapsed = withPresentationSuppressed { audioPlayer.elapsedTime }
        if notify, previousPreview != lyrics.preview {
            emitPresentationChanged()
        }
        return elapsed
    }
    var skipSilentSegments: Bool {
        audioPlayer.skipSilentSegments
    }

    func applySavedSkipSilentSegments() {
        guard let database = databaseProvider() else {
            audioPlayer.skipSilentSegments = false
            onEvent?(.error(
                PlaybackTransportError.databaseUnavailable,
                message: "Could not load saved silent-segment skipping setting",
                kind: .database
            ))
            return
        }
        do {
            audioPlayer.skipSilentSegments = try database.skipSilentSegments()
            onEvent?(.clearOperationalErrors(.database))
        } catch {
            audioPlayer.skipSilentSegments = false
            onEvent?(.error(error, message: "Could not load saved silent-segment skipping setting", kind: .database))
        }
    }
    func applySavedSkipSilentSegments(_ enabled: Bool) {
        audioPlayer.skipSilentSegments = enabled
        onEvent?(.clearOperationalErrors(.database))
    }

    @discardableResult
    func setSkipSilentSegments(_ enabled: Bool) -> Bool {
        guard let database = databaseProvider() else {
            onEvent?(.error(
                PlaybackTransportError.databaseUnavailable,
                message: "Could not save silent-segment skipping setting",
                kind: .database
            ))
            return false
        }
        do {
            try database.saveSkipSilentSegments(enabled)
        } catch {
            onEvent?(.error(error, message: "Could not save silent-segment skipping setting", kind: .database))
            return false
        }
        audioPlayer.skipSilentSegments = enabled
        emitPresentationChanged()
        onEvent?(.clearOperationalErrors(.database))
        return true
    }

    func loadSkipSegments(for track: Track) -> Result<[AudioSkipSegment], Error> {
        guard let database = databaseProvider() else {
            let error = PlaybackTransportError.databaseUnavailable
            onEvent?(.error(
                error,
                message: "Could not load saved skip segments",
                kind: .database
            ))
            return .failure(error)
        }
        do {
            let segments = try database.skipSegments(forTrackPath: track.path)
            onEvent?(.clearOperationalErrors(.database))
            return .success(segments)
        } catch {
            onEvent?(.error(error, message: "Could not load saved skip segments", kind: .database))
            return .failure(error)
        }
    }

    func saveSkipSegments(_ segments: [AudioSkipSegment], for track: Track) -> Bool {
        guard let database = databaseProvider() else {
            onEvent?(.error(
                PlaybackTransportError.databaseUnavailable,
                message: "Could not save skip segments",
                kind: .database
            ))
            return false
        }
        do {
            try database.saveSkipSegments(segments, forTrackPath: track.path)
            let isCurrentTrack = currentTrack?.path == track.path
            if isCurrentTrack {
                withPresentationSuppressed {
                    audioPlayer.setSkipSegments(segments)
                }
                lyrics.setSkipSegments(segments)
                emitPresentationChanged()
            }
            onEvent?(.clearOperationalErrors(.database))
            return true
        } catch {
            onEvent?(.error(error, message: "Could not save skip segments", kind: .database))
            return false
        }
    }

    var hasAudioSource: Bool {
        audioPlayer.currentURL != nil
    }

    var renderedPosition: TimeInterval? {
        guard audioPlayer.currentURL != nil else { return nil }
        return readElapsedTime()
    }

    var presentation: PlaybackTransportPresentation {
        let elapsed = readElapsedTime()
        return PlaybackTransportPresentation(
            track: currentTrack,
            artwork: artwork.image,
            duration: audioPlayer.duration > 0 ? audioPlayer.duration : currentTrack?.duration ?? 0,
            elapsed: elapsed,
            isPlaying: audioPlayer.isPlaying,
            lyricsEnabled: lyrics.isEnabled,
            lyricsPreview: lyrics.preview,
            replayGain: replayGain.presentation
        )
    }

    func makeSkipSegmentEditor() -> SkipSegmentEditorCoordinator {
        SkipSegmentEditorCoordinator(
            onSeek: { [weak self] seconds in
                guard let self, self.currentTrack != nil else { return }
                _ = self.seekFromSegmentEditor(to: seconds)
            },
            onSegmentsChanged: { [weak self] track, segments in
                guard let self else { return false }
                return self.saveSkipSegments(segments, for: track)
            },
            onPlaybackToggle: { [weak self] in
                self?.toggleSegmentEditorPlayback() ?? false
            },
            onVolumeChanged: { [weak self] volume in
                self?.onVolumeChanged?(volume)
            },
            onPreviewEnded: { [weak self] in
                self?.endSegmentEditorPreview()
            },
            currentPositionProvider: { [weak self] in
                self?.readElapsedTime() ?? 0
            }
        )
    }

    func refreshVolume() {
        skipSegmentEditor?.setVolume(audioPlayer.volume)
    }

    func refreshReplayGainDetails() {
        replayGain.refresh(currentTrack: currentTrack, audioPlayer: audioPlayer)
        emitPresentationChanged()
    }
    func updateFavoriteStates(_ changes: [PlaylistFavoriteChange]) {
        for change in changes where currentTrack?.id == change.trackID {
            currentTrack?.isFavorite = change.isFavorite
        }
    }

    func viewWillDisappear() {
        progress.stop()
        lyrics.cancelForViewDisappearance()
    }

    func finalizeForTermination(completion: @escaping @MainActor (Bool) -> Void) {
        let shouldRestorePlaybackHistory = history.isUntrackedPreviewActive || history.tracker?.activeEventID != nil
        endSegmentEditorPreview(restoringPendingHistory: false, preservePendingHistory: true)
        history.finalizeForTermination { [weak self] succeeded in
            if succeeded {
                self?.preview.discardPendingHistory()
            } else if shouldRestorePlaybackHistory {
                self?.restorePlaybackAfterCanceledTermination()
            }
            completion(succeeded)
        }
    }

    private func restorePlaybackAfterCanceledTermination() {
        preview.restoreAfterCanceledTermination(
            currentTrack: currentTrack,
            hasAudioSource: audioPlayer.currentURL != nil,
            elapsed: readElapsedTime(),
            source: currentPlaybackSource
        )
    }

    @discardableResult
    func togglePrivateMode() -> Bool {
        history.togglePrivateMode()
    }

    func withPresentationSuppressed<Result>(_ operation: () throws -> Result) rethrows -> Result {
        presentationSuppressionDepth += 1
        defer { presentationSuppressionDepth -= 1 }
        return try operation()
    }

    func completeNaturalPlayback() {
        artwork.cancel(keepingImage: true)
        lyrics.update(elapsed: audioPlayer.duration)
        lyrics.setPlaybackPosition(audioPlayer.duration)
        skipSegmentEditor?.setPlaybackState(audioPlayer.duration, isPlaying: false)
        progress.stop()
        replayGain.refresh(currentTrack: currentTrack, audioPlayer: audioPlayer)
        updateNowPlaying(state: .stopped)
        emitPresentationChanged()
    }

    private func presentSilentSkip(leadingDuration: TimeInterval, trailingDuration: TimeInterval) {
        guard let message = AudioPlaybackSkipMessage.detected(
            leadingDuration: leadingDuration,
            trailingDuration: trailingDuration
        ) else { return }
        onEvent?(.presentOperationalMessage(message, kind: .general))
    }

    private func silenceAnalysisCompleted(successfully: Bool, at position: TimeInterval?) {
        preview.silenceAnalysisCompleted(successfully: successfully, at: position)
    }

    private func playbackFinished() {
        history.tracker?.endPlayback(
            reason: .naturalCompletion,
            renderedPosition: audioPlayer.lastPlaybackPosition ?? audioPlayer.duration,
            isPlaying: true
        )
        skipSegmentEditor?.setPlaybackState(readElapsedTime(), isPlaying: false)
        endSegmentEditorPreview(restoringPendingHistory: false)
        onPlaybackFinished?()
    }

    private func playbackFailed(_ error: Error, renderedPosition: TimeInterval) {
        history.tracker?.endPlayback(
            reason: .unrecoverablePlaybackError,
            renderedPosition: renderedPosition,
            isPlaying: true
        )
        endSegmentEditorPreview(restoringPendingHistory: false)
        withPresentationSuppressed {
            clearPlaybackAfterFailure()
        }
        onPlaybackFailed?()
        emitPresentationChanged()
        onEvent?(.error(error, message: "Playback stopped after an audio device change", kind: .general))
    }

    func clearPlaybackAfterFailure() {
        endSegmentEditorPreview(restoringPendingHistory: false)
        audioPlayer.stop()
        artwork.cancel()
        lyrics.cancelForPlaybackFailure()
        currentTrack = nil
        skipSegmentEditor?.close()
        skipSegmentEditor = nil
        progress.stop()
        replayGain.clearPresentation()
        updateNowPlaying(state: .stopped)
    }

}

private extension PlaybackTransportController {
    private func presentSilentSkipCompleted(_ duration: TimeInterval) {
        guard let message = AudioPlaybackSkipMessage.completed(trailingDuration: duration) else { return }
        onEvent?(.presentOperationalMessage(message, kind: .general))
    }
}

extension PlaybackTransportController {
    var autoContinuePlaybackAfterOutputChange: Bool {
        audioPlayer.autoContinuePlaybackAfterOutputChange
    }

    var isPlaying: Bool {
        audioPlayer.isPlaying
    }

    func applySavedAutoContinuePlaybackAfterOutputChange(_ enabled: Bool) {
        audioPlayer.autoContinuePlaybackAfterOutputChange = enabled
        if !enabled {
            bluetoothDisconnectResumeTracker.reset()
        }
    }

    @discardableResult
    func setAutoContinuePlaybackAfterOutputChange(_ enabled: Bool) -> Bool {
        guard let database = databaseProvider() else {
            onEvent?(.error(
                PlaybackTransportError.databaseUnavailable,
                message: "Could not save automatic playback continuation setting",
                kind: .database
            ))
            return false
        }
        do {
            try database.saveAutoContinuePlaybackAfterOutputChange(enabled)
        } catch {
            onEvent?(.error(
                error,
                message: "Could not save automatic playback continuation setting",
                kind: .database
            ))
            return false
        }
        audioPlayer.autoContinuePlaybackAfterOutputChange = enabled
        if !enabled {
            bluetoothDisconnectResumeTracker.reset()
        }
        onEvent?(.clearOperationalErrors(.database))
        return true
    }

    func noteMediaKeyPause(at timestamp: TimeInterval?) {
        guard autoContinuePlaybackAfterOutputChange else {
            bluetoothDisconnectResumeTracker.reset()
            return
        }
        guard let timestamp else {
            bluetoothDisconnectResumeTracker.reset()
            return
        }
        if bluetoothDisconnectResumeTracker.recordRemotePause(at: timestamp) {
            resumeAfterBluetoothDisconnect()
        }
    }

    func noteBluetoothOutputDisconnect(at timestamp: TimeInterval) {
        guard autoContinuePlaybackAfterOutputChange else {
            bluetoothDisconnectResumeTracker.reset()
            return
        }
        bluetoothDisconnectResumeTracker.recordBluetoothToNonBluetoothOutputChange(at: timestamp)
    }

    private func resumeAfterBluetoothDisconnect() {
        guard autoContinuePlaybackAfterOutputChange,
              hasAudioSource,
              !isPlaying else { return }
        _ = toggleCurrentPlayback()
    }

    private func configureOutputChangePlaybackCallback() {
        audioPlayer.onPlaybackPausedAfterOutputChange = { [weak self] in
            guard let self else { return }
            self.progress.stop()
            self.history.pause()
            self.updateNowPlaying(state: .paused)
            self.emitPresentationChanged()
        }
    }
}
