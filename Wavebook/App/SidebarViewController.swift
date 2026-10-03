import AppKit
import WavebookCore

private final class SidebarActionTarget: NSObject {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
        super.init()
    }

    @objc private func invoke() { handler() }

    func menuItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(invoke), keyEquivalent: "")
        item.target = self
        item.representedObject = self
        return item
    }
}

private final class SidebarPlaylistButton: NSButton {
    let destination: PlaylistDestination

    init(title: String, destination: PlaylistDestination) {
        self.destination = destination
        super.init(frame: .zero)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class SidebarViewController: NSViewController {
    var onSelect: ((LibraryPage) -> Void)?
    var onSelectPlaylist: ((PlaylistDestination) -> Void)?
    var onRenamePlaylist: ((Int64) -> Void)?
    var onDeletePlaylist: ((Int64) -> Void)?
    var playlists: [Playlist] = [] {
        didSet {
            if isViewLoaded { reloadUserPlaylists() }
        }
    }

    private var buttons: [LibraryPage: NSButton] = [:]
    private var playlistButtons: [SidebarPlaylistButton] = []
    private var playlistStack: NSStackView?
    private var selectedPage: LibraryPage = .songs
    private var selectedPlaylist: PlaylistDestination?

    override func loadView() {
        let root = ThemeBackgroundView()
        root.onThemeChange = { [weak self] in self?.applySelection() }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 56, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let pages = LibraryPage.allCases.filter { $0 != .search && $0 != .playlists }
        for (index, page) in pages.enumerated() {
            let button = NSButton(title: page.rawValue, target: self, action: #selector(pageClicked(_:)))
            button.bezelStyle = .rounded
            button.isBordered = false
            button.tag = index
            buttons[page] = button
            stack.addArrangedSubview(button)
        }

        let playlistStack = NSStackView()
        playlistStack.orientation = .vertical
        playlistStack.alignment = .leading
        playlistStack.spacing = 8
        let section = NSTextField(labelWithString: "PLAYLISTS")
        section.font = .systemFont(ofSize: 11, weight: .bold)
        section.textColor = AppTheme.secondaryText
        playlistStack.addArrangedSubview(section)
        for kind in SystemPlaylistKind.allCases {
            addPlaylistButton(title: kind.displayName, destination: .system(kind), to: playlistStack)
        }
        self.playlistStack = playlistStack
        stack.addArrangedSubview(playlistStack)
        reloadUserPlaylists()

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        scrollView.documentView = documentView
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])
        view = root
        applySelection()
    }

    private func addPlaylistButton(title: String, destination: PlaylistDestination, to stack: NSStackView) {
        let button = SidebarPlaylistButton(title: title, destination: destination)
        button.bezelStyle = .rounded
        button.isBordered = false
        button.target = self
        button.action = #selector(playlistClicked(_:))
        button.contentTintColor = AppTheme.secondaryText
        if case let .user(id) = destination {
            let menu = NSMenu()
            let renameTarget = SidebarActionTarget { [weak self] in self?.onRenamePlaylist?(id) }
            let deleteTarget = SidebarActionTarget { [weak self] in self?.onDeletePlaylist?(id) }
            menu.addItem(renameTarget.menuItem(title: "Rename…"))
            menu.addItem(deleteTarget.menuItem(title: "Delete…"))
            button.menu = menu
        }
        playlistButtons.append(button)
        stack.addArrangedSubview(button)
    }

    private func reloadUserPlaylists() {
        guard let playlistStack else { return }
        playlistButtons
            .filter { if case .user = $0.destination { return true }; return false }
            .forEach {
                playlistStack.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
        playlistButtons.removeAll { if case .user = $0.destination { return true }; return false }
        for playlist in playlists {
            addPlaylistButton(title: playlist.name, destination: .user(playlist.id), to: playlistStack)
        }
        applySelection()
    }

    func setPlaylists(_ playlists: [Playlist]) {
        self.playlists = playlists
    }

    func select(_ page: LibraryPage) {
        selectedPage = page
        selectedPlaylist = nil
        applySelection()
    }

    func selectPlaylist(_ destination: PlaylistDestination) {
        selectedPage = .playlists
        selectedPlaylist = destination
        applySelection()
    }

    @objc private func playlistClicked(_ sender: SidebarPlaylistButton) {
        selectedPage = .playlists
        selectedPlaylist = sender.destination
        applySelection()
        onSelectPlaylist?(sender.destination)
    }

    @objc private func pageClicked(_ sender: NSButton) {
        let pages = LibraryPage.allCases.filter { $0 != .search && $0 != .playlists }
        guard pages.indices.contains(sender.tag) else { return }
        onSelect?(pages[sender.tag])
    }

    private func applySelection() {
        for (page, button) in buttons {
            button.font = .systemFont(ofSize: 15, weight: page == selectedPage ? .semibold : .regular)
            button.contentTintColor = page == selectedPage ? AppTheme.accent : AppTheme.secondaryText
        }
        for button in playlistButtons {
            let isSelected = selectedPage == .playlists && selectedPlaylist == button.destination
            button.font = .systemFont(ofSize: 15, weight: isSelected ? .semibold : .regular)
            button.contentTintColor = isSelected ? AppTheme.accent : AppTheme.secondaryText
        }
    }
}
