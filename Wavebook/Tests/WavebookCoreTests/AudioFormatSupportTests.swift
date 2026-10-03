@testable import WavebookCore
import XCTest

final class AudioFormatSupportTests: XCTestCase {
    func testRequiredV1FormatsStayExplicit() {
        XCTAssertEqual(AudioFormatSupport.requiredV1Extensions, ["flac", "mp3", "opus"])
    }

    func testScanFormatMatchingIsCaseInsensitive() {
        XCTAssertTrue(AudioFormatSupport.shouldScan(URL(fileURLWithPath: "/Music/A.OPUS")))
        XCTAssertTrue(AudioFormatSupport.shouldScan(URL(fileURLWithPath: "/Music/B.FlAc")))
        XCTAssertFalse(AudioFormatSupport.shouldScan(URL(fileURLWithPath: "/Music/C.txt")))
    }

    func testRequiredFormatsAreMarkedForRuntimeProbe() {
        XCTAssertTrue(AudioFormatSupport.requiresRuntimeProbe("opus"))
        XCTAssertTrue(AudioFormatSupport.requiresRuntimeProbe("FLAC"))
        XCTAssertFalse(AudioFormatSupport.requiresRuntimeProbe("txt"))
    }
}
