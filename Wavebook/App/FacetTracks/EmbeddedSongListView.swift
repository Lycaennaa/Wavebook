import AppKit
import WavebookCore

final class EmbeddedSongListView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    var onPlay: ((Track) -> Void)?
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
    var onAlbumSelect: ((AlbumKey) -> Void)?
    var onArtistSelect: ((String) -> Void)?
    var onGenreSelect: ((String) -> Void)?
    private var displayedTracks: [Track] = []
    private let collectionView = ActivatingCollectionView()
    private let artworkLoader = ArtworkImageLoader.shared
    private var heightConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let layout = InvalidatingFlowLayout()
        layout.minimumLineSpacing = 1
        layout.sectionInset = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [AppTheme.background]
        collectionView.register(SongItem.self, forItemWithIdentifier: SongItem.identifier)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        configureContextMenu()
        collectionView.onDoubleClick = { [weak self] indexPath in
            guard let self, self.displayedTracks.indices.contains(indexPath.item) else { return }
            self.onPlay?(self.displayedTracks[indexPath.item])
        }
        collectionView.onWindowChange = { [weak self] window in
            guard let self else { return }
            if window == nil {
                self.cancelVisibleArtworkRequests()
            } else {
                self.collectionView.reloadData()
            }
        }

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
    private func configureContextMenu() {
        collectionView.onContextMenu = { [weak self] clicked, selection in
            guard let self, self.displayedTracks.indices.contains(clicked.item) else { return nil }
            let tracks = selection.sorted { $0.item < $1.item }.compactMap { indexPath in
                self.displayedTracks.indices.contains(indexPath.item) ? self.displayedTracks[indexPath.item] : nil
            }
            return makeTrackContextMenu(
                tracks: tracks,
                contextTrack: self.displayedTracks[clicked.item],
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
        collectionView.visibleItems()
            .compactMap { $0 as? SongItem }
            .forEach { $0.cancelArtworkRequest() }
    }

    func activate() {
        let selection = collectionView.selectionIndexPaths
        collectionView.reloadData()
        collectionView.selectionIndexPaths = Set(selection.filter { displayedTracks.indices.contains($0.item) })
    }

    func deactivate() {
        cancelVisibleArtworkRequests()
    }
    private func selectedTracks() -> [Track] {
        collectionView.selectionIndexPaths
            .sorted { $0.item < $1.item }
            .compactMap { indexPath in
                displayedTracks.indices.contains(indexPath.item) ? displayedTracks[indexPath.item] : nil
            }
    }

    private func restoreSelection(for selectedTracks: [Track]) {
        collectionView.selectionIndexPaths = Set(displayedTracks.indices.compactMap { index in
            let track = displayedTracks[index]
            guard selectedTracks.contains(where: { $0.hasSameIdentity(as: track) }) else { return nil }
            return IndexPath(item: index, section: 0)
        })
    }

    func setTracks(_ tracks: [Track]) {
        let selectedTracks = selectedTracks()
        cancelVisibleArtworkRequests()
        displayedTracks = tracks
        onPrefetchLyricsFileAvailability?(tracks)
        collectionView.reloadData()
        restoreSelection(for: selectedTracks)
        heightConstraint?.constant = CGFloat(tracks.count * 80) + 24
    }

    var selectedTrack: Track? {
        guard let selected = selectedTracks().first else { return nil }
        return displayedTracks.first { $0.hasSameIdentity(as: selected) }
    }

    var tracks: [Track] {
        displayedTracks
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        displayedTracks.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        guard let item = collectionView.makeItem(
            withIdentifier: SongItem.identifier,
            for: indexPath
        ) as? SongItem else {
            return NSCollectionViewItem()
        }
        item.cancelArtworkRequest()
        let track = displayedTracks[indexPath.item]
        let request = artworkLoader.requestImage(forPath: track.path) { [weak item] image in
            item?.setArtwork(image)
        }
        item.configure(with: track, artwork: request.image)
        item.setFavoriteHandler { [weak self] in self?.onToggleFavorite?([track]) }
        item.setArtworkRequest(request)
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        NSSize(width: max(collectionView.bounds.width - 32, 32), height: 80)
    }

}
