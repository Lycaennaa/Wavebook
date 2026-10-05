import AppKit
import WavebookCore

enum PlaylistDestination: Equatable, Sendable {
    case system(SystemPlaylistKind)
    case user(Int64)
}

enum NavigationDestination: Equatable {
    case catalog(CatalogRoute)
    case playlist(PlaylistDestination)
    case queue
    case statistics
    case settings

    init(page: LibraryPage) {
        switch page {
        case .search: self = .catalog(.search)
        case .songs: self = .catalog(.songs)
        case .artists: self = .catalog(.artists(selectedArtist: nil))
        case .albums: self = .catalog(.albums(selectedAlbum: nil))
        case .genres: self = .catalog(.genres(selectedGenre: nil))
        case .statistics: self = .statistics
        case .playlists: self = .playlist(.system(.recentlyAdded))
        case .queue: self = .queue
        case .settings: self = .settings
        }
    }

    var page: LibraryPage {
        switch self {
        case .catalog(.search): return .search
        case .catalog(.songs): return .songs
        case .catalog(.artists): return .artists
        case .catalog(.albums): return .albums
        case .catalog(.genres): return .genres
        case .playlist: return .playlists
        case .queue: return .queue
        case .statistics: return .statistics
        case .settings: return .settings
        }
    }
}

@MainActor
protocol PlaylistNavigationHost: NavigationHost {
    var playlistDestination: PlaylistDestination { get }
    func select(destination: PlaylistDestination)
    func setQuery(_ query: String)
    func updateQuery(_ query: String)
    func cancelLoading()
}

@MainActor
final class AppNavigationCoordinator {
    private let contentHost: NSView
    private let backButton: NSButton
    private let forwardButton: NSButton
    private let pageTitle: NSTextField
    private let databaseProvider: () -> LibraryDatabase?
    private let catalogPageLoadCoordinator = CatalogPageLoadCoordinator()
    private let shuffleCoordinator: CatalogShuffleCoordinator
    private let hosts: [LibraryPage: any NavigationHost]

    private static let maximumHistoryCount = 100
    private var destination = NavigationDestination(page: .songs)
    private var backStack: [NavigationDestination] = []
    private var forwardStack: [NavigationDestination] = []
    private(set) var query = ""
    private var searchReturnDestination: NavigationDestination?

    var onPageChanged: ((LibraryPage) -> Void)?
    var onSettingsRequested: (() -> Void)?
    var onError: ((Error, String, OperationalErrorKind) -> Void)?
    var onClearOperationalErrors: ((OperationalErrorKind) -> Void)?
    var onPageWorkCancelled: (() -> Void)?

    init(
        contentHost: NSView,
        backButton: NSButton,
        forwardButton: NSButton,
        pageTitle: NSTextField,
        databaseProvider: @escaping () -> LibraryDatabase?,
        navigationHosts: [any NavigationHost]
    ) {
        self.contentHost = contentHost
        self.backButton = backButton
        self.forwardButton = forwardButton
        self.pageTitle = pageTitle
        self.databaseProvider = databaseProvider
        shuffleCoordinator = CatalogShuffleCoordinator(databaseProvider: databaseProvider)

        var hosts: [LibraryPage: any NavigationHost] = [:]
        for host in navigationHosts { hosts[host.page] = host }
        self.hosts = hosts
    }

    var currentPage: LibraryPage { destination.page }

    var currentDestination: NavigationDestination {
        if let host = playlistHost, currentPage == .playlists {
            return .playlist(host.playlistDestination)
        }
        guard let host = catalogHost(for: currentPage) else { return destination }
        return .catalog(host.route)
    }

    var currentCatalogPageContext: CatalogPageContext? {
        guard let host = catalogHost(for: currentPage) else { return nil }
        return catalogPageContext(for: host)
    }

    private func catalogPageContext(for host: any CatalogNavigationHost) -> CatalogPageContext {
        CatalogPageContext(route: host.route, query: query)
    }

    private var playlistHost: (any PlaylistNavigationHost)? {
        hosts[.playlists] as? any PlaylistNavigationHost
    }

    var selectedTrack: Track? { hosts[currentPage]?.selectedTrack }

