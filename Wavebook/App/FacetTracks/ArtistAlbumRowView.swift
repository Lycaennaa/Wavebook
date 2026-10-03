import AppKit
import WavebookCore

final class ArtistAlbumRowView: ThemeAwareControl {
    var onPress: (() -> Void)?

    private let artworkView = ArtworkImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var artworkRequest: ArtworkImageRequest?

    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = AppTheme.cgColor(AppTheme.background, in: self)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Open album")

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

        addSubview(artworkView)
        addSubview(labels)
        NSLayoutConstraint.activate([
            artworkView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            artworkView.centerYAnchor.constraint(equalTo: centerYAnchor),
            artworkView.widthAnchor.constraint(equalToConstant: 40),
            artworkView.heightAnchor.constraint(equalToConstant: 40),
            labels.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        themeDidChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    override func themeDidChange() {
        super.themeDidChange()
        layer?.backgroundColor = AppTheme.cgColor(isHovered ? AppTheme.selection : AppTheme.background, in: self)
        artworkView.layer?.backgroundColor = AppTheme.cgColor(AppTheme.raised, in: artworkView)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cancelArtworkRequest()
        }
    }

    func configure(with album: LibraryArtistAlbumSummary, artwork: NSImage?) {
        cancelArtworkRequest()
        titleLabel.stringValue = album.key.title.isEmpty ? "Unknown Album" : album.key.title
        let owner = album.key.owner.isEmpty ? "Unknown Artist" : album.key.owner
        subtitleLabel.stringValue = "\(owner) • \(album.trackCount) song\(album.trackCount == 1 ? "" : "s")"
        artworkView.setArtwork(artwork)
        toolTip = titleLabel.stringValue
        setAccessibilityLabel(titleLabel.stringValue)
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

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        themeDidChange()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        themeDidChange()
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        window?.makeFirstResponder(self)
        onPress?()
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 76 {
            onPress?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp],
                owner: self
            )
        )
    }
}
