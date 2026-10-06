import AppKit
import OSLog
import WavebookCore

final class FittingBoundaryView: ThemeBackgroundView {
    private var stableFittingSize = NSSize.zero

    override var fittingSize: NSSize {
        guard stableFittingSize.width > 0, stableFittingSize.height > 0 else {
            return bounds.size
        }
        return stableFittingSize
    }

    override func setFrameSize(_ newSize: NSSize) {
        let shouldCaptureSize = stableFittingSize.width <= 0
            || stableFittingSize.height <= 0
            || window?.inLiveResize == true
        super.setFrameSize(newSize)
        if shouldCaptureSize {
            stableFittingSize = newSize
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        stableFittingSize = bounds.size
    }
}

final class MainViewController: NSViewController {
    static let logger = Logger(subsystem: "Wavebook", category: "application")

    lazy var notifications = ApplicationNotificationCoordinator(logger: Self.logger)
    var onPageChanged: ((LibraryPage) -> Void)?
    var onPlaylistCatalogChanged: (([Playlist]) -> Void)?
    var onOnboardingRequested: (() -> Void)?
    var onLibraryScanStateChanged: ((LibraryScanSnapshot) -> Void)?

    let songsPage = SongsPageViewController()
    let artistsPage = ArtistsPageViewController()
    let albumsPage = AlbumsPageViewController()
    let genresPage = GenresPageViewController()
    let searchPage = SearchPageViewController()
    let statisticsPage = StatisticsPageViewController()
    let playlistsPage = PlaylistPageViewController()
    let queue = QueueViewController()
    let playerBar = PlayerBarView()
    let backButton = NSButton(
        image: NSImage(
            systemSymbolName: "chevron.left",
            accessibilityDescription: "Back"
        ) ?? NSImage(),
        target: nil,
        action: nil
    )
    let forwardButton = NSButton(
        image: NSImage(
            systemSymbolName: "chevron.right",
            accessibilityDescription: "Forward"
        ) ?? NSImage(),
        target: nil,
        action: nil
    )
    let pageTitle = NSTextField(labelWithString: "Songs")
    private let lyricFileLoader = LRCLyricsLoader()
    private let lyricsFileAvailabilityCache = LyricsFileAvailabilityCache()
    private var lyricsActionTask: Task<Void, Never>?
    private var hasAppliedInitialSettings = false
    private var appliedQueuePresentationRevision: UInt64?
    var hasStartedInitialLibraryScan = false
    var hasCompletedInitialLibraryScan = false
    var initialLibraryScanShuffleRequest = InitialLibraryScanShuffleRequest<CatalogPageContext>()
    let searchField: NSSearchField
    let shuffleButton = NSButton(title: "Shuffle Play", target: nil, action: nil)
    let addRootButton = NSButton(title: "Add Folder…", target: nil, action: nil)
    let settingsButton = NSButton(title: "Settings…", target: nil, action: nil)
    let contentHost = FittingBoundaryView()
    init(searchField: NSSearchField) {
        self.searchField = searchField
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    lazy var database: LibraryDatabase? = {
        do {
            return try Self.makeDatabase()
        } catch {
            handlePlaybackEvent(.error(error, message: "Could not start library database", kind: .database))
            return nil
        }
    }()

    lazy var playbackSession: PlaybackSessionCoordinator = {
        PlaybackSessionCoordinator(
            databaseProvider: { [weak self] in self?.database },
            shouldLoadReplayGainData: { [weak self] in self?.audioSettings.isEqualizerVisible ?? false },
            events: .init(
                presentationChanged: { [weak self] state in
                    self?.applyPlaybackPresentation(state)
                },
                event: { [weak self] event in
                    self?.handlePlaybackEvent(event)
                }
            )
        )
    }()

    lazy var audioSettings: AudioSettingsCoordinator = {
        AudioSettingsCoordinator(
            databaseProvider: { [weak self] in self?.database },
            audioOutput: self.playbackSession.audioOutput,
            playbackTransport: self.playbackSession.transport,
            playerBar: playerBar,
            onEvent: { [weak self] event in
                self?.handlePlaybackEvent(event)
            }
        )
    }()

    lazy var replayGainAnalysis: ReplayGainAnalysisCoordinator = {
        ReplayGainAnalysisCoordinator(
            databaseProvider: { [weak self] in self?.database },
            onEvent: { [weak self] event in
                self?.handlePlaybackEvent(event)
            }
        )
    }()

    lazy var libraryScan: LibraryScanCoordinator = {
        LibraryScanCoordinator(
            databaseProvider: { [weak self] in self?.database },
            onEvent: { [weak self] event in
                self?.handlePlaybackEvent(event)
            },
            onLibraryChanged: { [weak self] in
                self?.navigation.reloadCurrentPage()
            },
            onReplayGainStart: { [weak self] in
                self?.replayGainAnalysis.start()
            },
            onScanStateChanged: { [weak self] snapshot in
                self?.onLibraryScanStateChanged?(snapshot)
            }
        )
    }()

    lazy var navigation: AppNavigationCoordinator = {
        let coordinator = AppNavigationCoordinator(
            contentHost: contentHost,
            backButton: backButton,
            forwardButton: forwardButton,
            pageTitle: pageTitle,
            databaseProvider: { [weak self] in self?.database },
            navigationHosts: [
                searchPage,
                songsPage,
                artistsPage,
                albumsPage,
                genresPage,
                playlistsPage,
                queue,
                statisticsPage
            ]
        )
        coordinator.onPageChanged = { [weak self] page in
            self?.onPageChanged?(page)
        }
        coordinator.onSettingsRequested = { [weak self] in
            self?.showSettings()
        }
        coordinator.onError = { [weak self] error, message, kind in
            self?.report(error, message: message, kind: kind)
        }
        coordinator.onClearOperationalErrors = { [weak self] kind in
            self?.clearOperationalErrors(for: kind)
        }
        coordinator.onPageWorkCancelled = { [weak self] in
            self?.replayGainAnalysis.cancelAlbumRescan()
        }
        return coordinator
    }()

    override func viewDidAppear() {
        super.viewDidAppear()
        notifications.viewDidAppear()
        guard !hasAppliedInitialSettings else { return }
        hasAppliedInitialSettings = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.startInitialState()
            self.applyInitialSettings()
        }
    }

