import WavebookCore

@MainActor
final class PlaybackSessionCoordinator {
    struct Events {
        var presentationChanged: (PlaybackPresentationState) -> Void = { _ in }
        var event: (PlaybackSessionEvent) -> Void = { _ in }
    }

    let audioOutput: PlaybackAudioOutputController
    let replayGain: PlaybackReplayGainController
    let history: PlaybackHistoryController
    let transport: PlaybackTransportController
    let queue: PlaybackQueueCoordinator

    private let events: Events

    init(
        databaseProvider: @escaping () -> LibraryDatabase?,
        shouldLoadReplayGainData: @escaping () -> Bool = { false },
        events: Events = .init()
    ) {
        self.events = events

        let audioPlayer = AudioFilePlayer()
        let audioOutput = PlaybackAudioOutputController(audioPlayer: audioPlayer)
        let replayGain = PlaybackReplayGainController(
            databaseProvider: databaseProvider,
            shouldLoadData: shouldLoadReplayGainData
        )
        let history = PlaybackHistoryController(
            databaseProvider: databaseProvider,
            audioPlayer: audioPlayer,
            onEvent: events.event
        )
        let transport = PlaybackTransportController(
            databaseProvider: databaseProvider,
            audioPlayer: audioPlayer,
            replayGain: replayGain,
            history: history
        )
        let queue = PlaybackQueueCoordinator(transport: transport)

        self.audioOutput = audioOutput
        self.replayGain = replayGain
        self.history = history
        self.transport = transport
        self.queue = queue

        audioOutput.onDefaultOutputDeviceChanged = { [weak self] in
            self?.events.event(.outputDeviceChanged)
        }
        replayGain.onModeChanged = { [weak transport] in
            transport?.refreshReplayGainDetails()
        }
        transport.onEvent = events.event
        transport.onPresentationChanged = { [weak self] in
            self?.publish()
        }
        transport.onPlaybackFinished = { [weak queue] in
            queue?.handleNaturalCompletion()
        }
        transport.onPlaybackFailed = { [weak queue] in
            queue?.handlePlaybackFailure()
        }
        queue.onChanged = { [weak self] shouldScroll in
            self?.publish(shouldScrollQueueToCurrent: shouldScroll)
        }
    }

    func updateQueue(scrollToCurrent: Bool = false) {
        publish(shouldScrollQueueToCurrent: scrollToCurrent)
    }

    func refreshPresentation() {
        publish()
    }
    func updateFavoriteStates(_ changes: [PlaylistFavoriteChange]) {
        queue.updateFavoriteStates(changes)
        transport.updateFavoriteStates(changes)
        publish()
    }

    private func publish(shouldScrollQueueToCurrent: Bool = false) {
        events.presentationChanged(
            PlaybackPresentationState(
                queue: queue.presentation,
                transport: transport.presentation,
                shouldScrollQueueToCurrent: shouldScrollQueueToCurrent
            )
        )
    }
}
