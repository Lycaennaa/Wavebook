@testable import WavebookCore
import XCTest

final class InitialLibraryScanShuffleRequestTests: XCTestCase {
    func testDeferredShuffleIsConsumedOnceWhenContextMatches() {
        let context = CatalogPageContext(route: .songs, query: "")
        var request = InitialLibraryScanShuffleRequest<CatalogPageContext>()
        request.deferUntilScanCompletes(in: context)

        XCTAssertTrue(request.takeAfterScanCompletes(in: context))
        XCTAssertFalse(request.takeAfterScanCompletes(in: context))
    }

    func testNavigationContextChangeDiscardsDeferredShuffle() {
        let songsContext = CatalogPageContext(route: .songs, query: "")
        let albumsContext = CatalogPageContext(route: .albums(selectedAlbum: nil), query: "")
        let changedQuery = CatalogPageContext(route: .songs, query: "jazz")

        for context in [albumsContext, changedQuery] {
            var request = InitialLibraryScanShuffleRequest<CatalogPageContext>()
            request.deferUntilScanCompletes(in: songsContext)

            XCTAssertFalse(request.takeAfterScanCompletes(in: context))
            XCTAssertFalse(request.takeAfterScanCompletes(in: songsContext))
        }
    }

    func testExplicitPlaybackCancelsDeferredShuffle() {
        var request = InitialLibraryScanShuffleRequest<CatalogPageContext>()
        request.deferUntilScanCompletes(in: CatalogPageContext(route: .songs, query: ""))
        request.cancel()

        XCTAssertFalse(request.takeAfterScanCompletes(in: CatalogPageContext(route: .songs, query: "")))
    }
}
