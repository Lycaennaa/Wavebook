@testable import WavebookCore
import XCTest

final class PlaybackTimecodeTests: XCTestCase {
    func testParsesSecondsAndColonSeparatedValues() {
        XCTAssertEqual(PlaybackTimecode.parse("90"), 90)
        XCTAssertEqual(PlaybackTimecode.parse("1:30"), 90)
        XCTAssertEqual(PlaybackTimecode.parse("1:01:02.5"), 3_662.5)
    }

    func testRejectsInvalidTimeValues() {
        XCTAssertNil(PlaybackTimecode.parse(""))
        XCTAssertNil(PlaybackTimecode.parse("1:60"))
        XCTAssertNil(PlaybackTimecode.parse("1:02:60"))
        XCTAssertNil(PlaybackTimecode.parse("-1"))
        XCTAssertNil(PlaybackTimecode.parse("1:2:3:4"))
    }

    func testFormatsHoursAndFractionalSeconds() {
        XCTAssertEqual(PlaybackTimecode.string(from: 3_662.5), "1:01:02.50")
        XCTAssertEqual(PlaybackTimecode.string(from: 90), "1:30")
        XCTAssertEqual(PlaybackTimecode.string(from: 90.5, includingFractionalSeconds: false), "1:31")
    }
}
