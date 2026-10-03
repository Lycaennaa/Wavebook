import Foundation
import WavebookCore

@MainActor
protocol PlaybackQueueTransport {
    var currentTrack: Track? { get }
    var currentPlaybackSource: ListeningPlaybackSource { get }
    var hasAudioSource: Bool { get }
    var isPlaying: Bool { get }

    func withPresentationSuppressed<Result>(_ operation: () throws -> Result) rethrows -> Result
    func play(
        _ track: Track,
        source: ListeningPlaybackSource,
        trackingEndReason: ListeningEventEndReason?,
        onFailure: @escaping () -> Void
    ) -> Bool
    func toggleCurrentPlayback() -> Bool
    func completeNaturalPlayback()
}

@MainActor
final class PlaybackQueueCoordinator {
    private let transport: any PlaybackQueueTransport
    private var playbackQueue = PlaybackQueue()
    private var isPlayingFromQueue = false
    private var cachedPresentationEntries: [PlaybackQueue.Entry]?
    private var presentationRevision: UInt64 = 0

    var onChanged: ((Bool) -> Void)?
    var onPlaybackCommand: (() -> Void)?

    init(transport: any PlaybackQueueTransport) {
        self.transport = transport
    }

    var presentation: PlaybackQueuePresentation {
        let entries: [PlaybackQueue.Entry]
        if let cachedPresentationEntries {
            entries = cachedPresentationEntries
        } else {
            let loadedEntries = playbackQueue.queuedEntries
            cachedPresentationEntries = loadedEntries
            entries = loadedEntries
        }
        return PlaybackQueuePresentation(
            entries: entries,
            revision: presentationRevision,
            currentIndex: isPlayingFromQueue ? playbackQueue.currentQueueIndex : nil,
            isShuffled: playbackQueue.isShuffled,
            repeatMode: playbackQueue.repeatMode
        )
    }

    func update(scrollToCurrent: Bool = false) {
        presentationRevision &+= 1
        onChanged?(scrollToCurrent)
    }
    func updateFavoriteStates(_ changes: [PlaylistFavoriteChange]) {
        guard !changes.isEmpty else { return }
        for change in changes {
            playbackQueue.updateFavoriteState(trackID: change.trackID, isFavorite: change.isFavorite)
        }
        cachedPresentationEntries = nil
        presentationRevision &+= 1
    }

    func replaceForShuffle(with queue: PlaybackQueue) {
        guard !queue.isEmpty else { return }
        replaceQueuePreservingRepeatMode(with: queue)
        changed()
        _ = advanceToNextQueuedTrack()
    }

    @discardableResult
    func play(
        _ track: Track,
        source: ListeningPlaybackSource = ListeningPlaybackSource(kind: .library)
    ) -> Bool {
        notifyPlaybackCommand()
        isPlayingFromQueue = false
        let succeeded = transport.withPresentationSuppressed {
            transport.play(track, source: source, trackingEndReason: nil, onFailure: {})
        }
        changed()
        return succeeded
    }

    @discardableResult
    func playPlaylist(_ queue: PlaybackQueue) -> Bool {
        guard !queue.isEmpty else { return false }
        notifyPlaybackCommand()
        replaceQueuePreservingRepeatMode(with: queue)
        changed()
        guard let index = playbackQueue.playbackIndex,
              let entry = playbackQueue.entry(at: index) else { return false }
        return playQueued(entry, at: index)
    }

    @discardableResult
    func playPlaylist(_ tracks: [Track], source: ListeningPlaybackSource) -> Bool {
        guard !tracks.isEmpty else { return false }
        notifyPlaybackCommand()
        playbackQueue.replace(with: tracks, source: source)
        changed()
        guard let index = playbackQueue.playbackIndex,
              let entry = playbackQueue.entry(at: index) else { return false }
        return playQueued(entry, at: index)
    }

    @discardableResult
    func playQueuedTrack(
        _ entry: PlaybackQueue.Entry,
        trackingEndReason: ListeningEventEndReason? = nil
    ) -> Bool {
        notifyPlaybackCommand()
        guard let index = playbackQueue.entryIndex(of: entry),
              let currentEntry = playbackQueue.entry(at: index) else { return false }
        return playQueued(currentEntry, at: index, trackingEndReason: trackingEndReason)
    }

    func removeQueuedTracks(withIDs entryIDs: [UUID]) {
        let removal = playbackQueue.removeEntries(withIDs: entryIDs)
        guard !removal.removedEntries.isEmpty else { return }
        if removal.removedCurrentEntry, !playbackQueue.isShuffled {
            isPlayingFromQueue = false
        }
        changed()
    }

