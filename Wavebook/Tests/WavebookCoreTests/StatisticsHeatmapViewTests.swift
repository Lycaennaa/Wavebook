import WavebookCore
import XCTest

@MainActor
final class StatisticsHeatmapViewTests: XCTestCase {
    func testVisibleStartBeginsAtFirstQualifiedPlay() throws {
        let days = [
            try heatmapDay("2024-01-01", plays: 0),
            try heatmapDay("2024-01-02", plays: 0),
            try heatmapDay("2024-01-03", plays: 1),
            try heatmapDay("2024-01-04", plays: 0)
        ]

        XCTAssertEqual(StatisticsHeatmapView.visibleStartIndex(in: days), 2)
    }

    func testGridStartsAtFirstActiveWeekAndSizesToRemainingWeeks() {
        let grid = StatisticsHeatmapView.visibleGridMetrics(
            dayCount: 365,
            firstVisibleDayIndex: 220,
            leadingBlanks: 1
        )

        XCTAssertEqual(grid.firstVisibleColumn, 31)
        XCTAssertEqual(grid.columns, 22)
    }

    func testYearWithoutDataHasNoGridColumns() {
        let grid = StatisticsHeatmapView.visibleGridMetrics(
            dayCount: 365,
            firstVisibleDayIndex: 365,
            leadingBlanks: 1
        )

        XCTAssertEqual(grid.firstVisibleColumn, 0)
        XCTAssertEqual(grid.columns, 0)
    }

    func testNoQualifiedPlaysHasNoVisibleStart() throws {
        let days = [
            try heatmapDay("2024-01-01", plays: 0),
            try heatmapDay("2024-01-02", plays: 0)
        ]

        XCTAssertEqual(StatisticsHeatmapView.visibleStartIndex(in: days), days.count)
    }

    private func heatmapDay(_ date: String, plays: Int) throws -> ListeningHeatmapDay {
        ListeningHeatmapDay(day: try XCTUnwrap(ListeningLocalDay(date)), qualifiedPlayCount: plays)
    }
}
