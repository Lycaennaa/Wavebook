import AppKit
import WavebookCore
private final class PlaylistScrollView: NSScrollView {
    var onBoundsChange: (() -> Void)?

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        onBoundsChange?()
    }
}

final class PlaylistItemListViewController:
    NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    private static let dragType = NSPasteboard.PasteboardType("com.wavebook.playlist-item-id")
    private static let maximumDisplayedItemCount = PlaybackQueue.maximumEntryCount

    var onPlay: ((PlaylistItem) -> Void)?
    var onToggleFavorite: (([Track]) -> Void)?
    var onRemove: (([Int64]) -> Void)?
    var onReorder: ((Int64, Int) -> Void)?
    var onRequestMore: (() -> Void)?

    private var displayedItems: [PlaylistItem] = []
    private var hasMore = false
    private var canReorder = false
    private let collectionView = ActivatingCollectionView()
    private let artworkLoader = ArtworkImageLoader.shared
    private var isActive = false
    private var moreCheckGeneration = UUID()
    override func loadView() {
        let scrollView = PlaylistScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.backgroundColor = AppTheme.background
        scrollView.drawsBackground = true
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
        collectionView.register(PlaylistUnavailableItem.self, forItemWithIdentifier: PlaylistUnavailableItem.identifier)
        collectionView.registerForDraggedTypes([Self.dragType])
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)
        collectionView.onActivateSelection = { [weak self] in self?.playSelectedTrack() }
        collectionView.onDoubleClick = { [weak self] indexPath in
            guard let self, self.displayedItems.indices.contains(indexPath.item) else { return }
            let item = self.displayedItems[indexPath.item]
            guard item.track != nil else { return }
            self.onPlay?(item)
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
        scrollView.onBoundsChange = { [weak self] in self?.requestMoreIfNeeded() }
        view = scrollView
    }

    private func requestMoreIfNeeded() {
        guard isActive, hasMore, let scrollView = collectionView.enclosingScrollView else { return }
        let viewportHeight = scrollView.contentView.bounds.height
        let threshold = max(collectionView.bounds.height - viewportHeight - 320, 0)
        guard scrollView.contentView.bounds.maxY >= threshold else { return }
        onRequestMore?()
    }

    private func scheduleMoreCheck() {
        guard isActive else { return }
        let generation = moreCheckGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive, self.moreCheckGeneration == generation else { return }
            self.requestMoreIfNeeded()
        }
    }

    func setItems(_ items: [PlaylistItem], hasMore: Bool, canReorder: Bool) {
        let selection = currentSelectedItemIDs()
        cancelVisibleArtworkRequests()
        let retainedItems = items.count > Self.maximumDisplayedItemCount
            ? Array(items.prefix(Self.maximumDisplayedItemCount))
            : items
        displayedItems = retainedItems
        self.hasMore = hasMore
            && retainedItems.count == items.count
            && retainedItems.count < Self.maximumDisplayedItemCount
        self.canReorder = canReorder
        collectionView.reloadData()
        restoreSelection(for: selection)
        if isActive { scheduleMoreCheck() }
    }

    func setCanReorder(_ canReorder: Bool) {
        self.canReorder = canReorder
    }

    func clear() {
        setItems([], hasMore: false, canReorder: false)
    }

    func activate() {
        isActive = true
        moreCheckGeneration = UUID()
        let selection = collectionView.selectionIndexPaths
        collectionView.reloadData()
        collectionView.selectionIndexPaths = Set(selection.filter { displayedItems.indices.contains($0.item) })
        scheduleMoreCheck()
    }

    func deactivate() {
        isActive = false
        moreCheckGeneration = UUID()
        cancelVisibleArtworkRequests()
        displayedItems.removeAll(keepingCapacity: false)
        hasMore = false
        canReorder = false
        collectionView.selectionIndexPaths = Set<IndexPath>()
    }

    private var selectedPlayableItem: PlaylistItem? {
        collectionView.selectionIndexPaths.sorted { $0.item < $1.item }.compactMap { indexPath in
            displayedItems.indices.contains(indexPath.item) ? displayedItems[indexPath.item] : nil
        }.first { $0.track != nil }
    }

    var selectedTrack: Track? { selectedPlayableItem?.track }
    var items: [PlaylistItem] { displayedItems }

    var tracks: [Track] { displayedItems.compactMap(\.track) }

    var selectedItemIDs: [Int64] { currentSelectedItemIDs() }

    private func currentSelectedItemIDs() -> [Int64] {
        collectionView.selectionIndexPaths.sorted { $0.item < $1.item }.compactMap { indexPath in
            displayedItems.indices.contains(indexPath.item) ? displayedItems[indexPath.item].id : nil
        }
    }

    private func restoreSelection(for ids: [Int64]) {
        let ids = Set(ids)
        collectionView.selectionIndexPaths = Set(displayedItems.indices.compactMap { index in
            ids.contains(displayedItems[index].id) ? IndexPath(item: index, section: 0) : nil
        })
    }

    private func playSelectedTrack() {
        guard let item = selectedPlayableItem else { return }
        onPlay?(item)
    }

    private func cancelVisibleArtworkRequests() {
        collectionView.visibleItems().forEach { ($0 as? SongItem)?.cancelArtworkRequest() }
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        displayedItems.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        guard displayedItems.indices.contains(indexPath.item) else { return NSCollectionViewItem() }
        let playlistItem = displayedItems[indexPath.item]
        guard let track = playlistItem.track else {
            guard let item = collectionView.makeItem(
                withIdentifier: PlaylistUnavailableItem.identifier,
                for: indexPath
            ) as? PlaylistUnavailableItem else { return NSCollectionViewItem() }
            item.configure(with: playlistItem)
            return item
        }
        guard let item = collectionView.makeItem(
            withIdentifier: SongItem.identifier,
            for: indexPath
        ) as? SongItem else { return NSCollectionViewItem() }
        item.cancelArtworkRequest()
        let request = artworkLoader.requestImage(forPath: track.path) { [weak item] image in item?.setArtwork(image) }
        item.configure(with: track, artwork: request.image)
        item.setFavoriteHandler { [weak self] in self?.onToggleFavorite?([track]) }
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

    func collectionView(
        _ collectionView: NSCollectionView,
        pasteboardWriterForItemAt indexPath: IndexPath
    ) -> NSPasteboardWriting? {
        guard canReorder, displayedItems.indices.contains(indexPath.item) else { return nil }
        let pasteboard = NSPasteboardItem()
        pasteboard.setString(String(displayedItems[indexPath.item].id), forType: Self.dragType)
        return pasteboard
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        guard canReorder, draggingInfo.draggingSource as? NSCollectionView === collectionView else { return [] }
        proposedDropOperation.pointee = .before
        return .move
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        guard canReorder,
              indexPath.section == 0,
              let idString = draggingInfo.draggingPasteboard.string(forType: Self.dragType),
              let itemID = Int64(idString),
              let source = displayedItems.firstIndex(where: { $0.id == itemID }),
              !displayedItems.isEmpty else { return false }
        var insertionIndex = min(indexPath.item, displayedItems.count)
        if source < insertionIndex { insertionIndex -= 1 }
        onReorder?(itemID, min(insertionIndex, displayedItems.count - 1))
        return true
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !indexPaths.isEmpty else { return }
    }

}
