import AppKit

@MainActor
enum ArtworkPlaceholder {
    static let image = NSImage(
        systemSymbolName: "music.note",
        accessibilityDescription: "No artwork"
    ) ?? NSImage()
}

final class ArtworkImageView: NSImageView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureArtworkView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureArtworkView()
    }

    func setArtwork(_ artwork: NSImage?) {
        image = artwork ?? ArtworkPlaceholder.image
    }

    private func configureArtworkView() {
        imageScaling = .scaleProportionallyUpOrDown
        contentTintColor = AppTheme.secondaryText
        setArtwork(nil)
    }
}
