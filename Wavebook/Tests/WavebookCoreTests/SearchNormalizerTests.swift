@testable import WavebookCore
import XCTest

final class SearchNormalizerTests: XCTestCase {
    func testNormalizeIgnoresCasePunctuationAndDiacritics() {
        XCTAssertEqual(SearchNormalizer.normalizedText("Björk - Jóga (Live)"), "bjork joga live")
        XCTAssertEqual(SearchNormalizer.normalizedText("It's Chill-Out"), "its chillout")
    }

    func testMatchesTokensInAnyOrder() {
        let fields = ["Dayvan Cowboy", "Boards of Canada", "The Campfire Headphase", "Electronic", "dayvan.flac"]
        XCTAssertTrue(SearchNormalizer.matches(query: "canada cowboy", fields: fields))
        XCTAssertTrue(SearchNormalizer.matches(query: "Dayvan.Cowboy", fields: ["Dayvan-Cowboy"]))
        XCTAssertTrue(SearchNormalizer.matches(query: "its", fields: ["It's"] ))
        XCTAssertTrue(SearchNormalizer.matches(query: "Chillout", fields: ["Chill-Out"]))
        XCTAssertFalse(SearchNormalizer.matches(query: "typoo", fields: fields))
    }
    func testNormalizationUsesStableLocaleIndependentRules() {
        XCTAssertEqual(SearchNormalizer.normalizedText("I İ ı i"), "i i ı i")
        XCTAssertEqual(SearchNormalizer.tokens((1...20).map { "t\($0)" }.joined(separator: " ")).count, 16)
    }
}
