import AppKit
import WavebookCore

final class PlaylistUnavailableItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PlaylistUnavailableItem")

    private let titleLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "Unavailable")

    override func loadView() {
        let container = ThemeAwareView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = AppTheme.primaryText
        artistLabel.font = .systemFont(ofSize: 12)
        artistLabel.textColor = AppTheme.secondaryText
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .systemOrange
        let metadata = NSStackView(views: [titleLabel, artistLabel, statusLabel])
        metadata.orientation = .vertical
        metadata.alignment = .leading
        metadata.spacing = 2
        metadata.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(metadata)
        NSLayoutConstraint.activate([
            metadata.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            metadata.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            metadata.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        container.onThemeChange = { [weak self] in self?.updateBackground() }
        view = container
        updateBackground()
    }

    override var isSelected: Bool {
        didSet { updateBackground() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.stringValue = ""
        artistLabel.stringValue = ""
    }

    func configure(with item: PlaylistItem) {
        titleLabel.stringValue = item.displayTitle
        artistLabel.stringValue = item.displayArtist.replacingOccurrences(of: ";", with: ",")
        view.setAccessibilityLabel("Unavailable: \(item.displayTitle)")
        updateBackground()
    }

    private func updateBackground() {
        view.layer?.backgroundColor = AppTheme.cgColor(
            isSelected ? AppTheme.selection : AppTheme.background,
            in: view
        )
    }
}
