import Foundation
import WavebookCore

extension MainViewController {
    @objc func shufflePlay() {
        _ = startShufflePlay()
    }

    @discardableResult
    func startShufflePlay() -> Bool {
        guard let context = navigation.currentCatalogPageContext else { return false }
        navigation.cancelShuffle()
        playlistsPage.cancelPlaybackLoading()
        startInitialLibraryScanIfNeeded()
        guard hasCompletedInitialLibraryScan else {
            initialLibraryScanShuffleRequest.deferUntilScanCompletes(in: context)
            return true
        }
        return beginShufflePlay()
    }

    @discardableResult
    func beginShufflePlay() -> Bool {
        navigation.startShuffle { [weak self] queue in
            self?.playbackSession.queue.replaceForShuffle(with: queue)
        }
    }

    @discardableResult
    func playTrackWithinCatalogContext(_ track: Track) -> Bool {
        initialLibraryScanShuffleRequest.cancel()
        guard navigation.startPlaybackForCatalogTrack(track, onQueue: { [weak self] queue in
            _ = self?.playbackSession.queue.playPlaylist(queue)
        }) else {
            return playbackSession.queue.play(track)
        }
        return true
    }

    func updateQueue(scrollToCurrent: Bool = false) {
        playbackSession.updateQueue(scrollToCurrent: scrollToCurrent)
    }

    @discardableResult
    func handleMediaKey(
        _ command: MediaKeyCommand,
        at timestamp: TimeInterval? = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        initialLibraryScanShuffleRequest.cancel()
        navigation.cancelShuffle()
        let wasPlaying = playbackSession.transport.isPlaying
        let handled = playbackSession.queue.handleMediaKey(
            command,
            selectedTrack: navigation.selectedTrack,
            hasVisibleLibraryTracks: !navigation.visibleTracks.isEmpty,
            shuffle: { [weak self] in self?.startShufflePlay() ?? false }
        )
        if wasPlaying,
           !playbackSession.transport.isPlaying,
           command == .pause || command == .togglePlayPause {
            audioSettings.noteMediaKeyPause(at: timestamp)
        }
        return handled
    }
}
