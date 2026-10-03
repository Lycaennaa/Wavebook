@testable import WavebookCore
import XCTest

final class PlaybackWaveformViewportTests: XCTestCase {
    func testZoomIsBoundedAndCentered() {
        var viewport = PlaybackWaveformViewport(duration: 100)

        XCTAssertTrue(viewport.zoomIn(centeredAt: 50))
        XCTAssertEqual(viewport.zoomScale, 2)
        XCTAssertEqual(viewport.start, 25)
        XCTAssertEqual(viewport.end, 75)

        for _ in 0..<10 {
            _ = viewport.zoomIn(centeredAt: 50)
        }
        XCTAssertEqual(viewport.zoomScale, PlaybackWaveformViewport.maximumZoomScale)
        XCTAssertFalse(viewport.zoomIn(centeredAt: 50))

        XCTAssertTrue(viewport.resetZoom())
        XCTAssertEqual(viewport.zoomScale, 1)
        XCTAssertEqual(viewport.start, 0)
        XCTAssertEqual(viewport.end, 100)
    }

    func testPanClampsToDuration() {
        var viewport = PlaybackWaveformViewport(duration: 100)
        _ = viewport.setZoomScale(4, centeredAt: 50)

        XCTAssertTrue(viewport.pan(byFraction: 10))
        XCTAssertEqual(viewport.start, 75)
        XCTAssertEqual(viewport.end, 100)
        XCTAssertFalse(viewport.pan(byFraction: 1))

        XCTAssertTrue(viewport.pan(byFraction: -10))
        XCTAssertEqual(viewport.start, 0)
        XCTAssertEqual(viewport.end, 25)
    }

    func testDurationChangeClampsStartAndInvalidatesSafely() {
        var viewport = PlaybackWaveformViewport(duration: 100)
        _ = viewport.setZoomScale(4, centeredAt: 100)
        viewport.setDuration(20)

        XCTAssertEqual(viewport.duration, 20)
        XCTAssertEqual(viewport.start, 15)
        XCTAssertEqual(viewport.end, 20)

        viewport.setDuration(-1)
        XCTAssertEqual(viewport.duration, 0)
        XCTAssertEqual(viewport.start, 0)
        XCTAssertEqual(viewport.end, 0)
    }

    func testEnsureVisibleKeepsFocusInsideViewport() {
        var viewport = PlaybackWaveformViewport(duration: 100)
        _ = viewport.setZoomScale(4, centeredAt: 10)
        XCTAssertEqual(viewport.start, 0)
        XCTAssertEqual(viewport.end, 25)

        XCTAssertTrue(viewport.ensureVisible(90))
        XCTAssertEqual(viewport.start, 75)
        XCTAssertEqual(viewport.end, 100)
        XCTAssertFalse(viewport.ensureVisible(90))
    }
}
