import WavebookCore
import XCTest

@MainActor
final class PlaybackReplayGainControllerTests: XCTestCase {
    func testSetModePersistsSelectionAndRefreshesPlayback() throws {
        let database = try LibraryDatabase(inMemory: true)
        let controller = PlaybackReplayGainController(
            databaseProvider: { database },
            shouldLoadData: { false }
        )
        var refreshCount = 0
        controller.onModeChanged = { refreshCount += 1 }

        XCTAssertTrue(controller.setMode(.album))
        XCTAssertEqual(controller.mode, .album)
        XCTAssertEqual(controller.presentation.mode, .album)
        XCTAssertEqual(try database.replayGainMode(), .album)
        XCTAssertEqual(refreshCount, 1)

        XCTAssertTrue(controller.cycleMode())
        XCTAssertEqual(controller.mode, .off)
        XCTAssertEqual(try database.replayGainMode(), .off)
        XCTAssertEqual(refreshCount, 2)
    }

    func testSetModeWithoutDatabaseLeavesPlaybackUnchanged() {
        let controller = PlaybackReplayGainController(
            databaseProvider: { nil },
            shouldLoadData: { false }
        )
        var didRefresh = false
        controller.onModeChanged = { didRefresh = true }

        XCTAssertFalse(controller.setMode(.track))
        XCTAssertEqual(controller.mode, .defaultValue)
        XCTAssertFalse(didRefresh)
    }
}