    override func loadView() {
        let root = ThemeBackgroundView()
        configureTheme(for: root)
        configurePageCallbacks()
        configureQueueCallbacks()
        configurePlayerCallbacks()
        let topBar = configureControls()
        configureLayout(root: root, topBar: topBar)
        view = root
    }

    override func viewWillDisappear() {
        notifications.viewWillDisappear()
        super.viewWillDisappear()
        playbackSession.transport.viewWillDisappear()
        navigation.cancel()
        initialLibraryScanShuffleRequest.cancel()
        libraryScan.cancel()
        replayGainAnalysis.cancel()
        lyricsActionTask?.cancel()
        lyricsActionTask = nil
    }

    private func applyPlaybackPresentation(_ state: PlaybackPresentationState) {
        if appliedQueuePresentationRevision != state.queue.revision || state.shouldScrollQueueToCurrent {
            queue.setTracks(
                state.queue.entries,
                currentIndex: state.queue.currentIndex,
                scrollToCurrent: state.shouldScrollQueueToCurrent
            )
            appliedQueuePresentationRevision = state.queue.revision
        }
        if let track = state.transport.track {
            playerBar.set(
                track: track,
                artwork: state.transport.artwork,
                duration: state.transport.duration,
                isPlaying: state.transport.isPlaying
            )
        } else {
            playerBar.clearTrack()
        }
        playerBar.setPlaying(state.transport.isPlaying)
        playerBar.setProgress(elapsed: state.transport.elapsed, duration: state.transport.duration)
        playerBar.setLyricsEnabled(state.transport.lyricsEnabled)
        playerBar.setLyricsPreview(state.transport.lyricsPreview)
        playerBar.setShuffleEnabled(state.queue.isShuffled)
        playerBar.setRepeatMode(state.queue.repeatMode)
        playerBar.setReplayGainMode(state.transport.replayGain.mode)
        audioSettings.setReplayGainDetails(state.transport.replayGain)
    }

    private func handlePlaybackEvent(_ event: PlaybackSessionEvent) {
        switch event {
        case let .error(error, message, kind):
            report(error, message: message, kind: kind)
        case let .clearOperationalErrors(kind):
            clearOperationalErrors(for: kind)
        case let .persistenceError(message):
            showPersistenceError(message)
        case let .initialPersistenceWarning(message):
            showPersistenceError(message)
        case let .persistenceWarningChanged(warning):
            persistenceWarningDidChange(warning)
        case .outputDeviceChanged:
            audioSettings.defaultOutputDeviceChanged()
        case .libraryContentChanged:
            navigation.reloadCurrentPage()
        case let .presentOperationalMessage(message, kind):
            queueOrPresentOperationalError(message, kind: kind)
        case let .replayGainActionError(message):
            showReplayGainActionError(message)
        }
    }

