import AppKit
import WavebookCore

final class BrowseListViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    struct Entry: Equatable {
        var title: String
        var subtitle: String
        var artworkTrackPath: String?
    }

    var onSelect: ((Int) -> Void)?
    var onRequestMore: (() -> Void)?
    private var entries: [Entry] = []
    private let collectionView = ActivatingCollectionView()
    private let empty = NSTextField(labelWithString: "Nothing here")
    private let artworkLoader = ArtworkImageLoader.shared
    nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
    }

    private func requestMoreIfNeeded() {
        guard let scrollView = collectionView.enclosingScrollView else { return }
        let viewportHeight = scrollView.contentView.bounds.height
        let threshold = max(collectionView.bounds.height - viewportHeight - 320, 0)
        guard scrollView.contentView.bounds.maxY >= threshold else { return }
        onRequestMore?()
    }

    private func scheduleMoreCheck() {
        DispatchQueue.main.async { [weak self] in
            self?.requestMoreIfNeeded()
        }
    }

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
        layout.sectionInset = NSEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.backgroundColors = [AppTheme.background]
        collectionView.register(BrowseItem.self, forItemWithIdentifier: BrowseItem.identifier)
        collectionView.onWindowChange = { [weak self] window in
            guard let self else { return }
            if window == nil {
                self.cancelVisibleArtworkRequests()
            } else {
                self.collectionView.reloadData()
            }
        }

        empty.textColor = AppTheme.secondaryText
        empty.translatesAutoresizingMaskIntoConstraints = false

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
        root.addSubview(scrollView)
        root.addSubview(empty)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: root.centerYAnchor)
        ])

        view = root
    }

    func setEntries(_ entries: [Entry], selectedIndex: Int?, revealSelection: Bool = false) {
        cancelVisibleArtworkRequests()

        let previousSelection = collectionView.selectionIndexPaths.first?.item
        let previousOrigin = collectionView.enclosingScrollView?.contentView.bounds.origin
        self.entries = entries
        empty.isHidden = !entries.isEmpty
        collectionView.reloadData()
        if let selectedIndex, entries.indices.contains(selectedIndex) {
            let indexPath = IndexPath(item: selectedIndex, section: 0)
            collectionView.selectionIndexPaths = [indexPath]
            if revealSelection || (previousSelection != selectedIndex && previousSelection != nil) {
                DispatchQueue.main.async { [weak self] in
                    self?.collectionView.scrollToItems(at: [indexPath], scrollPosition: .centeredVertically)
                }
            } else if let previousOrigin {
                DispatchQueue.main.async { [weak self] in
                    self?.restoreScrollPosition(previousOrigin)
                }
            }
        } else {
            collectionView.selectionIndexPaths = []
            if let previousOrigin {
                DispatchQueue.main.async { [weak self] in
                    self?.restoreScrollPosition(previousOrigin)
                }
            }
        }
        scheduleMoreCheck()
    }

    private func cancelVisibleArtworkRequests() {
        collectionView.visibleItems()
            .compactMap { $0 as? BrowseItem }
            .forEach { $0.cancelArtworkRequest() }
    }

    func activate() {
        let selection = collectionView.selectionIndexPaths
        collectionView.reloadData()
        collectionView.selectionIndexPaths = Set(selection.filter { entries.indices.contains($0.item) })
        scheduleMoreCheck()
    }

    func deactivate() {
        cancelVisibleArtworkRequests()
    }

    private func restoreScrollPosition(_ origin: NSPoint) {
        guard let scrollView = collectionView.enclosingScrollView else { return }
        let documentHeight = collectionView.bounds.height
        let viewportHeight = scrollView.contentView.bounds.height
        let maxY = max(documentHeight - viewportHeight, 0)
        scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: min(max(origin.y, 0), maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        guard let item = collectionView.makeItem(
            withIdentifier: BrowseItem.identifier,
            for: indexPath
        ) as? BrowseItem else {
            return NSCollectionViewItem()
        }
        item.cancelArtworkRequest()
        let entry = entries[indexPath.item]
        let request = entry.artworkTrackPath.map { path in
            artworkLoader.requestImage(forPath: path) { [weak item] image in
                item?.setArtwork(image)
            }
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
        NSSize(width: max(collectionView.bounds.width - 20, 120), height: 56)
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let index = indexPaths.first?.item, entries.indices.contains(index) else { return }
        onSelect?(index)
    }
}

final class BrowseItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("BrowseItem")

    private let artworkView = ArtworkImageView()
    private let titleLabel = MarqueeLabel()
    private let subtitleLabel = MarqueeLabel()
    private var artworkLeadingConstraint: NSLayoutConstraint?
    private var textLeadingConstraint: NSLayoutConstraint?
    private var artworkRequest: ArtworkImageRequest?

    override func loadView() {
        let container = ThemeAwareView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.backgroundColor = AppTheme.cgColor(AppTheme.background, in: container)

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = AppTheme.primaryText

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = AppTheme.secondaryText

        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = 6
        artworkView.layer?.backgroundColor = AppTheme.cgColor(AppTheme.raised, in: artworkView)
        artworkView.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(artworkView)
        container.addSubview(stack)
        artworkLeadingConstraint = stack.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 10)
        textLeadingConstraint = stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12)

        NSLayoutConstraint.activate([
            artworkView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            artworkView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            artworkView.widthAnchor.constraint(equalToConstant: 40),
            artworkView.heightAnchor.constraint(equalToConstant: 40),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        artworkLeadingConstraint?.isActive = true

        container.onThemeChange = { [weak self] in self?.updateBackground() }
        view = container
        updateBackground()
    }

    override var isSelected: Bool {
        didSet {
            updateBackground()
        }
    }
    private func updateBackground() {
        view.layer?.backgroundColor = AppTheme.cgColor(isSelected ? AppTheme.selection : AppTheme.background, in: view)
        artworkView.layer?.backgroundColor = AppTheme.cgColor(AppTheme.raised, in: artworkView)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        cancelArtworkRequest()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelArtworkRequest()
        artworkView.setArtwork(nil)
    }

    func configure(with entry: BrowseListViewController.Entry, artwork: NSImage?) {
        cancelArtworkRequest()
        titleLabel.stringValue = entry.title
        subtitleLabel.stringValue = entry.subtitle
        titleLabel.resetScroll()
        subtitleLabel.resetScroll()
        artworkView.setArtwork(artwork)
        let hasArtwork = entry.artworkTrackPath != nil
        artworkView.isHidden = !hasArtwork
        artworkLeadingConstraint?.isActive = hasArtwork
        textLeadingConstraint?.isActive = !hasArtwork
    }
    func setArtwork(_ artwork: NSImage?) {
        artworkView.setArtwork(artwork)
    }

    func setArtworkRequest(_ request: ArtworkImageRequest?) {
        cancelArtworkRequest()
        artworkRequest = request
    }

    func cancelArtworkRequest() {
        artworkRequest?.cancel()
        artworkRequest = nil
    }
}

