import AppKit
import WavebookCore

final class SearchPageViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    var onPlay: ((Track) -> Void)?
    var onArtistSelect: ((String) -> Void)?
    var onAlbumSelect: ((AlbumKey) -> Void)?
    var onGenreSelect: ((String) -> Void)?

    private enum Row {
        case header(String)
        case song(Track)
        case artist(LibraryNameSummary)
        case album(LibraryAlbumSummary)
        case genre(LibraryNameSummary)
    }

    private let collectionView = ActivatingCollectionView()
    private let emptyLabel = NSTextField(labelWithString: "No results")
    private let artworkLoader = ArtworkImageLoader.shared
    private var rows: [Row] = []
    private var searchTracks: [Track] = []

    override func loadView() {
        let root = ThemeBackgroundView()
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.backgroundColor = AppTheme.background
        scrollView.drawsBackground = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let layout = InvalidatingFlowLayout()
        layout.minimumLineSpacing = 1
        layout.sectionInset = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.backgroundColors = [AppTheme.background]
        collectionView.register(SearchHeaderItem.self, forItemWithIdentifier: SearchHeaderItem.identifier)
        collectionView.register(BrowseItem.self, forItemWithIdentifier: BrowseItem.identifier)
        collectionView.onActivateSelection = { [weak self] in self?.activateSelectedResult() }
        collectionView.onDoubleClick = { [weak self] indexPath in self?.activateResult(at: indexPath.item) }
        collectionView.onWindowChange = { [weak self] window in
            if window == nil {
                self?.cancelVisibleArtworkRequests()
            }
        }

        emptyLabel.textColor = AppTheme.secondaryText
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = collectionView
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor)
        ])
        view = root
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        rows.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let row = rows[indexPath.item]
        if case let .header(title) = row {
            guard let item = collectionView.makeItem(
                withIdentifier: SearchHeaderItem.identifier,
                for: indexPath
            ) as? SearchHeaderItem else { return NSCollectionViewItem() }
            item.configure(title)
            return item
        }

        guard let item = collectionView.makeItem(
            withIdentifier: BrowseItem.identifier,
            for: indexPath
        ) as? BrowseItem else { return NSCollectionViewItem() }
        item.cancelArtworkRequest()
        let entry = browseEntry(for: row)
        let request = entry.artworkTrackPath.map { path in
            artworkLoader.requestImage(forPath: path) { [weak item] image in item?.setArtwork(image) }
        }
        item.configure(with: entry, artwork: request?.image)
        item.setArtworkRequest(request)
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        let width = max(collectionView.enclosingScrollView?.contentView.bounds.width ?? collectionView.bounds.width, 32)
        let height: CGFloat = if case .header = rows[indexPath.item] { 36 } else { 56 }
        return NSSize(width: width - 32, height: height)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        shouldSelectItemsAt indexPaths: Set<IndexPath>
    ) -> Set<IndexPath> {
        Set(indexPaths.filter { indexPath in
            guard rows.indices.contains(indexPath.item) else { return false }
            if case .header = rows[indexPath.item] { return false }
            return true
        })
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let index = indexPaths.first?.item, rows.indices.contains(index) else { return }
        switch rows[index] {
        case let .artist(artist): onArtistSelect?(artist.name)
        case let .album(album): onAlbumSelect?(album.key)
        case let .genre(genre): onGenreSelect?(genre.name)
        case .header, .song: break
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        collectionView.collectionViewLayout?.invalidateLayout()
    }

    private func browseEntry(for row: Row) -> BrowseListViewController.Entry {
        switch row {
        case .header:
            return .init(title: "", subtitle: "", artworkTrackPath: nil)
        case let .song(track):
            let subtitle = [track.artistDisplay, track.albumTitle].filter { !$0.isEmpty }.joined(separator: " • ")
            return .init(title: track.title, subtitle: subtitle, artworkTrackPath: track.path)
        case let .artist(artist):
            return .init(
                title: artist.name,
                subtitle: countLabel(artist.trackCount, singular: "song") + " • "
                    + countLabel(artist.albumCount, singular: "album"),
                artworkTrackPath: nil
            )
        case let .album(album):
            return .init(
                title: album.key.title,
                subtitle: [album.key.owner, countLabel(album.trackCount, singular: "song")]
                    .filter { !$0.isEmpty }
                    .joined(separator: " • "),
                artworkTrackPath: album.artworkTrackPath
            )
        case let .genre(genre):
            return .init(
                title: genre.name,
                subtitle: countLabel(genre.trackCount, singular: "song"),
                artworkTrackPath: nil
            )
        }
    }

    private func countLabel(_ count: Int, singular: String) -> String {
        "\(count) \(singular)\(count == 1 ? "" : "s")"
    }

    private func activateSelectedResult() {
        guard let index = collectionView.selectionIndexPaths.first?.item else { return }
        activateResult(at: index)
    }

    private func activateResult(at index: Int) {
        guard rows.indices.contains(index), case let .song(track) = rows[index] else { return }
        onPlay?(track)
    }

    private func cancelVisibleArtworkRequests() {
        collectionView.visibleItems().compactMap { $0 as? BrowseItem }.forEach { $0.cancelArtworkRequest() }
    }

    private func setPage(_ page: CatalogSearchPage) {
        cancelVisibleArtworkRequests()
        searchTracks = page.songs.tracks
        rows = []
        append(page.songs.tracks.map(Row.song), header: "Songs")
        append(page.artists.items.map(Row.artist), header: "Artists")
        append(page.albums.items.map(Row.album), header: "Albums")
        append(page.genres.items.map(Row.genre), header: "Genres")
        emptyLabel.isHidden = !rows.isEmpty
        collectionView.selectionIndexPaths = []
        collectionView.reloadData()
    }

    private func append(_ resultRows: [Row], header: String) {
        guard !resultRows.isEmpty else { return }
        rows.append(.header(header))
        rows.append(contentsOf: resultRows)
    }
}