    func report(_ error: Error, message: String, kind: OperationalErrorKind = .general) {
        notifications.report(error, message: message, kind: kind)
    }

    func queueOrPresentOperationalError(_ message: String, kind: OperationalErrorKind = .general) {
        notifications.present(message, kind: kind)
    }

    func clearOperationalErrors(for kind: OperationalErrorKind) {
        notifications.clearOperationalErrors(for: kind)
    }

    private static func makeDatabase() throws -> LibraryDatabase {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = base.appending(path: "Wavebook", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try LibraryDatabase(path: directory.appending(path: "Library.sqlite").path)
    }
}
extension MainViewController {
    func beginRenamePlaylist(id: Int64) {
        clearSearch()
        navigation.show(destination: .playlist(.user(id)), recordHistory: true)
        playlistsPage.beginRename(playlistID: id)
    }

    func beginDeletePlaylist(id: Int64) {
        clearSearch()
        navigation.show(destination: .playlist(.user(id)), recordHistory: true)
        playlistsPage.beginDelete(playlistID: id)
    }
}
private struct MainPageLyricsCallbacks {
    let openInApp: (Track, URL) -> Void
    let showInFinder: (Track) -> Void
    let fileAvailability: (Track) -> Bool?
    let prefetchFileAvailability: ([Track]) -> Void
    let observeFileAvailability: LyricsFileAvailabilityObserver
}

extension MainViewController {
    private func configureTheme(for root: ThemeBackgroundView) {
        root.onThemeChange = { [weak self] in
            guard let self else { return }
            self.searchField.layer?.backgroundColor = AppTheme.cgColor(AppTheme.raised, in: self.searchField)
        }
    }

    private func configurePageCallbacks() {
        let lyricsCallbacks = makeMainPageLyricsCallbacks()
        configurePlaybackAndNavigationCallbacks(lyricsCallbacks)
        configureCatalogPages(lyricsCallbacks)
        configureSongsAndPlaylistCallbacks(lyricsCallbacks)
    }

    private func makeMainPageLyricsCallbacks() -> MainPageLyricsCallbacks {
        MainPageLyricsCallbacks(
            openInApp: { [weak self] track, applicationURL in
                self?.openLyricsInApp(for: track, with: applicationURL)
            },
            showInFinder: { [weak self] track in
                self?.showLyricsInFinder(for: track)
            },
            fileAvailability: { [weak self] track in
                self?.lyricsFileAvailability(for: track)
            },
            prefetchFileAvailability: { [weak self] tracks in
                self?.prefetchLyricsFileAvailability(for: tracks)
            },
            observeFileAvailability: { [weak self] track, completion in
                self?.observeLyricsFileAvailability(for: track, completion: completion)
            }
        )
    }

    private func configurePlaybackAndNavigationCallbacks(_ lyricsCallbacks: MainPageLyricsCallbacks) {
        searchPage.onPlay = { [weak self] track in _ = self?.playbackSession.queue.play(track) }
        searchPage.onAlbumSelect = { [weak self] key in self?.openAlbum(key) }
        searchPage.onArtistSelect = { [weak self] artist in self?.openArtist(artist) }
        searchPage.onGenreSelect = { [weak self] genre in self?.openGenre(genre) }
        statisticsPage.databaseProvider = { [weak self] in self?.database }
        statisticsPage.trackerProvider = { [weak self] in self?.playbackSession.history.tracker }
        statisticsPage.renderedPositionProvider = { [weak self] in self?.playbackSession.history.renderedPosition }
        statisticsPage.isPlayingProvider = { [weak self] in self?.playbackSession.transport.isPlaying ?? false }
        playlistsPage.databaseProvider = { [weak self] in self?.database }
        playlistsPage.onPlaybackIntent = { [weak self] in
            self?.initialLibraryScanShuffleRequest.cancel()
            self?.navigation.cancelShuffle()
        }
        playbackSession.queue.onPlaybackCommand = { [weak self] in
            self?.initialLibraryScanShuffleRequest.cancel()
            self?.navigation.cancelShuffle()
            self?.playlistsPage.cancelPlaybackLoading()
            self?.startInitialLibraryScanIfNeeded()
        }
        queue.onOpenLyricsInApp = lyricsCallbacks.openInApp
        queue.onShowLyricsInFinder = lyricsCallbacks.showInFinder
        queue.lyricsFileAvailabilityProvider = lyricsCallbacks.fileAvailability
        queue.onPrefetchLyricsFileAvailability = lyricsCallbacks.prefetchFileAvailability
        queue.lyricsFileAvailabilityObserver = lyricsCallbacks.observeFileAvailability
        playlistsPage.onPlayPlaylist = { [weak self] queue in
            guard let self else { return }
            guard !queue.isEmpty else {
                self.queueOrPresentOperationalError("This playlist has no available tracks")
                return
            }
            _ = self.playbackSession.queue.playPlaylist(queue)
        }
        playlistsPage.onError = { [weak self] error in
            self?.report(error, message: "Could not load playlist", kind: .database)
        }
        playerBar.onTogglePrivateMode = { [weak self] in self?.togglePrivateMode() }
        playerBar.onToggleFavorite = { [weak self] track in self?.toggleFavorites([track]) }
    }

