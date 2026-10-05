import AppKit
import WavebookCore
enum CatalogAppendKind {
    case page
    case facets
    case details
}

@MainActor
protocol NavigationHost: AnyObject {
    var page: LibraryPage { get }
    var view: NSView { get }
    var selectedTrack: Track? { get }
    var tracks: [Track] { get }
    func activate()
    func deactivate()
    func refresh()
}

@MainActor
protocol CatalogNavigationHost: NavigationHost {
    var route: CatalogRoute { get }
    func select(route: CatalogRoute)
    func clear()
    func apply(result: CatalogPageResult)
    func appendRequest(query: String, kind: CatalogAppendKind) -> CatalogPageAppendRequest?
    func shuffleRequest(query: String) -> CatalogShuffleRequest?
}
