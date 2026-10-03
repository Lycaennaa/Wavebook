@testable import WavebookCore
import XCTest

final class PlaylistPageAccumulatorTests: XCTestCase {
    func testAccumulatesContiguousPages() {
        var accumulator = PlaylistPageAccumulator<Int>()

        XCTAssertEqual(
            accumulator.apply(
                page([1, 2], offset: 0, hasMore: true),
                replacing: false,
                maximumRetainedItemCount: 3
            ),
            false
        )
        XCTAssertEqual(
            accumulator.apply(
                page([3], offset: 2, hasMore: false),
                replacing: false,
                maximumRetainedItemCount: 3
            ),
            false
        )
        XCTAssertEqual(accumulator.items, [1, 2, 3])
        XCTAssertFalse(accumulator.hasMore)
    }

    func testRejectsNoncontiguousPageWithoutChangingState() {
        var accumulator = PlaylistPageAccumulator<Int>()
        _ = accumulator.apply(page([1], offset: 0, hasMore: true), replacing: false, maximumRetainedItemCount: 3)

        XCTAssertNil(
            accumulator.apply(
                page([3], offset: 2, hasMore: false),
                replacing: false,
                maximumRetainedItemCount: 3
            )
        )
        XCTAssertEqual(accumulator.items, [1])
        XCTAssertTrue(accumulator.hasMore)
    }

    func testTruncatesAtLimitAndStopsPagination() {
        var accumulator = PlaylistPageAccumulator<Int>()

        XCTAssertEqual(
            accumulator.apply(
                page([1, 2, 3, 4], offset: 0, hasMore: true),
                replacing: false,
                maximumRetainedItemCount: 3
            ),
            true
        )
        XCTAssertEqual(accumulator.items, [1, 2, 3])
        XCTAssertFalse(accumulator.hasMore)
    }

    private func page(_ items: [Int], offset: Int, hasMore: Bool) -> LibraryCatalogPage<Int> {
        LibraryCatalogPage(items: items, offset: offset, limit: items.count, hasMore: hasMore)
    }
}
