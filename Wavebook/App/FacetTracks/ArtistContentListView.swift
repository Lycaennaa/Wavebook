import AppKit
import WavebookCore

final class ArtistContentListView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    var onPlay: ((Track) -> Void)?
    var onAlbumSelect: ((AlbumKey) -> Void)?
    var onArtistSelect: ((String) -> Void)?
    var onGenreSelect: ((String) -> Void)?
    var onAddToQueue: (([Track]) -> Void)?
    var onAddNextToQueue: (([Track]) -> Void)?
    var onDownloadLyrics: ((Track) -> Void)?
    var onOpenLyricsInApp: ((Track, URL) -> Void)?
    var onShowLyricsInFinder: ((Track) -> Void)?
    var lyricsFileAvailabilityProvider: ((Track) -> Bool?)?
    var onPrefetchLyricsFileAvailability: (([Track]) -> Void)?
    var lyricsFileAvailabilityObserver: LyricsFileAvailabilityObserver?
    var onManageSkipSegments: ((Track) -> Void)?
    var onRescanLoudness: (([Track]) -> Void)?
    var onToggleFavorite: (([Track]) -> Void)?
    var manualPlaylists: [Playlist] = []
    var onAddToPlaylist: (([Track], Int64) -> Void)?

    private enum Row {
        case header(String)
        case text(String)
        case artists([String])
        case album(LibraryArtistAlbumSummary)
        case track(Track)
    }

    private var rows: [Row] = []
    private var displayedTracks: [Track] = []
    private let collectionView = ActivatingCollectionView()
    private let artworkLoader = ArtworkImageLoader.shared
    private var heightConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureCollectionView()
        configureCollectionViewActions()
        configureConstraints()
        isHidden = true
    }

    private func configureCollectionView() {
        let layout = InvalidatingFlowLayout()
        layout.minimumLineSpacing = 1
        layout.sectionInset = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [AppTheme.background]
        collectionView.register(ArtistHeaderItem.self, forItemWithIdentifier: ArtistHeaderItem.identifier)
        collectionView.register(ArtistTextItem.self, forItemWithIdentifier: ArtistTextItem.identifier)
        collectionView.register(ArtistNamesItem.self, forItemWithIdentifier: ArtistNamesItem.identifier)
        collectionView.register(ArtistAlbumItem.self, forItemWithIdentifier: ArtistAlbumItem.identifier)
        collectionView.register(SongItem.self, forItemWithIdentifier: SongItem.identifier)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureCollectionViewActions() {
        collectionView.onSelectAll = { [weak self] in
            guard let self else { return [] }
            return Set(self.rows.indices.compactMap { index in
                if case .track = self.rows[index] { return IndexPath(item: index, section: 0) }
                return nil
            })
        }
        collectionView.onContextMenu = { [weak self] clicked, selection in
            guard let self,
                  self.rows.indices.contains(clicked.item),
                  case let .track(lyricsTrack) = self.rows[clicked.item] else { return nil }
            let tracks = selection.sorted { $0.item < $1.item }.compactMap { indexPath -> Track? in
                guard self.rows.indices.contains(indexPath.item),
                      case let .track(track) = self.rows[indexPath.item] else { return nil }
                return track
            }
            return makeTrackContextMenu(
                tracks: tracks,
                contextTrack: lyricsTrack,
                actions: TrackContextMenuActions(
                    onAddToQueue: self.onAddToQueue,
                    onAddNextToQueue: self.onAddNextToQueue,
                    onDownloadLyrics: self.onDownloadLyrics,
                    onOpenLyricsInApp: self.onOpenLyricsInApp,
                    onShowLyricsInFinder: self.onShowLyricsInFinder,
                    lyricsFileAvailabilityProvider: self.lyricsFileAvailabilityProvider,
                    lyricsFileAvailabilityObserver: self.lyricsFileAvailabilityObserver,
                    onManageSkipSegments: self.onManageSkipSegments,
                    onAlbumSelect: self.onAlbumSelect,
                    onArtistSelect: self.onArtistSelect,
                    onGenreSelect: self.onGenreSelect,
                    onRescanLoudness: self.onRescanLoudness,
                    onToggleFavorite: self.onToggleFavorite,
                    manualPlaylists: self.manualPlaylists,
                    onAddToPlaylist: self.onAddToPlaylist
                )
            )
        }
        collectionView.onDoubleClick = { [weak self] indexPath in
            guard let self,
                  self.rows.indices.contains(indexPath.item),
                  case let .track(track) = self.rows[indexPath.item] else { return }
            self.onPlay?(track)
        }
        collectionView.onWindowChange = { [weak self] window in
            guard let self else { return }
            if window == nil {
                self.cancelVisibleArtworkRequests()
            } else {
                self.collectionView.reloadData()
            }
        }
    }

    private func configureConstraints() {
        addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let height = heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
        heightConstraint = height
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        collectionView.collectionViewLayout?.invalidateLayout()
    }

    private func cancelVisibleArtworkRequests() {
        for item in collectionView.visibleItems() {
            (item as? SongItem)?.cancelArtworkRequest()
            (item as? ArtistAlbumItem)?.cancelArtworkRequest()
        }
    }

    func activate() {
        let selection = collectionView.selectionIndexPaths
        collectionView.reloadData()
        collectionView.selectionIndexPaths = Set(selection.filter { rows.indices.contains($0.item) })
    }

    func deactivate() {
        cancelVisibleArtworkRequests()
    }
    private func selectedTracks() -> [Track] {
        collectionView.selectionIndexPaths
            .sorted { $0.item < $1.item }
            .compactMap { indexPath in
                guard rows.indices.contains(indexPath.item),
                      case let .track(track) = rows[indexPath.item] else { return nil }
                return track
            }
    }

    private func restoreSelection(for selectedTracks: [Track]) {
        collectionView.selectionIndexPaths = Set(rows.indices.compactMap { index in
            guard case let .track(track) = rows[index],
                  selectedTracks.contains(where: { $0.hasSameIdentity(as: track) }) else { return nil }
            return IndexPath(item: index, section: 0)
        })
    }

    func setContent(detail: LibraryArtistDetail?, tracks: [Track]) {
        let selectedTracks = selectedTracks()
        cancelVisibleArtworkRequests()

        displayedTracks = tracks
        onPrefetchLyricsFileAvailability?(tracks)
        rows = []
        if let detail {
            if !detail.genres.isEmpty {
                rows.append(.header("Genres"))
                rows.append(.text(detail.genres.joined(separator: ", ")))
            }
            if !detail.ownedAlbums.isEmpty {
                rows.append(.header("Albums"))
                rows.append(contentsOf: detail.ownedAlbums.map(Row.album))
            }
            if !detail.appearingAlbums.isEmpty {
                rows.append(.header("Appears on Albums"))
                rows.append(contentsOf: detail.appearingAlbums.map(Row.album))
            }
        }
        if !tracks.isEmpty, !rows.isEmpty {
            rows.append(.header("Songs"))
        }
        rows.append(contentsOf: tracks.map(Row.track))
        collectionView.reloadData()
        restoreSelection(for: selectedTracks)
        heightConstraint?.constant = rows.reduce(CGFloat(24)) { total, row in total + height(for: row) + 1 }
        isHidden = rows.isEmpty
    }

    func setAlbumContent(tracks: [Track]) {
        let selectedTracks = selectedTracks()
        cancelVisibleArtworkRequests()

        displayedTracks = tracks
        onPrefetchLyricsFileAvailability?(tracks)
        rows = []
        let artists = Array(Set(tracks.flatMap { track -> [String] in
            let artists = track.artists
            return artists.isEmpty ? [""] : artists
        })).sorted(by: CatalogFacetOrdering.localizedNamePrecedes)
        let genres = Array(Set(tracks.flatMap(\.genres))).sorted(by: CatalogFacetOrdering.localizedNamePrecedes)

        if !artists.isEmpty {
            rows.append(.header("Artists"))
            rows.append(.artists(artists))
        }
        if !genres.isEmpty {
            rows.append(.header("Genres"))
            rows.append(.text(genres.joined(separator: ", ")))
        }
        if !tracks.isEmpty, !rows.isEmpty {
            rows.append(.header("Songs"))
        }
        rows.append(contentsOf: tracks.map(Row.track))
        collectionView.reloadData()
        restoreSelection(for: selectedTracks)
        heightConstraint?.constant = rows.reduce(CGFloat(24)) { total, row in total + height(for: row) + 1 }
        isHidden = rows.isEmpty
    }

    var selectedTrack: Track? {
        guard let selected = selectedTracks().first else { return nil }
        return displayedTracks.first { $0.hasSameIdentity(as: selected) }
    }

    var tracks: [Track] { displayedTracks }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        switch rows[indexPath.item] {
        case let .header(text):
            guard let item = collectionView.makeItem(
                withIdentifier: ArtistHeaderItem.identifier,
                for: indexPath
            ) as? ArtistHeaderItem else { return NSCollectionViewItem() }
            item.configure(text)
            return item
        case let .text(text):
            guard let item = collectionView.makeItem(
                withIdentifier: ArtistTextItem.identifier,
                for: indexPath
            ) as? ArtistTextItem else { return NSCollectionViewItem() }
            item.configure(text)
            return item
        case let .artists(artists):
            guard let item = collectionView.makeItem(
                withIdentifier: ArtistNamesItem.identifier,
                for: indexPath
            ) as? ArtistNamesItem else { return NSCollectionViewItem() }
            item.configure(artists)
            item.onArtistSelect = { [weak self] artist in self?.onArtistSelect?(artist) }
            return item
        case let .album(album):
            guard let item = collectionView.makeItem(
                withIdentifier: ArtistAlbumItem.identifier,
                for: indexPath
            ) as? ArtistAlbumItem else { return NSCollectionViewItem() }
            item.cancelArtworkRequest()
            let request = artworkLoader.requestImage(forPath: album.artworkTrackPath) { [weak item] image in
                item?.setArtwork(image)
            }
            item.configure(with: album, artwork: request.image)
            item.setArtworkRequest(request)
            return item
        case let .track(track):
            guard let item = collectionView.makeItem(
                withIdentifier: SongItem.identifier,
                for: indexPath
            ) as? SongItem else { return NSCollectionViewItem() }
            item.cancelArtworkRequest()
            let request = artworkLoader.requestImage(forPath: track.path) { [weak item] image in
                item?.setArtwork(image)
            }
            item.configure(with: track, artwork: request.image)
            item.setFavoriteHandler { [weak self] in self?.onToggleFavorite?([track]) }
            item.setArtworkRequest(request)
            return item
        }
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        NSSize(
            width: max(collectionView.bounds.width - 32, 32),
            height: height(for: rows[indexPath.item])
        )
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let index = indexPaths.first?.item, rows.indices.contains(index) else { return }
        if case let .album(album) = rows[index] { onAlbumSelect?(album.key) }
    }

    private func height(for row: Row) -> CGFloat {
        switch row {
        case .header: return 30
        case let .text(text):
            return max(32, CGFloat(Int(ceil(Double(text.count) / 80.0)) * 18 + 14))
        case let .artists(artists):
            let width = collectionView.bounds.width - 32
            return CGFloat(ArtistNamesItem.rowCount(for: artists, width: width) * 34 + 10)
        case .album, .track: return 80
        }
    }

}
