import AppKit
import WavebookCore

final class AlbumsPageViewController: FacetTracksPageViewController {
    init() {
        super.init(kind: .albums)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
extension AlbumsPageViewController: CatalogNavigationHost {
    var page: LibraryPage { .albums }
    var route: CatalogRoute {
        .albums(selectedAlbum: selectedAlbumKey)
    }

    func refresh() {}
    func select(route: CatalogRoute) {
        if case let .albums(selectedAlbum) = route, let selectedAlbum {
            selectAlbum(selectedAlbum)
        }
    }

    func clear() {
        clearLoadedContent()
    }

    func apply(result: CatalogPageResult) {
        guard case let .albums(_, _, change) = result else { return }
        switch change {
        case let .replace(value):
            applyAlbums(
                entries: value.entries,
                selectedAlbum: value.selectedAlbum,
                tracks: value.tracks
            )
        case let .appendEntries(value): appendAlbums(value)
        case let .appendDetail(value): appendDetailTracks(value)
        }
    }

    func appendRequest(query: String, kind: CatalogAppendKind) -> CatalogPageAppendRequest? {
        switch kind {
        case .facets where hasMoreFacets:
            return .albumEntries(
                query: query,
                selectedAlbum: selectedAlbumKey,
                offset: loadedFacetCount
            )
        case .details where hasMoreDetails:
            guard let selectedAlbum = selectedAlbumKey else { return nil }
            return .albumDetail(
                query: query,
                selectedAlbum: selectedAlbum,
                offset: loadedDetailTrackCount
            )
        default:
            return nil
        }
    }

    func shuffleRequest(query: String) -> CatalogShuffleRequest? {
        guard let key = selectedAlbumKey else { return nil }
        return .album(query: query, key: key)
    }
}
