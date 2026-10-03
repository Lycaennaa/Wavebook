@testable import WavebookCore
import XCTest

final class MediaKeyEventParserTests: XCTestCase {
    func testMediaKeyDownMapsToCommands() {
        XCTAssertEqual(MediaKeyEventParser.command(data1: data1(keyCode: 16, keyState: 0x0A)), .togglePlayPause)
        XCTAssertEqual(MediaKeyEventParser.command(data1: data1(keyCode: 17, keyState: 0x0A)), .nextTrack)
        XCTAssertEqual(MediaKeyEventParser.command(data1: data1(keyCode: 19, keyState: 0x0A)), .nextTrack)
        XCTAssertEqual(MediaKeyEventParser.command(data1: data1(keyCode: 18, keyState: 0x0A)), .previousTrack)
        XCTAssertEqual(MediaKeyEventParser.command(data1: data1(keyCode: 20, keyState: 0x0A)), .previousTrack)
    }

    func testMediaKeyRepeatIsIgnored() {
        XCTAssertNil(MediaKeyEventParser.command(data1: data1(keyCode: 17, keyState: 0x0A) | 0x1))
    }

    func testIgnoresKeyUpAndUnknownKeys() {
        XCTAssertNil(MediaKeyEventParser.command(data1: data1(keyCode: 16, keyState: 0x0B)))
        XCTAssertNil(MediaKeyEventParser.command(data1: data1(keyCode: 21, keyState: 0x0A)))
    }

    private func data1(keyCode: Int, keyState: Int) -> Int {
        (keyCode << 16) | (keyState << 8)
    }
}
