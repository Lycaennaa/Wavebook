@testable import WavebookCore
import XCTest

final class ListeningHistoryCancellationTests: XCTestCase {
    func testListeningHistoryQueriesHonorCancelledToken() throws {
        let database = try LibraryDatabase(inMemory: true)
        let token = LibraryDatabaseCancellationToken()
        token.cancel()

        XCTAssertThrowsError(try LibraryDatabase.withCatalogCancellationToken(token) {
            try database.availableListeningYears()
        }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertThrowsError(try LibraryDatabase.withCatalogCancellationToken(token) {
            try database.listeningStatisticsSummary(year: 2024)
        }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertThrowsError(try LibraryDatabase.withCatalogCancellationToken(token) {
            try database.listeningHeatmap(year: 2024)
        }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertThrowsError(try LibraryDatabase.withCatalogCancellationToken(token) {
            try database.listeningRankings(dimension: .song, year: 2024)
        }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertThrowsError(try LibraryDatabase.withCatalogCancellationToken(token) {
            try database.listeningSkippedSongs(year: 2024)
        }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        let day = try XCTUnwrap(ListeningLocalDay("2024-01-01"))
        XCTAssertThrowsError(try LibraryDatabase.withCatalogCancellationToken(token) {
            try database.qualifiedPlayTimeline(day: day)
        }) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }
}
