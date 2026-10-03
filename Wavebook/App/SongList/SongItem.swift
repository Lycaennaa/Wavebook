import AppKit
import WavebookCore

final class SongItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("SongItem")

    private let titleLabel = MarqueeLabel()
    private let artistLabel = MarqueeLabel()
    private let albumLabel = MarqueeLabel()
    private let genreLabel = NSTextField(labelWithString: "")
    private let artworkView = ArtworkImageView()
    private let playButton = NSButton(
        image: NSImage(
            systemSymbolName: "play.fill",
            accessibilityDescription: "Play"
        ) ?? NSImage(),
        target: nil,
        action: nil
    )
    private let favoriteButton = NSButton(
        image: NSImage(systemSymbolName: "star", accessibilityDescription: "Favorite") ?? NSImage(),
        target: nil,
        action: nil
    )
    private var onFavorite: (() -> Void)?
    private var isFavorite = false
    private var standardTrailingConstraint: NSLayoutConstraint?
    private var queueTrailingConstraint: NSLayoutConstraint?
    private var onPlay: (() -> Void)?
    private var isCurrentTrack = false
    private var artworkRequest: ArtworkImageRequest?

    override func loadView() {
        let container = ThemeAwareView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.backgroundColor = AppTheme.cgColor(AppTheme.background, in: container)

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = AppTheme.primaryText

        for label in [artistLabel, albumLabel] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = AppTheme.secondaryText
        }
        genreLabel.font = .systemFont(ofSize: 12)
        genreLabel.textColor = AppTheme.secondaryText
        genreLabel.lineBreakMode = .byTruncatingTail

        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = 6
        artworkView.layer?.backgroundColor = AppTheme.cgColor(AppTheme.raised, in: artworkView)
        artworkView.translatesAutoresizingMaskIntoConstraints = false

        playButton.bezelStyle = .circular
        playButton.isBordered = false
        playButton.contentTintColor = AppTheme.accent
        playButton.target = self
        playButton.action = #selector(playClicked)
        playButton.isHidden = true
        playButton.translatesAutoresizingMaskIntoConstraints = false
        favoriteButton.bezelStyle = .circular
        favoriteButton.isBordered = false
        favoriteButton.contentTintColor = AppTheme.accent
        favoriteButton.target = self
        favoriteButton.action = #selector(favoriteClicked)
        favoriteButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, artistLabel, albumLabel, genreLabel])
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(artworkView)
        container.addSubview(stack)
        container.addSubview(playButton)
        container.addSubview(favoriteButton)

        configureLayout(in: container, stack: stack)

        container.onThemeChange = { [weak self] in self?.updateBackground() }
        view = container
        updateBackground()
    }
    private func configureLayout(in container: ThemeAwareView, stack: NSStackView) {
        let standardTrailingConstraint = stack.trailingAnchor.constraint(
            equalTo: favoriteButton.leadingAnchor,
            constant: -10
        )
        let queueTrailingConstraint = stack.trailingAnchor.constraint(
            equalTo: playButton.leadingAnchor,
            constant: -10
        )
        self.standardTrailingConstraint = standardTrailingConstraint
        self.queueTrailingConstraint = queueTrailingConstraint

        NSLayoutConstraint.activate([
            artworkView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            artworkView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            artworkView.widthAnchor.constraint(equalToConstant: 40),
            artworkView.heightAnchor.constraint(equalToConstant: 40),
            stack.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 10),
            standardTrailingConstraint,
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            playButton.trailingAnchor.constraint(equalTo: favoriteButton.leadingAnchor, constant: -8),
            playButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 28),
            playButton.heightAnchor.constraint(equalToConstant: 28),
            favoriteButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            favoriteButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            favoriteButton.widthAnchor.constraint(equalToConstant: 28),
            favoriteButton.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    override var isSelected: Bool {
        didSet {
            updateBackground()
        }
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

    func configure(with track: Track, artwork: NSImage?) {
        cancelArtworkRequest()
        titleLabel.stringValue = track.title
        artistLabel.stringValue = track.artistDisplay.replacingOccurrences(of: ";", with: ",")
        albumLabel.stringValue = track.albumTitle
        let genre = track.genreDisplay.replacingOccurrences(of: ";", with: ",")
        genreLabel.stringValue = [genre, track.format.uppercased(), track.hasLyrics ? "LYRICS" : ""]
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
        artworkView.setArtwork(artwork)
        configureQueueState(isCurrent: false, isPrevious: false, onPlay: nil)
        isFavorite = track.isFavorite
        updateFavoriteButton()
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
    func setFavoriteHandler(_ handler: (() -> Void)?) { onFavorite = handler }

    private func updateFavoriteButton() {
        favoriteButton.image = NSImage(
            systemSymbolName: isFavorite ? "star.fill" : "star",
            accessibilityDescription: isFavorite ? "Unfavorite" : "Favorite"
        )
        favoriteButton.toolTip = isFavorite ? "Unfavorite" : "Favorite"
    }

    @objc private func favoriteClicked() { onFavorite?() }

    func configureQueueState(isCurrent: Bool, isPrevious: Bool, onPlay: (() -> Void)?) {
        self.onPlay = onPlay
        isCurrentTrack = isCurrent
        playButton.isHidden = onPlay == nil
        playButton.toolTip = onPlay == nil ? nil : "Play"
        view.alphaValue = isPrevious ? 0.5 : 1

        if onPlay == nil {
            queueTrailingConstraint?.isActive = false
            standardTrailingConstraint?.isActive = true
        } else {
            standardTrailingConstraint?.isActive = false
            queueTrailingConstraint?.isActive = true
        }
        updateBackground()
    }

    @objc private func playClicked() {
        onPlay?()
    }

    private func updateBackground() {
        view.layer?.backgroundColor = AppTheme.cgColor(
            isCurrentTrack || isSelected ? AppTheme.selection : AppTheme.background,
            in: view
        )
        view.layer?.borderColor = isCurrentTrack ? AppTheme.cgColor(AppTheme.accent, in: view) : nil
        view.layer?.borderWidth = isCurrentTrack ? 1.5 : 0
        artworkView.layer?.backgroundColor = AppTheme.cgColor(AppTheme.raised, in: artworkView)
    }
}