    var visibleTracks: [Track] { hosts[currentPage]?.tracks ?? [] }

    func showPage(_ page: LibraryPage) {
        guard page != .settings else {
            cancelPageWork()
            hosts[currentPage]?.deactivate()
            onSettingsRequested?()
            return
        }
        show(destination: NavigationDestination(page: page), recordHistory: true)
    }

    func show(destination newDestination: NavigationDestination, recordHistory: Bool) {
        if recordHistory, currentDestination != newDestination {
            backStack.append(currentDestination)
            if backStack.count > Self.maximumHistoryCount {
                backStack.removeFirst(backStack.count - Self.maximumHistoryCount)
            }
            forwardStack.removeAll()
        }

        cancelPageWork()
        if currentPage != newDestination.page {
            hosts[currentPage]?.deactivate()
            (hosts[currentPage] as? any CatalogNavigationHost)?.clear()
        }
        destination = newDestination
        if let catalogHost = catalogHost(for: newDestination.page), case let .catalog(route) = newDestination {
            catalogHost.select(route: route)
        } else if let playlistHost, case let .playlist(playlist) = newDestination {
            playlistHost.select(destination: playlist)
            playlistHost.setQuery(query)
        }

        guard let host = hosts[newDestination.page] else { return }
        pageTitle.stringValue = newDestination.page.rawValue
        setContentView(host.view)
        host.activate()
        if catalogHost(for: newDestination.page) != nil {
            startPageLoad()
        } else if newDestination.page == .playlists {
            playlistHost?.refresh()
        } else {
            host.refresh()
        }
        onPageChanged?(newDestination.page)
        updateNavigationButtons()
    }

