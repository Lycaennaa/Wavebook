import AppKit
import WavebookCore

final class InvalidatingFlowLayout: NSCollectionViewFlowLayout {
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        true
    }
}

final class ActivatingCollectionView: NSCollectionView {
    var onActivateSelection: (() -> Void)?
    var onDoubleClick: ((IndexPath) -> Void)?
    var onSelectAll: (() -> Set<IndexPath>)?
    var onContextMenu: ((IndexPath, Set<IndexPath>) -> NSMenu?)?
    var onWindowChange: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 76 {
            onActivateSelection?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2,
              let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return }
        onDoubleClick?(indexPath)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard allowsMultipleSelection,
              event.modifierFlags.contains(.command),
              event.charactersIgnoringModifiers?.lowercased() == "a" else {
            return super.performKeyEquivalent(with: event)
        }

        if let onSelectAll {
            selectionIndexPaths = onSelectAll()
        } else {
            selectAll(nil)
        }
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let onContextMenu,
              let clicked = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else {
            return super.menu(for: event)
        }
        let selection = selectionIndexPaths.contains(clicked) ? selectionIndexPaths : Set([clicked])
        guard let menu = onContextMenu(clicked, selection) else { return nil }
        selectionIndexPaths = selection
        return menu
    }
}

final class SongListViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    private static let maximumDisplayedTrackCount = PlaybackQueue.maximumEntryCount
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
    var onAlbumSelect: ((AlbumKey) -> Void)?
    var onArtistSelect: ((String) -> Void)?
    var onGenreSelect: ((String) -> Void)?
    var onRescanLoudness: (([Track]) -> Void)?
    var onToggleFavorite: (([Track]) -> Void)?
    var manualPlaylists: [Playlist] = []
    var onAddToPlaylist: (([Track], Int64) -> Void)?
    var onRequestMore: (() -> Void)?
    private var displayedTracks: [Track] = []
    private let collectionView = ActivatingCollectionView()
    private let artworkLoader = ArtworkImageLoader.shared
    nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
    }

    private func requestMoreIfNeeded() {
        guard hasMore,
              let scrollView = collectionView.enclosingScrollView,
              let layout = collectionView.collectionViewLayout,
              SongListPaginationPolicy.shouldRequestMore(
                hasMore: hasMore,
                documentHeight: layout.collectionViewContentSize.height,
                viewportHeight: scrollView.contentView.bounds.height,
                visibleMaxY: scrollView.contentView.bounds.maxY
              ) else { return }
        onRequestMore?()
    }
    private func scheduleMoreCheck() {
        DispatchQueue.main.async { [weak self] in
            self?.requestMoreIfNeeded()
        }
    }

    var hasMore = false

    override func loadView() {
        let scrollView = makeScrollView()

        let layout = InvalidatingFlowLayout()
        layout.minimumLineSpacing = 1
        layout.sectionInset = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [AppTheme.background]
        collectionView.autoresizingMask = [.width]
        collectionView.register(SongItem.self, forItemWithIdentifier: SongItem.identifier)
        collectionView.onActivateSelection = { [weak self] in
            guard let track = self?.selectedTrack else { return }
            self?.onPlay?(track)
        }
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

        scrollView.documentView = collectionView
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestMoreIfNeeded()
            }
        }

        view = scrollView
    }

    private func makeScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.backgroundColor = AppTheme.background
        scrollView.drawsBackground = true
        return scrollView
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

    private func cancelVisibleArtworkRequests() {
        collectionView.visibleItems()
            .compactMap { $0 as? SongItem }
            .forEach { $0.cancelArtworkRequest() }
    }

    func activate() {
        let selection = collectionView.selectionIndexPaths
        collectionView.reloadData()
        collectionView.selectionIndexPaths = Set(selection.filter { displayedTracks.indices.contains($0.item) })
        scheduleMoreCheck()
    }

    func deactivate() {
        cancelVisibleArtworkRequests()
        displayedTracks.removeAll(keepingCapacity: false)
        hasMore = false
        collectionView.selectionIndexPaths = Set<IndexPath>()
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
        item.setFavoriteHandler { [weak self] in self?.onToggleFavorite?([track]) }
        item.configure(with: track, artwork: request.image)
        item.setArtworkRequest(request)
        return item
    }
    func collectionView(
        _ collectionView: NSCollectionView,
        didEndDisplaying item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        (item as? SongItem)?.cancelArtworkRequest()
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        let width = max(
            collectionView.enclosingScrollView?.contentView.bounds.width ?? collectionView.bounds.width,
            32
        )
        return NSSize(width: width - 32, height: 80)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        collectionView.collectionViewLayout?.invalidateLayout()
        scheduleMoreCheck()
    }

    func setTracks(_ tracks: [Track], hasMore: Bool = false) {
        let selectedTracks = selectedTracks()
        cancelVisibleArtworkRequests()
        let retainedTracks = tracks.count > Self.maximumDisplayedTrackCount
            ? Array(tracks.prefix(Self.maximumDisplayedTrackCount))
            : tracks
        displayedTracks = retainedTracks
        onPrefetchLyricsFileAvailability?(retainedTracks)
        self.hasMore = hasMore
            && retainedTracks.count == tracks.count
            && retainedTracks.count < Self.maximumDisplayedTrackCount
        collectionView.reloadData()
        restoreSelection(for: selectedTracks)
        scheduleMoreCheck()
    }

    func setPage(_ page: LibraryTrackPage) {
        setTracks(page.tracks, hasMore: page.hasMore)
    }

    func appendPage(_ page: LibraryTrackPage) {
        guard page.offset == displayedTracks.count else { return }
        let remaining = Self.maximumDisplayedTrackCount - displayedTracks.count
        guard remaining > 0 else {
            hasMore = false
            return
        }
        let selectedTracks = selectedTracks()
        cancelVisibleArtworkRequests()
        let appendedTracks = page.tracks.count > remaining
            ? Array(page.tracks.prefix(remaining))
            : page.tracks
        displayedTracks.append(contentsOf: appendedTracks)
        onPrefetchLyricsFileAvailability?(appendedTracks)
        hasMore = page.hasMore
            && appendedTracks.count == page.tracks.count
            && displayedTracks.count < Self.maximumDisplayedTrackCount
        collectionView.reloadData()
        restoreSelection(for: selectedTracks)
        scheduleMoreCheck()
    }

    var selectedTrack: Track? {
        guard let selected = selectedTracks().first else { return nil }
        return displayedTracks.first { $0.hasSameIdentity(as: selected) }
    }

    var tracks: [Track] {
        displayedTracks
    }

}