final class MarqueeLabel: NSView {
    var stringValue = "" { didSet { contentDidChange() } }
    var font = NSFont.systemFont(ofSize: 13) { didSet { contentDidChange() } }
    var textColor = AppTheme.primaryText { didSet { renderingCache = nil; needsDisplay = true } }
    var onPress: (() -> Void)? {
        didSet {
            if onPress != nil {
                setAccessibilityRole(.button)
                focusRingType = .exterior
            }
        }
    }

    private struct RenderingCache {
        let standardAttributes: [NSAttributedString.Key: Any]
        let truncatingAttributes: [NSAttributedString.Key: Any]
        let textWidth: CGFloat
    }

    private var renderingCache: RenderingCache?

    private var offset: CGFloat = 0
    private var isHovered = false
    nonisolated(unsafe) private var timer: Timer?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: ceil(font.ascender - font.descender + font.leading))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        if isHovered { startScrollIfNeeded() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let cache = currentRenderingCache()
        if offset == 0 {
            (stringValue as NSString).draw(in: bounds, withAttributes: cache.truncatingAttributes)
            return
        }
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: bounds).setClip()
        (stringValue as NSString).draw(at: NSPoint(x: -offset, y: 0), withAttributes: cache.standardAttributes)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
                owner: self
            )
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            isHovered = false
            resetScroll()
        }
    }

    deinit {
        timer?.invalidate()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        startScrollIfNeeded()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        resetScroll()
    }

    override var acceptsFirstResponder: Bool { onPress != nil }

    override func mouseDown(with event: NSEvent) {
        guard let onPress else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        onPress()
    }

    override func keyDown(with event: NSEvent) {
        guard onPress != nil, event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 76 else {
            super.keyDown(with: event)
            return
        }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }

    func resetScroll() {
        timer?.invalidate()
        timer = nil
        offset = 0
        needsDisplay = true
    }
    func prepareForHiding() {
        isHovered = false
        resetScroll()
    }

    private func contentDidChange() {
        renderingCache = nil
        resetScroll()
        invalidateIntrinsicContentSize()
        setAccessibilityValue(stringValue)
        if isHovered { startScrollIfNeeded() }
    }

    private func startScrollIfNeeded() {
        let overflow = textWidth - bounds.width
        guard overflow > 1 else {
            resetScroll()
            return
        }
        if offset > overflow {
            offset = overflow
            needsDisplay = true
        }
        guard offset < overflow, timer == nil else { return }
        let scrollTimer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let overflow = self.textWidth - self.bounds.width
                guard overflow > 1 else {
                    self.resetScroll()
                    return
                }
                self.offset = min(self.offset + 0.8, overflow)
                if self.offset >= overflow {
                    self.timer?.invalidate()
                    self.timer = nil
                }
                self.needsDisplay = true
            }
        }
        timer = scrollTimer
        RunLoop.main.add(scrollTimer, forMode: .common)
    }

    private var textWidth: CGFloat { currentRenderingCache().textWidth }

    private func currentRenderingCache() -> RenderingCache {
        if let renderingCache { return renderingCache }
        let standardAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var truncatingAttributes = standardAttributes
        truncatingAttributes[.paragraphStyle] = paragraph
        let cache = RenderingCache(
            standardAttributes: standardAttributes,
            truncatingAttributes: truncatingAttributes,
            textWidth: (stringValue as NSString).size(withAttributes: [.font: font]).width
        )
        renderingCache = cache
        return cache
    }
}