    private func configureCatalogPages(_ lyricsCallbacks: MainPageLyricsCallbacks) {
        let playWithinCatalogContext: (Track) -> Void = { [weak self] track in
            _ = self?.playTrackWithinCatalogContext(track)
        }
        configureCatalogPageCallbacks(
            artistsPage,
            lyricsCallbacks: lyricsCallbacks,
            onPlay: playWithinCatalogContext
        )
        configureCatalogPageCallbacks(
            albumsPage,
            lyricsCallbacks: lyricsCallbacks,
            onPlay: playWithinCatalogContext,
            onRescanLoudness: { [weak self] _ in self?.rescanSelectedAlbumLoudness() }
        )
        configureCatalogPageCallbacks(
            genresPage,
            lyricsCallbacks: lyricsCallbacks,
            onPlay: { [weak self] track in _ = self?.playbackSession.queue.play(track) }
        )
    }

    private func configureSongsAndPlaylistCallbacks(_ lyricsCallbacks: MainPageLyricsCallbacks) {
        songsPage.actions = SongListActions(
            onPlay: { [weak self] track in _ = self?.playbackSession.queue.play(track) },
            contextMenuActions: TrackContextMenuActions(
                onAddToQueue: { [weak self] tracks in self?.playbackSession.queue.addToQueue(tracks) },
                onAddNextToQueue: { [weak self] tracks in self?.playbackSession.queue.addNextToQueue(tracks) },
                onDownloadLyrics: { [weak self] track in self?.showLyricsDownloadDialog(for: track) },
                onOpenLyricsInApp: lyricsCallbacks.openInApp,
                onShowLyricsInFinder: lyricsCallbacks.showInFinder,
                lyricsFileAvailabilityProvider: lyricsCallbacks.fileAvailability,
                lyricsFileAvailabilityObserver: lyricsCallbacks.observeFileAvailability,
                onManageSkipSegments: { [weak self] track in self?.manageSkipSegments(for: track) },
                onAlbumSelect: { [weak self] key in self?.openAlbum(key) },
                onArtistSelect: { [weak self] artist in self?.openArtist(artist) },
                onGenreSelect: { [weak self] genre in self?.openGenre(genre) },
                onRescanLoudness: { [weak self] tracks in self?.replayGainAnalysis.rescanLoudness(for: tracks) },
                onToggleFavorite: { [weak self] tracks in self?.toggleFavorites(tracks) },
                manualPlaylists: songsPage.actions.contextMenuActions.manualPlaylists,
                onAddToPlaylist: { [weak self] tracks, playlistID in
                    self?.addTracks(tracks, toPlaylistID: playlistID)
                }
            ),
            onPrefetchLyricsFileAvailability: lyricsCallbacks.prefetchFileAvailability,
            onRequestMore: { [weak self] in self?.navigation.loadMore(kind: .page) }
        )
        playlistsPage.onPlaylistMutation = { [weak self] in self?.refreshPlaylistCatalog() }
        playlistsPage.onToggleFavorite = { [weak self] tracks in self?.toggleFavorites(tracks) }
        playlistsPage.onManageSkipSegments = { [weak self] track in self?.manageSkipSegments(for: track) }
        playlistsPage.onSelectDestination = { [weak self] destination in
            self?.navigation.show(destination: .playlist(destination), recordHistory: true)
        }
        playlistsPage.onPlaylistDeleted = { [weak self] id in
            guard let self else { return }
            self.navigation.removePlaylistFromHistory(id: id)
            guard self.navigation.currentDestination == .playlist(.user(id)) else { return }
            self.navigation.show(destination: .playlist(.system(.recentlyAdded)), recordHistory: false)
        }
    }

