@testable import WavebookCore
import XCTest

final class PlaybackQueueCoordinatorTests: XCTestCase {
    @MainActor
    func testRepeatOneReplaysStandaloneTrackWithItsSource() {
        let transport = FakePlaybackQueueTransport()
        let coordinator = PlaybackQueueCoordinator(transport: transport)
        let track = makeTrack(1)
        let source = ListeningPlaybackSource(kind: .playlist, persistentID: 42, sourceName: "Mix")

        coordinator.cycleRepeatMode()
        coordinator.cycleRepeatMode()
        XCTAssertTrue(coordinator.play(track, source: source))

        coordinator.handleNaturalCompletion()

        XCTAssertEqual(transport.playedTracks.count, 2)
        XCTAssertTrue(transport.playedTracks.allSatisfy { $0.hasSameIdentity(as: track) })
        XCTAssertEqual(transport.playedSources, [source, source])
    }

    @MainActor
    func testPlaylistAndShuffleReplacementPreserveRepeatMode() {
        let transport = FakePlaybackQueueTransport()
        let coordinator = PlaybackQueueCoordinator(transport: transport)
        let tracks = [makeTrack(1), makeTrack(2)]
        coordinator.cycleRepeatMode()

        XCTAssertTrue(coordinator.playPlaylist(PlaybackQueue(items: tracks)))
        XCTAssertTrue(coordinator.presentation.repeatMode == .all)

        coordinator.replaceForShuffle(with: PlaybackQueue(items: tracks))

        XCTAssertTrue(coordinator.presentation.repeatMode == .all)
    }

    private func makeTrack(_ id: Int64) -> Track {
        Track(
            id: id,
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

@MainActor
private final class FakePlaybackQueueTransport: PlaybackQueueTransport {
    var currentTrack: Track?
    var currentPlaybackSource = ListeningPlaybackSource(kind: .library)
    var hasAudioSource = false
    var isPlaying = false
    private(set) var playedTracks: [Track] = []
    private(set) var playedSources: [ListeningPlaybackSource] = []

    func withPresentationSuppressed<Result>(_ operation: () throws -> Result) rethrows -> Result {
        try operation()
    }

    func play(
        _ track: Track,
        source: ListeningPlaybackSource,
        trackingEndReason: ListeningEventEndReason?,
        onFailure: @escaping () -> Void
    ) -> Bool {
        playedTracks.append(track)
        playedSources.append(source)
        currentTrack = track
        currentPlaybackSource = source
        hasAudioSource = true
        isPlaying = true
        return true
    }

    func toggleCurrentPlayback() -> Bool {
        isPlaying.toggle()
        return true
    }

    func completeNaturalPlayback() {
        hasAudioSource = false
        isPlaying = false
    }
}
