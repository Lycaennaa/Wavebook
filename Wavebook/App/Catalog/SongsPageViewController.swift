import AppKit
import WavebookCore

final class SongsPageViewController: NSViewController {
    var onPlay: ((Track) -> Void)? {
        get { songList.onPlay }
        set { songList.onPlay = newValue }
    }
    var onAddToQueue: (([Track]) -> Void)? {
        get { songList.onAddToQueue }
        set { songList.onAddToQueue = newValue }
    }
    var onAddNextToQueue: (([Track]) -> Void)? {
        get { songList.onAddNextToQueue }
        set { songList.onAddNextToQueue = newValue }
    }
    var onDownloadLyrics: ((Track) -> Void)? {
        get { songList.onDownloadLyrics }
        set { songList.onDownloadLyrics = newValue }
    }
    var onOpenLyricsInApp: ((Track, URL) -> Void)? {
        get { songList.onOpenLyricsInApp }
        set { songList.onOpenLyricsInApp = newValue }
    }
    var onShowLyricsInFinder: ((Track) -> Void)? {
        get { songList.onShowLyricsInFinder }
        set { songList.onShowLyricsInFinder = newValue }
    }
    var lyricsFileAvailabilityProvider: ((Track) -> Bool?)? {
        get { songList.lyricsFileAvailabilityProvider }
        set { songList.lyricsFileAvailabilityProvider = newValue }
    }
    var onPrefetchLyricsFileAvailability: (([Track]) -> Void)? {
        get { songList.onPrefetchLyricsFileAvailability }
        set { songList.onPrefetchLyricsFileAvailability = newValue }
    }
    var lyricsFileAvailabilityObserver: LyricsFileAvailabilityObserver? {
        get { songList.lyricsFileAvailabilityObserver }
        set { songList.lyricsFileAvailabilityObserver = newValue }
    }
    var onManageSkipSegments: ((Track) -> Void)? {
        get { songList.onManageSkipSegments }
        set { songList.onManageSkipSegments = newValue }
    }
    var onRescanLoudness: (([Track]) -> Void)? {
        get { songList.onRescanLoudness }
        set { songList.onRescanLoudness = newValue }
    }
    var onToggleFavorite: (([Track]) -> Void)? {
        get { songList.onToggleFavorite }
        set { songList.onToggleFavorite = newValue }
    }
    var manualPlaylists: [Playlist] {
        get { songList.manualPlaylists }
        set { songList.manualPlaylists = newValue }
    }
    var onAddToPlaylist: (([Track], Int64) -> Void)? {
        get { songList.onAddToPlaylist }
        set { songList.onAddToPlaylist = newValue }
    }
    var onAlbumSelect: ((AlbumKey) -> Void)? {
        get { songList.onAlbumSelect }
        set { songList.onAlbumSelect = newValue }
    }
    var onArtistSelect: ((String) -> Void)? {
        get { songList.onArtistSelect }
        set { songList.onArtistSelect = newValue }
    }
    var onGenreSelect: ((String) -> Void)? {
        get { songList.onGenreSelect }
        set { songList.onGenreSelect = newValue }
    }
    var onRequestMore: (() -> Void)? {
        get { songList.onRequestMore }
        set { songList.onRequestMore = newValue }
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
