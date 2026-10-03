@testable import WavebookCore
import XCTest

final class PlaylistPlaybackSelectionTests: XCTestCase {
    func testManualItemStartsAtTheCorrectPlayableDuplicate() throws {
        let duplicate = makeTrack(1)
        let items = [
            makeItem(id: 1, ordinal: 0, track: duplicate),
            makeItem(id: 2, ordinal: 1, track: nil),
            makeItem(id: 3, ordinal: 2, track: makeTrack(2)),
            makeItem(id: 4, ordinal: 3, track: duplicate)
        ]
        let start = try PlaylistPlaybackSelection.start(for: items[3], in: items)
        XCTAssertEqual(start, .manualItem(track: duplicate, queueIndex: 2))
        XCTAssertThrowsError(try PlaylistPlaybackSelection.start(for: items[1], in: items))

        let loadedQueue = PlaybackQueue(items: [duplicate, makeTrack(2), duplicate])
        let selectedQueue = try PlaylistPlaybackSelection.preparedQueue(
            from: loadedQueue,
            startingAt: start
        )
        XCTAssertEqual(selectedQueue.currentTrack, duplicate)
        XCTAssertNil(selectedQueue.nextIndex)
    }

    func testPreparedQueueStartsAtSelectedTrackInOrder() throws {
        let tracks = (1...3).map(makeTrack)
        let loadedQueue = PlaybackQueue(items: tracks)

        let selectedQueue = try PlaylistPlaybackSelection.preparedQueue(
            from: loadedQueue,
            startingAt: .track(tracks[1])
        )

        XCTAssertEqual(selectedQueue.currentTrack, tracks[1])
        XCTAssertEqual(selectedQueue.nextIndex, 2)
        XCTAssertFalse(selectedQueue.isShuffled)
        XCTAssertThrowsError(
            try PlaylistPlaybackSelection.preparedQueue(
                from: loadedQueue,
                startingAt: .track(makeTrack(4))
            )
        )
    }

    private func makeItem(id: Int64, ordinal: Int, track: Track?) -> PlaylistItem {
        PlaylistItem(
            id: id,
            playlistID: 7,
            ordinal: ordinal,
            track: track,
            snapshot: PlaylistItemSnapshot(
                path: track?.path ?? "/missing/track.flac",
                title: track?.title ?? "Unavailable",
                artistDisplay: track?.artistDisplay ?? "Artist",
                albumTitle: track?.albumTitle ?? "Album"
            )
        )
    }

    private func makeTrack(_ id: Int) -> Track {
        Track(
            id: Int64(id),
            path: "/music/track-\(id).flac",
            title: "Track \(id)",
            artistDisplay: "Artist",
            albumTitle: "Album",
            genreDisplay: "Genre",
            duration: 60,
            format: "flac"
        )
    }
}
