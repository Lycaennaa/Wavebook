import AppKit
import WavebookCore

class FacetTracksPageViewController: NSViewController {
    enum Kind {
        case artists
        case albums
        case genres
    }

    var actions = SongListActions() {
        didSet {
            trackList.actions = actions
            artistContentList.actions = actions
        }
    }
    var onSelectionChanged: (() -> Void)?
    var onRequestMoreFacets: (() -> Void)?
    var onRequestMoreDetails: (() -> Void)?

    private let kind: Kind
    private let facetList = BrowseListViewController()
    private let trackList = EmbeddedSongListView()
    private let artistContentList = ArtistContentListView()
    private var state = FacetTracksPageState()
    private var revealSelectedFacetOnReload = false
    private weak var detailScrollView: NSScrollView?
    nonisolated(unsafe) private var detailScrollObserver: NSObjectProtocol?

    deinit {
        if let detailScrollObserver {
            NotificationCenter.default.removeObserver(detailScrollObserver)
        }
    }

    func activate() {
        facetList.activate()
        trackList.activate()
        artistContentList.activate()
    }

    func deactivate() {
        facetList.deactivate()
        trackList.deactivate()
        artistContentList.deactivate()
        clearLoadedContent()
    }

    init(kind: Kind) {
        self.kind = kind
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let stack = NSStackView()
        let scrollView = NSScrollView()
        let detailStack = NSStackView()
        let documentView = FlippedDocumentView()
        configureLayout(
            stack: stack,
            scrollView: scrollView,
            detailStack: detailStack,
            documentView: documentView
        )
        configureFacetListActions()
        view = stack
    }

    private func requestMoreDetailsIfNeeded() {
        guard hasMoreDetails,
              let scrollView = detailScrollView,
              let documentView = scrollView.documentView else { return }
        let viewportHeight = scrollView.contentView.bounds.height
        let threshold = max(documentView.bounds.height - viewportHeight - 480, 0)
        guard scrollView.contentView.bounds.maxY >= threshold else { return }
        onRequestMoreDetails?()
    }

    private func scheduleMoreDetailsCheck() {
        DispatchQueue.main.async { [weak self] in
            self?.requestMoreDetailsIfNeeded()
        }
    }
    func applyArtists(
        entries: LibraryNamePage,
        selectedArtist: String?,
        detail: LibraryArtistDetailPage?
    ) {
        state.applyArtists(entries: entries, selectedArtist: selectedArtist, detail: detail)
        let index = selectedArtist.flatMap { selected in entries.items.firstIndex { $0.name == selected } }
        facetList.setEntries(
            entries.items.map { artistEntry($0) },
            selectedIndex: index,
            revealSelection: revealSelectedFacetOnReload
        )
        trackList.setTracks([])
        artistContentList.setContent(detail: detail?.detail, tracks: detail?.tracks.tracks ?? [])
        revealSelectedFacetOnReload = false
        scheduleMoreDetailsCheck()
    }

    func applyAlbums(
        entries: LibraryAlbumPage,
        selectedAlbum: AlbumKey?,
        tracks: LibraryTrackPage
    ) {
        state.applyAlbums(entries: entries, selectedAlbum: selectedAlbum, tracks: tracks)
        let index = selectedAlbum.flatMap { selected in entries.items.firstIndex { $0.key == selected } }
        facetList.setEntries(
            entries.items.map(albumEntry),
            selectedIndex: index,
            revealSelection: revealSelectedFacetOnReload
        )
        trackList.setTracks([])
        artistContentList.setAlbumContent(tracks: tracks.tracks)
        revealSelectedFacetOnReload = false
        scheduleMoreDetailsCheck()
    }

    func applyGenres(
        entries: LibraryNamePage,
        selectedGenre: String?,
        tracks: LibraryTrackPage
    ) {
        state.applyGenres(entries: entries, selectedGenre: selectedGenre, tracks: tracks)
        let index = selectedGenre.flatMap { selected in entries.items.firstIndex { $0.name == selected } }
        facetList.setEntries(
            entries.items.map { genreEntry($0) },
            selectedIndex: index,
            revealSelection: revealSelectedFacetOnReload
        )
        artistContentList.setContent(detail: nil, tracks: [])
        artistContentList.setAlbumContent(tracks: [])
        trackList.setTracks(tracks.tracks)
        revealSelectedFacetOnReload = false
        scheduleMoreDetailsCheck()
    }

    func appendArtists(_ page: LibraryNamePage) {
        guard state.appendArtists(page) else { return }
        let entries = state.artistEntries
        let index = state.selectedArtist.flatMap { selected in entries.firstIndex { $0.name == selected } }
        facetList.setEntries(entries.map { artistEntry($0) }, selectedIndex: index)
    }

    func appendAlbums(_ page: LibraryAlbumPage) {
        guard state.appendAlbums(page) else { return }
        let entries = state.albumEntries
        let index = state.selectedAlbum.flatMap { selected in entries.firstIndex { $0.key == selected } }
        facetList.setEntries(entries.map(albumEntry), selectedIndex: index)
    }

    func appendGenres(_ page: LibraryNamePage) {
        guard state.appendGenres(page) else { return }
        let entries = state.genreEntries
        let index = state.selectedGenre.flatMap { selected in entries.firstIndex { $0.name == selected } }
        facetList.setEntries(entries.map { genreEntry($0) }, selectedIndex: index)
    }

    func appendArtistDetail(_ page: LibraryArtistDetailPage) {
        guard state.appendArtistDetail(page), let detail = state.artistDetailPage else { return }
        artistContentList.setContent(detail: detail.detail, tracks: detail.tracks.tracks)
        scheduleMoreDetailsCheck()
    }

