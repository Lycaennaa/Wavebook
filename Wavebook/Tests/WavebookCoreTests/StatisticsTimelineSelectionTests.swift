import XCTest

final class StatisticsTimelineSelectionTests: XCTestCase {
    func testCheckboxSelectionsAccumulateWithoutRowSelectionReplacingThem() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        var selection = StatisticsTimelineSelection()

        selection.setRowSelection([first])
        selection.enterCheckboxMode()
        selection.setCheckboxSelection(true, for: second)
        selection.setCheckboxSelection(true, for: third)
        selection.setRowSelection([first])
        XCTAssertEqual(selection.eventIDs, Set([first, second, third]))

        selection.setCheckboxSelection(false, for: second)
        XCTAssertEqual(selection.eventIDs, Set([first, third]))
        selection.leaveCheckboxMode()
        selection.setRowSelection([third])
        XCTAssertEqual(selection.eventIDs, Set([third]))
    }
}