extension SearchPageViewController: CatalogNavigationHost {
    var page: LibraryPage { .search }
    var route: CatalogRoute { .search }
    var selectedTrack: Track? {
        guard let index = collectionView.selectionIndexPaths.first?.item,
              rows.indices.contains(index),
              case let .song(track) = rows[index] else { return nil }
        return track
    }
    var tracks: [Track] { searchTracks }

    func activate() { collectionView.reloadData() }
    func deactivate() { cancelVisibleArtworkRequests() }
    func refresh() {}
    func select(route: CatalogRoute) {}
    func clear() {
        setPage(CatalogSearchPage(
            songs: emptyTrackPage(),
            artists: emptyNamePage(),
            albums: emptyAlbumPage(),
            genres: emptyNamePage()
        ))
    }

    func apply(result: CatalogPageResult) {
        guard case let .search(_, page) = result else { return }
        setPage(page)
    }

    func appendRequest(query: String, kind: CatalogAppendKind) -> CatalogPageAppendRequest? { nil }
    func shuffleRequest(query: String) -> CatalogShuffleRequest? { .songs(query: query) }

    private func emptyTrackPage() -> LibraryTrackPage {
        LibraryTrackPage(tracks: [], offset: 0, limit: 0, hasMore: false)
    }

    private func emptyNamePage() -> LibraryNamePage {
        LibraryNamePage(items: [], offset: 0, limit: 0, hasMore: false)
    }

    private func emptyAlbumPage() -> LibraryAlbumPage {
        LibraryAlbumPage(items: [], offset: 0, limit: 0, hasMore: false)
    }
}

private final class SearchHeaderItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("SearchHeaderItem")
    private let label = NSTextField(labelWithString: "")

    override func loadView() {
        let container = ThemeAwareView()
        label.font = .systemFont(ofSize: 15, weight: .bold)
        label.textColor = AppTheme.primaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -4),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5)
        ])
        view = container
    }

    func configure(_ title: String) { label.stringValue = title }
}
