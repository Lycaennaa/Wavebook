import AppKit
import WavebookCore

final class RootSplitViewController: NSViewController {
    private let sidebarController = SidebarViewController()
    private let mainController: MainViewController
    private var mainMinimumWidthConstraint: NSLayoutConstraint?

    init(searchField: NSSearchField) {
        mainController = MainViewController(searchField: searchField)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = ThemeBackgroundView()

        sidebarController.onSelectPlaylist = { [weak self] destination in
            guard let self else { return }
            self.mainController.clearSearch()
            self.sidebarController.selectPlaylist(destination)
            self.mainController.navigation.show(destination: .playlist(destination), recordHistory: true)
        }
        mainController.onPlaylistCatalogChanged = { [weak self] playlists in
            self?.sidebarController.setPlaylists(playlists)
        }
        sidebarController.onRenamePlaylist = { [weak self] id in
            self?.mainController.beginRenamePlaylist(id: id)
        }
        sidebarController.onDeletePlaylist = { [weak self] id in
            self?.mainController.beginDeletePlaylist(id: id)
        }
        sidebarController.onSelect = { [weak self] page in
            self?.mainController.showPage(page)
            if page != .settings {
                self?.sidebarController.select(page)
            }
        }
        mainController.onPageChanged = { [weak self] page in
            guard let self, page != .search, page != .settings else { return }
            if page == .playlists,
               case let .playlist(destination) = self.mainController.navigation.currentDestination {
                self.sidebarController.selectPlaylist(destination)
            } else {
                self.sidebarController.select(page)
            }
        }

        addChild(sidebarController)
        addChild(mainController)

        let sidebar = sidebarController.view
        let main = mainController.view
        root.clipsToBounds = true
        sidebar.clipsToBounds = true
        main.clipsToBounds = true
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        main.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(main)
        root.addSubview(sidebar)

        let minimumWidthConstraint = main.widthAnchor.constraint(greaterThanOrEqualToConstant: 980)
        mainMinimumWidthConstraint = minimumWidthConstraint

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 200),
            main.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            minimumWidthConstraint,
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            main.topAnchor.constraint(equalTo: root.topAnchor),
            main.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
    }

    func beginLiveResize() {
        mainMinimumWidthConstraint?.isActive = false
    }

    func endLiveResize() {
        guard let mainMinimumWidthConstraint else { return }
        mainMinimumWidthConstraint.constant = max(0, view.bounds.width - 200)
        mainMinimumWidthConstraint.isActive = true
    }

    func handleMediaKey(_ command: MediaKeyCommand) -> Bool {
        mainController.handleMediaKey(command)
    }

    func addRoot() {
        mainController.addRoot()
    }

    func showSettings() {
        mainController.showSettings()
    }

    func prepareForTermination(completion: @escaping @MainActor (Bool) -> Void) {
        mainController.finalizeForTermination(completion: completion)
    }

}