    func addToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        playbackQueue.append(contentsOf: tracks)
        changed()
    }

    func addNextToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        playbackQueue.insertNext(tracks)
        changed()
    }

    @discardableResult
    func moveQueuedTrack(_ entry: PlaybackQueue.Entry, to destination: Int) -> Bool {
        guard playbackQueue.moveQueuedItem(entry, to: destination) else { return false }
        changed()
        return true
    }

    @discardableResult
    func playNextQueuedTrack() -> Bool {
        notifyPlaybackCommand()
        return advanceToNextQueuedTrack()
    }

    private func advanceToNextQueuedTrack() -> Bool {
        guard let index = playbackQueue.nextIndex,
              let entry = playbackQueue.entry(at: index) else { return false }
        return playQueued(entry, at: index, trackingEndReason: .next)
    }

    @discardableResult
    func playPreviousQueuedTrack() -> Bool {
        notifyPlaybackCommand()
        guard let index = playbackQueue.previousIndex,
              let entry = playbackQueue.entry(at: index) else { return false }
        return playQueued(entry, at: index, trackingEndReason: .previous)
    }

    func toggleShuffle() {
        playbackQueue.setShuffleEnabled(!playbackQueue.isShuffled)
        changed()
    }

    func cycleRepeatMode() {
        let mode: PlaybackRepeatMode
        switch playbackQueue.repeatMode {
        case .off:
            mode = .all
        case .all:
            mode = .one
        case .one:
            mode = .off
        }
        playbackQueue.setRepeatMode(mode)
        changed()
    }

    @discardableResult
    func togglePlayback(selectedTrack: Track?, shuffle: @escaping () -> Bool) -> Bool {
        notifyPlaybackCommand()
        if transport.isPlaying || transport.hasAudioSource {
            return transport.toggleCurrentPlayback()
        }
        if playbackQueue.isAtEnd {
            return false
        }
        if playbackQueue.isEmpty {
            return shuffle()
        }
        if let index = playbackQueue.playbackIndex,
           let entry = playbackQueue.entry(at: index) {
            return playQueued(entry, at: index)
        }
        if let selectedTrack {
            return play(selectedTrack)
        }
        return false
    }

    @discardableResult
    func handleMediaKey(
        _ command: MediaKeyCommand,
        selectedTrack: Track?,
        hasVisibleLibraryTracks: Bool,
        shuffle: @escaping () -> Bool
    ) -> Bool {
        let hasTrack = transport.hasAudioSource
            || playbackQueue.playbackIndex != nil
            || (playbackQueue.isEmpty && !playbackQueue.isAtEnd && hasVisibleLibraryTracks)
        switch command {
        case .togglePlayPause:
            return togglePlayback(selectedTrack: selectedTrack, shuffle: shuffle)
        case .play:
            guard !transport.isPlaying else { return hasTrack }
            return togglePlayback(selectedTrack: selectedTrack, shuffle: shuffle)
        case .pause:
            guard transport.isPlaying else { return hasTrack }
            return togglePlayback(selectedTrack: selectedTrack, shuffle: shuffle)
        case .nextTrack:
            return playNextQueuedTrack()
        case .previousTrack:
            return playPreviousQueuedTrack()
        }
    }

    func handlePlaybackFailure() {
        isPlayingFromQueue = false
        changed()
    }
    func handleNaturalCompletion() {
        if isPlayingFromQueue {
            playbackQueue.markCurrentTrackFinished()
            if let index = playbackQueue.playbackIndex,
               let entry = playbackQueue.entry(at: index),
               playQueued(entry, at: index) {
                return
            }
        } else if playbackQueue.repeatMode.repeatsStandaloneTrack,
                  let track = transport.currentTrack {
            let source = transport.currentPlaybackSource
            let replayed = transport.withPresentationSuppressed {
                transport.play(track, source: source, trackingEndReason: nil, onFailure: {})
            }
            if replayed {
                changed()
                return
            }
        }

        isPlayingFromQueue = false
        if transport.currentTrack != nil {
            transport.withPresentationSuppressed {
                transport.completeNaturalPlayback()
            }
        }
        changed()
    }

    private func playQueued(
        _ entry: PlaybackQueue.Entry,
        at index: Int,
        trackingEndReason: ListeningEventEndReason? = nil
    ) -> Bool {
        guard let currentEntry = playbackQueue.entry(at: index), currentEntry.id == entry.id else { return false }
        isPlayingFromQueue = false
        let succeeded = transport.withPresentationSuppressed {
            transport.play(
                currentEntry.track,
                source: currentEntry.source,
                trackingEndReason: trackingEndReason,
                onFailure: { [weak self] in
                    self?.playbackQueue.markPlaybackFailed(for: currentEntry)
                }
            )
        }
        guard succeeded else {
            changed()
            return false
        }
        _ = playbackQueue.play(at: index)
        isPlayingFromQueue = true
        changed()
        return true
    }

    private func notifyPlaybackCommand() {
        onPlaybackCommand?()
    }
    private func replaceQueuePreservingRepeatMode(with queue: PlaybackQueue) {
        var queue = queue
        queue.setRepeatMode(playbackQueue.repeatMode)
        playbackQueue = queue
    }

    private func changed() {
        cachedPresentationEntries = nil
        presentationRevision &+= 1
        onChanged?(false)
    }
}
