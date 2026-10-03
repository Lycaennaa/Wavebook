import XCTest

final class SongListPaginationPolicyTests: XCTestCase {
    func testDoesNotRequestMoreBeforeLayoutGeometryIsAvailable() {
        XCTAssertFalse(shouldRequestMore(documentHeight: 0, viewportHeight: 800, visibleMaxY: 800))
        XCTAssertFalse(shouldRequestMore(documentHeight: 2_000, viewportHeight: 0, visibleMaxY: 0))
    }

    func testRequestsMoreOnlyNearTheDocumentEndOrWhenFillingViewport() {
        XCTAssertFalse(shouldRequestMore(documentHeight: 5_000, viewportHeight: 800, visibleMaxY: 800))
        XCTAssertTrue(shouldRequestMore(documentHeight: 5_000, viewportHeight: 800, visibleMaxY: 3_880))
        XCTAssertTrue(shouldRequestMore(documentHeight: 500, viewportHeight: 800, visibleMaxY: 800))
    }

    func testDoesNotRequestMoreWhenNoPagesRemain() {
        XCTAssertFalse(
            SongListPaginationPolicy.shouldRequestMore(
                hasMore: false,
                documentHeight: 500,
                viewportHeight: 800,
                visibleMaxY: 800
            )
        )
    }

    private func shouldRequestMore(documentHeight: CGFloat, viewportHeight: CGFloat, visibleMaxY: CGFloat) -> Bool {
        SongListPaginationPolicy.shouldRequestMore(
            hasMore: true,
            documentHeight: documentHeight,
            viewportHeight: viewportHeight,
            visibleMaxY: visibleMaxY
        )
    }
}
