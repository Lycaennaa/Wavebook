import AppKit
import WavebookCore

final class RootSplitViewController: NSViewController {
    private let sidebarController = SidebarViewController()
    private let mainController: MainViewController

    init(searchField: NSSearchField) {
        mainController = MainViewController(searchField: searchField)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
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

        view = RootSplitView(sidebar: sidebarController.view, main: mainController.view)
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
