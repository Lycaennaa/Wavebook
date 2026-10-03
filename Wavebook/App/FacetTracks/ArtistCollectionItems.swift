import AppKit
import WavebookCore

final class ArtistHeaderItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ArtistHeaderItem")
    private let label = NSTextField(labelWithString: "")

    override func loadView() {
        let container = NSView()
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = AppTheme.primaryText
        label.alignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4)
        ])
        view = container
    }

    func configure(_ text: String) { label.stringValue = text }
}

final class ArtistTextItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ArtistTextItem")
    private let label = NSTextField(labelWithString: "")

    override func loadView() {
        let container = NSView()
        label.font = .systemFont(ofSize: 12)
        label.textColor = AppTheme.secondaryText
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.alignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        view = container
    }

    func configure(_ text: String) { label.stringValue = text }
}

final class ArtistNamesItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ArtistNamesItem")
    var onArtistSelect: ((String) -> Void)?

    private let stack = NSStackView()
    private var artistsByButton: [NSButton: String] = [:]
    private var artists: [String] = []
    private var laidOutWidth: CGFloat = 0

    override func loadView() {
        let container = NSView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 5)
        ])
        view = container
    }

    func configure(_ artists: [String]) {
        self.artists = artists
        rebuildButtons()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = view.bounds.width
        guard abs(width - laidOutWidth) > 1 else { return }
        rebuildButtons()
    }

    static func rowCount(for artists: [String], width: CGFloat) -> Int {
        guard !artists.isEmpty else { return 0 }
        let availableWidth = max(width, 32)
        var rowCount = 1
        var rowWidth: CGFloat = 0
        for artist in artists {
            let buttonWidth = badgeWidth(for: artist)
            let nextWidth = rowWidth == 0 ? buttonWidth : rowWidth + 8 + buttonWidth
            if rowWidth > 0, nextWidth > availableWidth {
                rowCount += 1
                rowWidth = buttonWidth
            } else {
                rowWidth = nextWidth
            }
        }
        return rowCount
    }

    private func rebuildButtons() {
        laidOutWidth = view.bounds.width
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        artistsByButton.removeAll()
        let availableWidth = max(view.bounds.width, 32)
        var row = makeRow()
        stack.addArrangedSubview(row)
        var rowWidth: CGFloat = 0
        for artist in artists {
            let buttonWidth = Self.badgeWidth(for: artist)
            let nextWidth = rowWidth == 0 ? buttonWidth : rowWidth + 8 + buttonWidth
            if rowWidth > 0, nextWidth > availableWidth {
                row = makeRow()
                stack.addArrangedSubview(row)
                rowWidth = buttonWidth
            } else {
                rowWidth = nextWidth
            }
            let button = NSButton(
                title: artist.isEmpty ? "Unknown Artist" : artist,
                target: self,
                action: #selector(artistPressed(_:))
            )
            button.bezelStyle = .rounded
            button.contentTintColor = AppTheme.accent
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            artistsByButton[button] = artist
            row.addArrangedSubview(button)
        }
    }

    private static func badgeWidth(for artist: String) -> CGFloat {
        let title = artist.isEmpty ? "Unknown Artist" : artist
        return ceil(
            (title as NSString).size(
                withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
            ).width
        ) + 32
    }

    private func makeRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    @objc private func artistPressed(_ sender: NSButton) {
        onArtistSelect?(artistsByButton[sender] ?? sender.title)
    }
}

final class ArtistAlbumItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ArtistAlbumItem")

    private let artworkView = ArtworkImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var artworkRequest: ArtworkImageRequest?

    override func loadView() {
        let container = ThemeAwareView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.backgroundColor = AppTheme.cgColor(AppTheme.background, in: container)

        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = 6
        artworkView.layer?.backgroundColor = AppTheme.cgColor(AppTheme.raised, in: artworkView)
        artworkView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = AppTheme.primaryText
        titleLabel.lineBreakMode = .byTruncatingTail

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = AppTheme.secondaryText
        subtitleLabel.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [titleLabel, subtitleLabel])
        labels.orientation = .vertical
        labels.spacing = 2
        labels.alignment = .leading
        labels.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(artworkView)
        container.addSubview(labels)
        NSLayoutConstraint.activate([
            artworkView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            artworkView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            artworkView.widthAnchor.constraint(equalToConstant: 40),
            artworkView.heightAnchor.constraint(equalToConstant: 40),
            labels.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            labels.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
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

    func configure(with album: LibraryArtistAlbumSummary, artwork: NSImage?) {
        cancelArtworkRequest()
        titleLabel.stringValue = album.key.title.isEmpty ? "Unknown Album" : album.key.title
        let owner = album.key.owner.isEmpty ? "Unknown Artist" : album.key.owner
        subtitleLabel.stringValue = "\(owner) • \(album.trackCount) song\(album.trackCount == 1 ? "" : "s")"
        artworkView.setArtwork(artwork)
        view.toolTip = titleLabel.stringValue
        view.setAccessibilityLabel(titleLabel.stringValue)
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
