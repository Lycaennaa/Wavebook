import AppKit
import WavebookCore

final class ArtistsPageViewController: FacetTracksPageViewController {
    init() {
        super.init(kind: .artists)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
extension ArtistsPageViewController: CatalogNavigationHost {
    var page: LibraryPage { .artists }
    var route: CatalogRoute {
        .artists(selectedArtist: selectedArtistName)
    }

    func refresh() {}
    func select(route: CatalogRoute) {
        if case let .artists(selectedArtist) = route, let selectedArtist {
            selectArtist(selectedArtist)
        }
    }

    func clear() {
        clearLoadedContent()
    }

    func apply(result: CatalogPageResult) {
        guard case let .artists(_, _, change) = result else { return }
        switch change {
        case let .replace(value):
            applyArtists(
                entries: value.entries,
                selectedArtist: value.selectedArtist,
                detail: value.detail
            )
        case let .appendEntries(value): appendArtists(value)
        case let .appendDetail(value): appendArtistDetail(value)
        }
    }

    func appendRequest(query: String, kind: CatalogAppendKind) -> CatalogPageAppendRequest? {
        switch kind {
        case .facets where hasMoreFacets:
            return .artistEntries(
                query: query,
                selectedArtist: selectedArtistName,
                offset: loadedFacetCount
            )
        case .details where hasMoreDetails:
            guard let selectedArtist = selectedArtistName else { return nil }
            return .artistDetail(
                query: query,
                selectedArtist: selectedArtist,
                detailOffset: detailOffset + detailLimit,
                trackOffset: loadedDetailTrackCount
            )
        default:
            return nil
        }
    }

    func shuffleRequest(query: String) -> CatalogShuffleRequest? {
        guard let name = selectedArtistName else { return nil }
        return .artist(query: query, name: name)
    }
}
