import Foundation
import WavebookCore

enum PlaylistPlaybackStart: Sendable, Equatable {
    case beginning
    case track(Track)
    case manualItem(track: Track, queueIndex: Int)
}

enum PlaylistPlaybackSelectionError: LocalizedError {
    case selectedTrackUnavailable

    var errorDescription: String? {
        "The selected track is no longer available in the playlist."
    }
}

enum PlaylistPlaybackSelection {
    static func start(for item: PlaylistItem, in items: [PlaylistItem]) throws -> PlaylistPlaybackStart {
        guard let track = item.track,
              let queueIndex = queueIndex(forManualItemID: item.id, in: items) else {
            throw PlaylistPlaybackSelectionError.selectedTrackUnavailable
        }
        return .manualItem(track: track, queueIndex: queueIndex)
    }

    static func queueIndex(forManualItemID itemID: Int64, in items: [PlaylistItem]) -> Int? {
        guard let selectedIndex = items.firstIndex(where: { $0.id == itemID }),
              items[selectedIndex].track != nil else { return nil }
        return items[..<selectedIndex].compactMap(\.track).count
    }

    nonisolated static func preparedQueue(
        from loadedQueue: PlaybackQueue,
        startingAt start: PlaylistPlaybackStart
    ) throws -> PlaybackQueue {
        switch start {
        case .beginning:
            return loadedQueue
        case let .track(track):
            guard let index = loadedQueue.entries.firstIndex(where: {
                $0.track.hasSameIdentity(as: track)
            }) else {
                throw PlaylistPlaybackSelectionError.selectedTrackUnavailable
            }
            return try queue(loadedQueue, startingAt: track, index: index)
        case let .manualItem(track, queueIndex):
            return try queue(loadedQueue, startingAt: track, index: queueIndex)
        }
    }

    private nonisolated static func queue(
        _ loadedQueue: PlaybackQueue,
        startingAt track: Track,
        index: Int
    ) throws -> PlaybackQueue {
        var queue = loadedQueue
        queue.setShuffleEnabled(false)
        guard queue.entry(at: index)?.track.hasSameIdentity(as: track) == true,
              queue.play(at: index) != nil else {
            throw PlaylistPlaybackSelectionError.selectedTrackUnavailable
        }
        return queue
    }
}
