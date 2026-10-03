import AppKit
import WavebookCore

final class QueueViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    private static let dragType = NSPasteboard.PasteboardType("com.musicplayercodex.queue-entry-id")

    var onPlay: ((PlaybackQueue.Entry) -> Void)?
    var onRemove: (([UUID]) -> Void)?
    var onMove: ((PlaybackQueue.Entry, Int) -> Bool)?
    var onAlbumSelect: ((AlbumKey) -> Void)?
    var onArtistSelect: ((String) -> Void)?
    var onGenreSelect: ((String) -> Void)?
    var onToggleFavorite: (([Track]) -> Void)?
    var onManageSkipSegments: ((Track) -> Void)?
    var onOpenLyricsInApp: ((Track, URL) -> Void)?
    var onShowLyricsInFinder: ((Track) -> Void)?
    var lyricsFileAvailabilityProvider: ((Track) -> Bool?)?
    var onPrefetchLyricsFileAvailability: (([Track]) -> Void)?
    var lyricsFileAvailabilityObserver: LyricsFileAvailabilityObserver?
    var onRefresh: (() -> Void)?
    private var displayedEntries: [PlaybackQueue.Entry] = []
    private var currentTrackIndex: Int?
    private let collectionView = ActivatingCollectionView()
    private let empty = NSTextField(labelWithString: "Queue is empty")
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let artworkLoader = ArtworkImageLoader.shared

    override func loadView() {
        let root = ThemeBackgroundView()
        let title = NSTextField(labelWithString: "Queue")
        let scrollView = NSScrollView()
        configureTitleAndRemoveButton(title)
        configureCollection(scrollView)
        configureLayout(root: root, title: title, scrollView: scrollView)
        view = root
    }

    private func configureTitleAndRemoveButton(_ title: NSTextField) {
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = AppTheme.primaryText
        title.translatesAutoresizingMaskIntoConstraints = false
        removeButton.bezelStyle = .rounded
        removeButton.contentTintColor = AppTheme.accent
        removeButton.target = self
        removeButton.action = #selector(removeSelectedTracks)
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        empty.textColor = AppTheme.secondaryText
        empty.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureCollection(_ scrollView: NSScrollView) {
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
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [AppTheme.background]
        collectionView.autoresizingMask = [.width]
        collectionView.register(SongItem.self, forItemWithIdentifier: SongItem.identifier)
        collectionView.onActivateSelection = { [weak self] in
            self?.playSelectedTrack()
        }
        collectionView.registerForDraggedTypes([Self.dragType])
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)
        collectionView.onDoubleClick = { [weak self] indexPath in
            guard let self, self.displayedEntries.indices.contains(indexPath.item) else { return }
            self.onPlay?(self.displayedEntries[indexPath.item])
        }
        collectionView.onContextMenu = { [weak self] clicked, selection in
            guard let self, self.displayedEntries.indices.contains(clicked.item) else { return nil }
            let tracks = self.entries(for: selection).map(\.track)
            let track = self.displayedEntries[clicked.item].track
            return makeTrackContextMenu(
                tracks: tracks,
                contextTrack: track,
                actions: TrackContextMenuActions(
                    onAddToQueue: nil,
                    onAddNextToQueue: nil,
                    onDownloadLyrics: nil,
                    onOpenLyricsInApp: self.onOpenLyricsInApp,
                    onShowLyricsInFinder: self.onShowLyricsInFinder,
                    lyricsFileAvailabilityProvider: self.lyricsFileAvailabilityProvider,
                    lyricsFileAvailabilityObserver: self.lyricsFileAvailabilityObserver,
                    onManageSkipSegments: self.onManageSkipSegments,
                    onAlbumSelect: self.onAlbumSelect,
                    onArtistSelect: self.onArtistSelect,
                    onGenreSelect: self.onGenreSelect,
                    onRescanLoudness: nil,
                    onToggleFavorite: self.onToggleFavorite
                )
            )
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
    }

    private func configureLayout(root: NSView, title: NSTextField, scrollView: NSScrollView) {
        root.addSubview(title)
        root.addSubview(removeButton)
        root.addSubview(scrollView)
        root.addSubview(empty)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            removeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            removeButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: root.centerYAnchor)
        ])
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        displayedEntries.count
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
        let entry = displayedEntries[indexPath.item]
        let track = entry.track
        let request = artworkLoader.requestImage(forPath: track.path) { [weak item] image in
            item?.setArtwork(image)
        }
        item.configure(with: track, artwork: request.image)
        item.setArtworkRequest(request)
        item.setFavoriteHandler { [weak self] in self?.onToggleFavorite?([track]) }
        item.configureQueueState(
            isCurrent: indexPath.item == currentTrackIndex,
            isPrevious: currentTrackIndex.map { indexPath.item < $0 } ?? false,
            onPlay: { [weak self] in self?.onPlay?(entry) }
        )
        return item
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

    func collectionView(
        _ collectionView: NSCollectionView,
        pasteboardWriterForItemAt indexPath: IndexPath
    ) -> NSPasteboardWriting? {
        guard displayedEntries.indices.contains(indexPath.item) else { return nil }
        let item = NSPasteboardItem()
        item.setString(
            displayedEntries[indexPath.item].id.uuidString,
            forType: Self.dragType
        )
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        guard draggingInfo.draggingSource as? NSCollectionView === collectionView else { return [] }
        proposedDropOperation.pointee = .before
        return .move
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        guard indexPath.section == 0,
              let idString = draggingInfo.draggingPasteboard.string(forType: Self.dragType),
              let entryID = UUID(uuidString: idString),
              let source = displayedEntries.firstIndex(where: { $0.id == entryID }),
              !displayedEntries.isEmpty else { return false }
        let entry = displayedEntries[source]
        var insertionIndex = min(indexPath.item, displayedEntries.count)
        if source < insertionIndex {
            insertionIndex -= 1
        }
        let destination = min(insertionIndex, displayedEntries.count - 1)
        return onMove?(entry, destination) ?? false
    }

    private func cancelVisibleArtworkRequests() {
        collectionView.visibleItems()
            .compactMap { $0 as? SongItem }
            .forEach { $0.cancelArtworkRequest() }
    }

    func activate() {
        let selection = collectionView.selectionIndexPaths
        collectionView.reloadData()
        collectionView.selectionIndexPaths = Set(selection.filter { displayedEntries.indices.contains($0.item) })
    }

    func deactivate() {
        cancelVisibleArtworkRequests()
    }
    private func entries(for selection: Set<IndexPath>) -> [PlaybackQueue.Entry] {
        selection
            .sorted { $0.item < $1.item }
            .compactMap { indexPath in
                displayedEntries.indices.contains(indexPath.item) ? displayedEntries[indexPath.item] : nil
            }
    }

    private func selectedEntries() -> [PlaybackQueue.Entry] {
        entries(for: collectionView.selectionIndexPaths)
    }

    private func restoreSelection(for selectedEntries: [PlaybackQueue.Entry]) {
        let selectedIDs = Set(selectedEntries.map(\.id))
        collectionView.selectionIndexPaths = Set(displayedEntries.indices.compactMap { index in
            selectedIDs.contains(displayedEntries[index].id) ? IndexPath(item: index, section: 0) : nil
        })
    }

    func setTracks(_ tracks: [PlaybackQueue.Entry], currentIndex: Int?, scrollToCurrent: Bool = false) {
        let selectedEntries = selectedEntries()
        cancelVisibleArtworkRequests()

        let previousCurrentTrackIndex = currentTrackIndex
        displayedEntries = tracks
        currentTrackIndex = currentIndex.flatMap { tracks.indices.contains($0) ? $0 : nil }
        onPrefetchLyricsFileAvailability?(tracks.map(\.track))
        empty.isHidden = !tracks.isEmpty
        collectionView.reloadData()
        restoreSelection(for: selectedEntries)
        if scrollToCurrent || currentTrackIndex != previousCurrentTrackIndex, let currentTrackIndex {
            view.layoutSubtreeIfNeeded()
            collectionView.scrollToItems(
                at: [IndexPath(item: currentTrackIndex, section: 0)],
                scrollPosition: .centeredVertically
            )
        }
    }

    @objc private func removeSelectedTracks() {
        let entryIDs = selectedEntries().map(\.id)
        guard !entryIDs.isEmpty else { return }
        onRemove?(entryIDs)
    }

    private func playSelectedTrack() {
        guard let entry = selectedEntry else { return }
        onPlay?(entry)
    }

    private var selectedEntry: PlaybackQueue.Entry? {
        selectedEntries().first
    }

}
extension QueueViewController: NavigationHost {
    var page: LibraryPage { .queue }
    var selectedTrack: Track? { nil }
    var tracks: [Track] { [] }

    func refresh() {
        onRefresh?()
    }
}
