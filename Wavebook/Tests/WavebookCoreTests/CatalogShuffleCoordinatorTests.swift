import Foundation
@testable import WavebookCore
import XCTest

final class CatalogShuffleCoordinatorTests: XCTestCase {
    @MainActor
    func testCancelWhileLoadingPreventsStaleShuffleCallback() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let started = expectation(description: "Shuffle queue load started")
        let finished = expectation(description: "Shuffle queue load finished")
        let callback = expectation(description: "Cancelled shuffle callback")
        callback.isInverted = true
        let gate = ShuffleLoadGate(started: started, finished: finished)
        let coordinator = CatalogShuffleCoordinator(
            databaseProvider: { database },
            queueLoader: { _, _ in gate.load() }
        )

        XCTAssertTrue(coordinator.start(
            request: .songs(query: ""),
            start: .shuffled,
            onSuccess: { _ in callback.fulfill() },
            onFailure: { _ in callback.fulfill() }
        ))
        await fulfillment(of: [started], timeout: 2)
        coordinator.cancel()
        gate.resume()
        await fulfillment(of: [finished], timeout: 2)
        await fulfillment(of: [callback], timeout: 1)
    }

    @MainActor
    func testOrderedPlaybackStartsAtSelectedTrack() async throws {
        let database = try LibraryDatabase(inMemory: true)
        let tracks = (1...3).map(makeTrack)
        let coordinator = CatalogShuffleCoordinator(
            databaseProvider: { database },
            queueLoader: { _, _ in PlaybackQueue(items: tracks) }
        )
        let loaded = expectation(description: "Playback queue loaded")

        XCTAssertTrue(coordinator.start(
            request: .album(query: "", key: AlbumKey(title: "Album", owner: "Artist")),
            start: .selectedTrack(tracks[1]),
            onSuccess: { queue in
                XCTAssertFalse(queue.isShuffled)
                XCTAssertEqual(queue.currentTrack, tracks[1])
                XCTAssertEqual(queue.nextIndex, 2)
                loaded.fulfill()
            },
            onFailure: { error in
                XCTFail("Could not load playback queue: \(error)")
                loaded.fulfill()
            }
        ))

        await fulfillment(of: [loaded], timeout: 2)
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

private final class ShuffleLoadGate: @unchecked Sendable {
    private let started: XCTestExpectation
    private let finished: XCTestExpectation
    private let semaphore = DispatchSemaphore(value: 0)

    init(started: XCTestExpectation, finished: XCTestExpectation) {
        self.started = started
        self.finished = finished
    }

    func load() -> PlaybackQueue {
        started.fulfill()
        semaphore.wait()
        finished.fulfill()
        return PlaybackQueue()
    }

    func resume() {
        semaphore.signal()
    }
}
