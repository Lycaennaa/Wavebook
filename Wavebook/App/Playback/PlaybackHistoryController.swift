import Foundation
import WavebookCore

@MainActor
final class PlaybackHistoryController {
    private let databaseProvider: () -> LibraryDatabase?
    private let audioPlayer: AudioFilePlayer
    private let onEvent: (PlaybackSessionEvent) -> Void
    private var renderedPositionProvider: () -> TimeInterval
    private lazy var trackerStorage: ListeningHistoryTracker? = makeTracker()
    private var untrackedPreviewActive = false
    var isUntrackedPreviewActive: Bool { untrackedPreviewActive }

    init(
        databaseProvider: @escaping () -> LibraryDatabase?,
        audioPlayer: AudioFilePlayer,
        onEvent: @escaping (PlaybackSessionEvent) -> Void
    ) {
        self.databaseProvider = databaseProvider
        self.audioPlayer = audioPlayer
        self.onEvent = onEvent
        self.renderedPositionProvider = { 0 }
    }

    func setRenderedPositionProvider(_ provider: @escaping () -> TimeInterval) {
        renderedPositionProvider = provider
    }

    var tracker: ListeningHistoryTracker? {
        trackerStorage
    }

    var privateModeEnabled: Bool? {
        tracker?.isPrivateMode
    }

    var renderedPosition: TimeInterval? {
        guard audioPlayer.currentURL != nil else { return nil }
        return renderedPositionProvider()
    }

    func endPlayback(for track: Track? = nil, reason: ListeningEventEndReason? = nil) {
        guard let tracker else { return }
        let resolvedReason = reason ?? {
            if let track, let currentPath = audioPlayer.currentURL?.path, currentPath == track.path {
                return ListeningEventEndReason.sameTrackRestart
            }
            return ListeningEventEndReason.differentTrackSelection
        }()
        tracker.endPlayback(
            reason: resolvedReason,
            renderedPosition: renderedPosition,
            isPlaying: audioPlayer.isPlaying
        )
    }

    @discardableResult
    func startPlayback(
        for track: Track,
        source: ListeningPlaybackSource = ListeningPlaybackSource(kind: .library),
        initialPosition: TimeInterval? = nil
    ) -> Bool {
        guard let tracker else { return false }
        let trimmedFormat = track.format.trimmingCharacters(in: .whitespacesAndNewlines)
        let format = trimmedFormat.isEmpty
            ? URL(fileURLWithPath: track.path).pathExtension
            : trimmedFormat
        let result = tracker.startPlayback(
            track: track,
            openedDuration: audioPlayer.duration,
            openedFormat: format,
            source: source,
            initialPosition: initialPosition ?? renderedPositionProvider(),
            isPlaying: audioPlayer.isPlaying
        )
        if case .started = result { return true }
        return false
    }

    func pause() {
        guard audioPlayer.currentURL != nil else { return }
        tracker?.pause(renderedPosition: renderedPositionProvider())
    }

    func resume() {
        guard audioPlayer.currentURL != nil else { return }
        tracker?.resume(renderedPosition: renderedPositionProvider())
    }
    func beginUntrackedPreview() {
        guard !untrackedPreviewActive else { return }
        untrackedPreviewActive = true
        tracker?.pause(renderedPosition: renderedPositionProvider())
    }

    func endUntrackedPreview() {
        guard untrackedPreviewActive else { return }
        untrackedPreviewActive = false
        if audioPlayer.isPlaying {
            tracker?.resume(renderedPosition: renderedPositionProvider())
        } else {
            tracker?.pause(renderedPosition: renderedPositionProvider())
        }
    }

    func prepareForSeek() {
        tracker?.prepareForSeek(renderedPosition: renderedPosition)
    }

    func completeSeek(successfully: Bool) {
        _ = tracker?.completeSeek(
            successfully: successfully,
            renderedPosition: successfully ? renderedPositionProvider() : renderedPosition,
            isPlaying: audioPlayer.isPlaying
        )
    }
    func rebaseAfterAutomaticSkip(from start: TimeInterval, to end: TimeInterval) {
        guard !untrackedPreviewActive, end > start else { return }
        tracker?.prepareForSeek(renderedPosition: start)
        _ = tracker?.completeSeek(
            successfully: true,
            renderedPosition: end,
            isPlaying: audioPlayer.isPlaying
        )
    }

    func finalizeForTermination(completion: @escaping @MainActor (Bool) -> Void) {
        guard let tracker else {
            completion(true)
            return
        }
        tracker.terminate(
            renderedPosition: renderedPosition,
            isPlaying: audioPlayer.isPlaying,
            completion: completion
        )
    }

    @discardableResult
    func togglePrivateMode() -> Bool {
        guard let tracker else { return false }
        return tracker.setPrivateMode(
            !tracker.isPrivateMode,
            renderedPosition: renderedPosition,
            isPlaying: audioPlayer.isPlaying
        )
    }

    private func makeTracker() -> ListeningHistoryTracker? {
        guard let database = databaseProvider() else { return nil }
        let tracker = ListeningHistoryTracker(
            database: database,
            sampleProvider: { [weak self] in
                guard let self, self.audioPlayer.currentURL != nil else { return nil }
                return ListeningPlaybackSample(
                    renderedPosition: self.renderedPositionProvider(),
                    isPlaying: self.audioPlayer.isPlaying && !self.untrackedPreviewActive,
                    observedAtUTC: Date()
                )
            }
        )

        let eventHandler = onEvent
        tracker.onPersistenceError = { message in
            MainActor.assumeIsolated {
                eventHandler(.persistenceError(message))
            }
        }
        tracker.onPersistenceWarningChanged = { warning in
            MainActor.assumeIsolated {
                eventHandler(.persistenceWarningChanged(warning))
            }
        }
        if let warning = tracker.persistenceWarning {
            eventHandler(.initialPersistenceWarning(warning))
        }
        return tracker
    }
}