    private func configureCatalogPageCallbacks(
        _ page: FacetTracksPageViewController,
        lyricsCallbacks: MainPageLyricsCallbacks,
        onPlay: @escaping (Track) -> Void,
        onRescanLoudness: (([Track]) -> Void)? = nil
    ) {
        page.actions = SongListActions(
            onPlay: onPlay,
            contextMenuActions: TrackContextMenuActions(
                onAddToQueue: { [weak self] tracks in self?.playbackSession.queue.addToQueue(tracks) },
                onAddNextToQueue: { [weak self] tracks in self?.playbackSession.queue.addNextToQueue(tracks) },
                onDownloadLyrics: { [weak self] track in self?.showLyricsDownloadDialog(for: track) },
                onOpenLyricsInApp: lyricsCallbacks.openInApp,
                onShowLyricsInFinder: lyricsCallbacks.showInFinder,
                lyricsFileAvailabilityProvider: lyricsCallbacks.fileAvailability,
                lyricsFileAvailabilityObserver: lyricsCallbacks.observeFileAvailability,
                onManageSkipSegments: { [weak self] track in self?.manageSkipSegments(for: track) },
                onAlbumSelect: { [weak self] key in self?.openAlbum(key) },
                onArtistSelect: { [weak self] artist in self?.openArtist(artist) },
                onGenreSelect: { [weak self] genre in self?.openGenre(genre) },
                onRescanLoudness: onRescanLoudness ?? { [weak self] tracks in
                    self?.replayGainAnalysis.rescanLoudness(for: tracks)
                },
                onToggleFavorite: { [weak self] tracks in self?.toggleFavorites(tracks) },
                manualPlaylists: songsPage.actions.contextMenuActions.manualPlaylists,
                onAddToPlaylist: { [weak self] tracks, playlistID in
                    self?.addTracks(tracks, toPlaylistID: playlistID)
                }
            ),
            onPrefetchLyricsFileAvailability: lyricsCallbacks.prefetchFileAvailability
        )
        page.onSelectionChanged = { [weak self] in self?.navigation.reloadCurrentPage() }
        page.onRequestMoreFacets = { [weak self] in self?.navigation.loadMore(kind: .facets) }
        page.onRequestMoreDetails = { [weak self] in self?.navigation.loadMore(kind: .details) }
    }
    private func lyricsFileAvailability(for track: Track) -> Bool? {
        if let cachedValue = lyricsFileAvailabilityCache.value(for: track.path) {
            return cachedValue
        }
        lyricsFileAvailabilityCache.prefetch([track])
        return nil
    }

    private func observeLyricsFileAvailability(
        for track: Track,
        completion: @escaping (Bool) -> Void
    ) {
        lyricsFileAvailabilityCache.observe(path: track.path, completion: completion)
    }

    private func prefetchLyricsFileAvailability(for tracks: [Track]) {
        lyricsFileAvailabilityCache.prefetch(tracks, database: database)
    }

    private func openLyricsInApp(for track: Track, with applicationURL: URL) {
        resolveLyricsFile(for: track) { lyricURL in
            openFile(lyricURL, with: applicationURL)
        }
    }

    private func showLyricsInFinder(for track: Track) {
        resolveLyricsFile(for: track) { lyricURL in
            NSWorkspace.shared.activateFileViewerSelecting([lyricURL])
        }
    }

    private func resolveLyricsFile(for track: Track, completion: @escaping (URL) -> Void) {
        lyricsActionTask?.cancel()
        let loader = lyricFileLoader
        let database = database
        let audioURL = URL(fileURLWithPath: track.path)
        lyricsActionTask = Task { @MainActor [weak self] in
            do {
                guard let lyricURL = try await loader.lyricFileURL(for: audioURL, database: database) else {
                    guard !Task.isCancelled, let self else { return }
                    self.report(CocoaError(.fileNoSuchFile), message: "LRC file is unavailable")
                    return
                }
                guard !Task.isCancelled, self != nil else { return }
                completion(lyricURL)
            } catch {
                guard !Task.isCancelled else { return }
                self?.report(error, message: "Could not resolve lyrics file")
            }
        }
    }

}
