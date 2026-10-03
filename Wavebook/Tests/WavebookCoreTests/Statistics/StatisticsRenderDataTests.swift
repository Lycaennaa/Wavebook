@testable import WavebookCore
import XCTest

final class StatisticsRenderDataTests: XCTestCase {
    func testSummaryRenderDataContainsOnlyDeclaredRowsPerColumn() {
        let year = ListeningStatisticsSummary(
            qualifiedPlayCount: 7,
            listenedSeconds: 3661,
            uniqueSongCount: 4,
            uniqueArtistCount: 3,
            skipCount: 2
        )
        let lifetime = ListeningStatisticsSummary(
            qualifiedPlayCount: 19,
            listenedSeconds: 7200,
            uniqueSongCount: 11,
            uniqueArtistCount: 8,
            skipCount: 5
        )

        let renderData = ListeningStatisticsSummaryRenderData(year: year, lifetime: lifetime)

        XCTAssertEqual(renderData.columns.count, 2)
        XCTAssertEqual(renderData.columns.map(\.count), [2, 2])
        XCTAssertEqual(renderData.columns[0], [
            .playsAndTime(qualifiedPlayCount: 7, listenedSeconds: 3661),
            .songsArtistsAndSkips(uniqueSongCount: 4, uniqueArtistCount: 3, skipCount: 2)
        ])
        XCTAssertEqual(renderData.columns[1], [
            .playsAndTime(qualifiedPlayCount: 19, listenedSeconds: 7200),
            .songsArtistsAndSkips(uniqueSongCount: 11, uniqueArtistCount: 8, skipCount: 5)
        ])
    }
}
