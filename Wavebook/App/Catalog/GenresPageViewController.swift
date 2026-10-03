import AppKit
import WavebookCore

final class GenresPageViewController: FacetTracksPageViewController {
    init() {
        super.init(kind: .genres)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
extension GenresPageViewController: CatalogNavigationHost {
    var page: LibraryPage { .genres }
    var route: CatalogRoute {
        .genres(selectedGenre: selectedGenreName)
    }

    func refresh() {}
    func select(route: CatalogRoute) {
        if case let .genres(selectedGenre) = route, let selectedGenre {
            selectGenre(selectedGenre)
        }
    }

    func clear() {
        clearLoadedContent()
    }

    func apply(result: CatalogPageResult) {
        guard case let .genres(_, _, change) = result else { return }
        switch change {
        case let .replace(value):
            applyGenres(
                entries: value.entries,
                selectedGenre: value.selectedGenre,
                tracks: value.tracks
            )
        case let .appendEntries(value): appendGenres(value)
        case let .appendDetail(value): appendDetailTracks(value)
        }
    }

    func appendRequest(query: String, kind: CatalogAppendKind) -> CatalogPageAppendRequest? {
        switch kind {
        case .facets where hasMoreFacets:
            return .genreEntries(
                query: query,
                selectedGenre: selectedGenreName,
                offset: loadedFacetCount
            )
        case .details where hasMoreDetails:
            guard let selectedGenre = selectedGenreName else { return nil }
            return .genreDetail(
                query: query,
                selectedGenre: selectedGenre,
                offset: loadedDetailTrackCount
            )
        default:
            return nil
        }
    }

    func shuffleRequest(query: String) -> CatalogShuffleRequest? {
        guard let name = selectedGenreName else { return nil }
        return .genre(query: query, name: name)
    }
}