    func appendDetailTracks(_ page: LibraryTrackPage) {
        guard state.appendDetailTracks(page, kind: kind) else { return }
        switch kind {
        case .artists:
            break
        case .albums:
            artistContentList.setAlbumContent(tracks: state.albumTrackPage?.tracks ?? [])
        case .genres:
            trackList.setTracks(state.genreTrackPage?.tracks ?? [])
        }
        scheduleMoreDetailsCheck()
    }

    var hasMoreFacets: Bool {
        state.hasMoreFacets
    }

    var loadedFacetCount: Int {
        state.loadedFacetCount
    }

    var hasMoreDetails: Bool {
        state.hasMoreDetails
    }

    var loadedDetailTrackCount: Int {
        state.loadedDetailTrackCount
    }

    var detailOffset: Int {
        state.detailOffset
    }

    var detailLimit: Int {
        state.detailLimit
    }

    func clearLoadedContent() {
        setEmpty()
    }

    var selectedTrack: Track? {
        if kind == .artists || kind == .albums { return artistContentList.selectedTrack }
        return trackList.selectedTrack
    }

    var tracks: [Track] {
        if kind == .artists || kind == .albums { return artistContentList.tracks }
        return trackList.tracks
    }

    private func selectFacet(at index: Int) {
        guard state.selectFacet(at: index, kind: kind) else { return }
        onSelectionChanged?()
    }

    private func setEmpty() {
        state.clearContent()
        facetList.setEntries([], selectedIndex: nil)
        trackList.setTracks([])
        artistContentList.setContent(detail: nil, tracks: [])
        artistContentList.setAlbumContent(tracks: [])
    }

    func selectAlbum(_ key: AlbumKey) {
        state.selectAlbum(key)
        revealSelectedFacetOnReload = true
    }

    func selectArtist(_ artist: String) {
        state.selectArtist(artist)
        revealSelectedFacetOnReload = true
    }

    func selectGenre(_ genre: String) {
        state.selectGenre(genre)
        revealSelectedFacetOnReload = true
    }

    var selectedAlbumKey: AlbumKey? {
        state.selectedAlbum
    }

    var selectedArtistName: String? {
        state.selectedArtist
    }

    var selectedGenreName: String? {
        state.selectedGenre
    }

    private func artistEntry(_ summary: LibraryNameSummary) -> BrowseListViewController.Entry {
        var parts = [songCount(summary.trackCount), albumCount(summary.albumCount)]
        if summary.appearanceCount >= 1 { parts.append("\(summary.appearanceCount) appears") }
        let title = summary.name.isEmpty ? "Unknown Artist" : summary.name
        let subtitle = parts.joined(separator: " • ")
        return BrowseListViewController.Entry(title: title, subtitle: subtitle)
    }

    private func genreEntry(_ summary: LibraryNameSummary) -> BrowseListViewController.Entry {
        let title = summary.name.isEmpty ? "Unknown Genre" : summary.name
        let subtitle = "\(songCount(summary.trackCount)) • \(artistCount(summary.artistCount))"
        return BrowseListViewController.Entry(title: title, subtitle: subtitle)
    }

    private func albumEntry(_ summary: LibraryAlbumSummary) -> BrowseListViewController.Entry {
        let title = summary.key.title.isEmpty ? "Unknown Album" : summary.key.title
        let owner = summary.key.owner.isEmpty ? "Unknown Artist" : summary.key.owner
        let subtitle = "\(owner) • \(songCount(summary.trackCount))"
        let artworkPath = summary.artworkTrackPath.isEmpty ? nil : summary.artworkTrackPath
        return BrowseListViewController.Entry(title: title, subtitle: subtitle, artworkTrackPath: artworkPath)
    }

    private func songCount(_ count: Int) -> String {
        "\(count) song\(count == 1 ? "" : "s")"
    }

    private func albumCount(_ count: Int) -> String {
        "\(count) album\(count == 1 ? "" : "s")"
    }

    private func artistCount(_ count: Int) -> String {
        "\(count) artist\(count == 1 ? "" : "s")"
    }
}
extension FacetTracksPageViewController {
    private func configureLayout(
        stack: NSStackView,
        scrollView: NSScrollView,
        detailStack: NSStackView,
        documentView: FlippedDocumentView
    ) {
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .height
        stack.distribution = .fill
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.backgroundColor = AppTheme.background
        scrollView.drawsBackground = true
        detailStack.orientation = .vertical
        detailStack.spacing = 0
        detailStack.alignment = .width
        detailStack.distribution = .fill
        facetList.view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        documentView.translatesAutoresizingMaskIntoConstraints = false
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        trackList.translatesAutoresizingMaskIntoConstraints = false
        artistContentList.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(facetList.view)
        stack.addArrangedSubview(scrollView)
        documentView.addSubview(detailStack)
        detailStack.addArrangedSubview(artistContentList)
        detailStack.addArrangedSubview(trackList)
        scrollView.documentView = documentView
        detailScrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        detailScrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestMoreDetailsIfNeeded()
            }
        }
        NSLayoutConstraint.activate([
            facetList.view.widthAnchor.constraint(equalToConstant: 260),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            detailStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            detailStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            detailStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            detailStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])
    }

    private func configureFacetListActions() {
        facetList.onSelect = { [weak self] index in
            self?.selectFacet(at: index)
        }
        facetList.onRequestMore = { [weak self] in
            self?.onRequestMoreFacets?()
        }
    }
}
