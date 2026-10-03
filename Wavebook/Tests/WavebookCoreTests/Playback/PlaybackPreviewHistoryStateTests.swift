@testable import WavebookCore
import XCTest

final class PlaybackPreviewHistoryStateTests: XCTestCase {
    private let track = Track(
        id: 1,
        path: "/music/example.m4a",
        title: "Example",
        artistDisplay: "Artist",
        albumTitle: "Album",
        genreDisplay: "Genre",
        duration: 120,
        format: "m4a"
    )

    func testPlayingPreviewExitRestoresAnalysisPosition() {
        var state = PlaybackPreviewHistoryState.none
        state.setAwaitingAnalysis(for: track)

        XCTAssertNil(state.resolveAnalysis(successfully: true, position: 12, whilePreviewing: true))
        XCTAssertEqual(state, .awaitingPreview(track, position: 12))
        XCTAssertEqual(state.takeAwaitingPreview(), .init(track: track, position: 12))
        XCTAssertEqual(state, .none)
    }

    func testSourceStaysWithDelayedPreviewAndSeekRestoration() {
        let source = ListeningPlaybackSource(
            kind: .playlist,
            persistentID: 42,
            sourceName: "Road Trip"
        )
        var context = PlaybackPreviewHistoryContext()
        context.setAwaitingAnalysis(for: track, source: source)

        XCTAssertNil(context.resolveAnalysis(successfully: true, position: 12, whilePreviewing: true))
        XCTAssertEqual(context.takeAwaitingPreview()?.source, source)

        context.setAwaitingAnalysis(for: track, source: source)
        XCTAssertEqual(context.takePending()?.source, source)
        XCTAssertFalse(context.hasPending)
    }

    func testRequestGenerationRejectsCancelledCompletions() {
        var generation = PlaybackRequestGeneration()
        let first = generation.begin()
        generation.cancel()
        XCTAssertFalse(generation.accepts(first))

        let second = generation.begin()
        XCTAssertTrue(generation.accepts(second))
    }

    func testPausedOrFailedPreviewExitRestoresWithoutAnalysisPosition() {
        var state = PlaybackPreviewHistoryState.awaitingAnalysis(track)

        XCTAssertNil(state.resolveAnalysis(successfully: false, position: 12, whilePreviewing: true))
        XCTAssertEqual(state.takeAwaitingPreview(), .init(track: track, position: nil))

        state.setAwaitingAnalysis(for: track)
        XCTAssertEqual(
            state.resolveAnalysis(successfully: true, position: nil, whilePreviewing: false),
            .init(track: track, position: nil)
        )
        XCTAssertEqual(state, .none)
    }

    func testTrackSwitchOrTerminationClearsPendingState() {
        var state = PlaybackPreviewHistoryState.awaitingPreview(track, position: 20)

        state.clear()

        XCTAssertEqual(state, .none)
        XCTAssertNil(state.takePending())
    }
}