    func updateQuery(_ newQuery: String) {
        guard !newQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearQuery()
            return
        }
        query = newQuery
        if currentPage == .search {
            reloadCurrentPage()
        } else {
            searchReturnDestination = currentDestination
            show(destination: .catalog(.search), recordHistory: false)
        }
    }

    func clearQuery() {
        query = ""
        guard currentPage == .search else { return }
        let returnDestination = searchReturnDestination ?? .catalog(.songs)
        searchReturnDestination = nil
        show(destination: returnDestination, recordHistory: false)
    }

    func goBack() {
        guard currentPage != .search, let previous = backStack.popLast() else { return }
        forwardStack.append(currentDestination)
        if forwardStack.count > Self.maximumHistoryCount {
            forwardStack.removeFirst(forwardStack.count - Self.maximumHistoryCount)
        }
        show(destination: previous, recordHistory: false)
    }

    func goForward() {
        guard currentPage != .search, let next = forwardStack.popLast() else { return }
        backStack.append(currentDestination)
        if backStack.count > Self.maximumHistoryCount {
            backStack.removeFirst(backStack.count - Self.maximumHistoryCount)
        }
        show(destination: next, recordHistory: false)
    }
    func removePlaylistFromHistory(id: Int64) {
        let deleted = NavigationDestination.playlist(.user(id))
        backStack.removeAll { $0 == deleted }
        forwardStack.removeAll { $0 == deleted }
        updateNavigationButtons()
    }

    func updateNavigationButtons() {
        backButton.isEnabled = currentPage != .search && !backStack.isEmpty
        forwardButton.isEnabled = currentPage != .search && !forwardStack.isEmpty
    }

    func reactivateCurrentPage() {
        hosts[currentPage]?.activate()
        reloadCurrentPage()
    }

    func reloadCurrentPage() {
        if catalogHost(for: currentPage) != nil {
            startPageLoad()
        } else if currentPage == .playlists {
            playlistHost?.refresh()
        } else {
            hosts[currentPage]?.refresh()
        }
    }

    func loadMore(kind: CatalogAppendKind) {
        guard !catalogPageLoadCoordinator.isLoading,
              let host = catalogHost(for: currentPage),
              let request = host.appendRequest(query: query, kind: kind) else { return }
        startMorePageLoad(request)
    }

    @discardableResult
    func startShuffle(onQueue: @escaping @MainActor (PlaybackQueue) -> Void) -> Bool {
        guard let host = catalogHost(for: currentPage),
              let request = host.shuffleRequest(query: query) else { return false }
        let page = currentPage
        let route = host.route
        let query = query
        return shuffleCoordinator.start(
            request: request,
            start: .shuffled,
            onSuccess: { [weak self] queue in
                guard let self,
                      self.currentPage == page,
                      self.query == query,
                      self.catalogHost(for: page)?.route == route else { return }
                onQueue(queue)
            },
            onFailure: { [weak self] error in
                self?.onError?(error, "Could not load tracks for shuffle", .general)
            }
        )
    }

    @discardableResult
    func startPlaybackForCatalogTrack(
        _ track: Track,
        onQueue: @escaping @MainActor (PlaybackQueue) -> Void
    ) -> Bool {
        guard let host = catalogHost(for: currentPage),
              let request = host.shuffleRequest(query: query) else { return false }
        let context = catalogPageContext(for: host)
        return shuffleCoordinator.start(
            request: request,
            start: .selectedTrack(track),
            onSuccess: { [weak self] queue in
                guard let self, self.isCurrentCatalogPage(context) else { return }
                onQueue(queue)
            },
            onFailure: { [weak self] error in
                guard let self, self.isCurrentCatalogPage(context) else { return }
                self.onError?(error, "Could not load tracks for playback", .general)
            }
        )
    }

    func cancelShuffle() {
        shuffleCoordinator.cancel()
    }

    func cancel() { cancelPageWork() }

    private func catalogHost(for page: LibraryPage) -> (any CatalogNavigationHost)? {
        hosts[page] as? any CatalogNavigationHost
    }

    private func startPageLoad() {
        shuffleCoordinator.cancel()
        catalogPageLoadCoordinator.cancel()
        guard let host = catalogHost(for: currentPage) else {
            hosts[currentPage]?.refresh()
            return
        }
        guard let database = databaseProvider() else {
            host.clear()
            return
        }
        let context = catalogPageContext(for: host)
        catalogPageLoadCoordinator.start(
            database: database,
            request: .replace(context),
            onSuccess: { [weak self] result in
                guard let self, self.isCurrentCatalogPage(result.context) else { return }
                self.onClearOperationalErrors?(.database)
                host.apply(result: result)
            },
            onFailure: { [weak self] context, error in
                guard let self, self.isCurrentCatalogPage(context) else { return }
                host.clear()
                let message: String
                switch context.route {
                case .search: message = "Could not search library"
                case .songs: message = "Could not load songs"
                case .artists, .albums, .genres: message = "Could not load library details"
                }
                self.onError?(error, message, .database)
            }
        )
    }

    private func startMorePageLoad(_ request: CatalogPageAppendRequest) {
        guard !catalogPageLoadCoordinator.isLoading, let database = databaseProvider() else { return }
        let host = catalogHost(for: currentPage)
        catalogPageLoadCoordinator.start(
            database: database,
            request: .append(request),
            onSuccess: { [weak self] result in
                guard let self, self.isCurrentCatalogPage(result.context) else { return }
                self.onClearOperationalErrors?(.database)
                host?.apply(result: result)
            },
            onFailure: { [weak self] context, error in
                guard let self, self.isCurrentCatalogPage(context) else { return }
                self.onError?(error, "Could not load more library items", .database)
            }
        )
    }

    private func isCurrentCatalogPage(_ context: CatalogPageContext) -> Bool {
        return currentCatalogPageContext == context
    }

    private func cancelPageWork() {
        catalogPageLoadCoordinator.cancel()
        shuffleCoordinator.cancel()
        playlistHost?.cancelLoading()
        onPageWorkCancelled?()
    }

    private func setContentView(_ contentView: NSView) {
        if contentView.superview !== contentHost {
            contentView.translatesAutoresizingMaskIntoConstraints = true
            contentView.frame = contentHost.bounds
            contentView.autoresizingMask = [.width, .height]
            contentHost.addSubview(contentView)
        }
        for subview in contentHost.subviews {
            if subview === contentView {
                subview.isHidden = false
            } else {
                resetTransientState(in: subview)
                subview.isHidden = true
            }
        }
    }

    private func resetTransientState(in view: NSView) {
        if let marquee = view as? MarqueeLabel { marquee.prepareForHiding() }
        view.subviews.forEach { resetTransientState(in: $0) }
    }
}
