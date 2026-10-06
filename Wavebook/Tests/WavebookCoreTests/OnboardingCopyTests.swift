import XCTest

final class OnboardingCopyTests: XCTestCase {
    func testBundledCopyFileDecodesEveryWelcomeField() throws {
        let bundle = Bundle(for: OnboardingCopyTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "OnboardingCopy", withExtension: "json"))
        let copy = try OnboardingCopy.load(from: url)

        XCTAssertEqual(copy.welcome.title, "Welcome to Wavebook")
        XCTAssertEqual(copy.welcome.libraryDescription, "Browse by song, artist, album, or genre.")
        XCTAssertEqual(
            copy.welcome.featureDescription,
            "Adjust playback with the equalizer and ReplayGain. "
                + "With offline lyrics and optional online search."
        )
        XCTAssertEqual(
            copy.welcome.folderAccessDescription,
            "Wavebook scans only selected folders. Audio files are not moved or deleted."
        )
        XCTAssertEqual(copy.welcome.chooseFoldersButtonTitle, "Choose Music Folders…")
        XCTAssertEqual(copy.welcome.chooseFoldersAccessibilityHelp, "Choose one or more local folders to scan.")
        XCTAssertEqual(copy.welcome.exitButtonTitle, "Exit Onboarding")
        XCTAssertEqual(copy.welcome.exitAccessibilityHelp, "Open Wavebook without selecting music folders.")
    }

    func testIncompleteCopyDocumentIsRejected() {
        let data = Data(#"{"welcome":{"title":"Welcome"}}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(OnboardingCopy.self, from: data))
    }
}
