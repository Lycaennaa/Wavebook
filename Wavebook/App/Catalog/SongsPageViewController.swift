import AppKit
import WavebookCore

final class SongsPageViewController: NSViewController {
    var actions: SongListActions {
        get { songList.actions }
        set { songList.actions = newValue }
    }

    private let songList = SongListViewController()

    override func loadView() {
        let root = ThemeBackgroundView()
        addChild(songList)
        let songListView = songList.view
        songListView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(songListView)
        NSLayoutConstraint.activate([
            songListView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            songListView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            songListView.topAnchor.constraint(equalTo: root.topAnchor),
            songListView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
    }

    func activate() {
        songList.activate()
    }

    func deactivate() {
        songList.deactivate()
    }

    func setTracks(_ tracks: [Track]) {
        songList.setTracks(tracks)
    }
    func setPage(_ page: LibraryTrackPage) {
        songList.setPage(page)
    }

    func appendPage(_ page: LibraryTrackPage) {
        songList.appendPage(page)
    }

    var hasMore: Bool {
        songList.hasMore
    }

    var loadedTrackCount: Int {
        songList.tracks.count
    }

    var selectedTrack: Track? {
        songList.selectedTrack
    }

    var tracks: [Track] {
        songList.tracks
    }
}
extension SongsPageViewController: CatalogNavigationHost {
    var page: LibraryPage { .songs }
    var route: CatalogRoute { .songs }

    func refresh() {}
    func select(route: CatalogRoute) {}

    func clear() {
        setTracks([])
    }

    func apply(result: CatalogPageResult) {
        guard case let .songs(_, change) = result else { return }
        switch change {
        case let .replace(value): setPage(value)
        case let .append(value): appendPage(value)
        }
    }

    func appendRequest(query: String, kind: CatalogAppendKind) -> CatalogPageAppendRequest? {
        guard kind == .page, hasMore else { return nil }
        return .songs(query: query, offset: loadedTrackCount)
    }

    func shuffleRequest(query: String) -> CatalogShuffleRequest? {
        .songs(query: query)
    }
}
