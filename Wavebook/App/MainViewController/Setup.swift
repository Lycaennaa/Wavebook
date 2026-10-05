import AppKit
import WavebookCore

extension MainViewController {
    func manageSkipSegments(for track: Track) {
        playbackSession.transport.showSkipSegments(for: track, owner: self)
    }

    func toggleFavorites(_ tracks: [Track]) {
        guard let database else { return }
        let trackIDs = tracks.compactMap(\.id)
        guard !trackIDs.isEmpty else { return }
        do {
            let changes = try database.toggleFavorite(trackIDs: trackIDs)
            playbackSession.updateFavoriteStates(changes)
            navigation.reloadCurrentPage()
        } catch {
            report(error, message: "Could not update favorites", kind: .database)
        }
    }

    func addTracks(_ tracks: [Track], toPlaylistID playlistID: Int64) {
        guard let database else { return }
        do {
            let result = try database.addTracks(tracks.compactMap(\.id), toPlaylistID: playlistID)
            if result.shouldWarnAboutDuplicates {
                notifications.present(
                    "Some selected tracks are already in this playlist. They were added again.",
                    kind: .general
                )
            }
        } catch {
            report(error, message: "Could not add tracks to playlist", kind: .database)
        }
    }

    func refreshPlaylistCatalog() {
        guard let database else { return }
        do {
            let playlists = try database.playlists()
            let manualPlaylists = playlists.filter { $0.kind == .manual }
            songsPage.actions.contextMenuActions.manualPlaylists = manualPlaylists
            [artistsPage, albumsPage, genresPage].forEach {
                $0.actions.contextMenuActions.manualPlaylists = manualPlaylists
            }
            onPlaylistCatalogChanged?(playlists)
        } catch {
            report(error, message: "Could not load playlists", kind: .database)
        }
    }

    func configureQueueCallbacks() {
        queue.onPlay = { [weak self] entry in
            _ = self?.playbackSession.queue.playQueuedTrack(entry)
        }
        queue.onRemove = { [weak self] entryIDs in
            self?.playbackSession.queue.removeQueuedTracks(withIDs: entryIDs)
        }
        queue.onMove = { [weak self] entry, destination in
            self?.playbackSession.queue.moveQueuedTrack(entry, to: destination) ?? false
        }
        queue.onAlbumSelect = { [weak self] key in self?.openAlbum(key) }
        queue.onArtistSelect = { [weak self] artist in self?.openArtist(artist) }
        queue.onToggleFavorite = { [weak self] tracks in self?.toggleFavorites(tracks) }
        queue.onGenreSelect = { [weak self] genre in self?.openGenre(genre) }
        queue.onManageSkipSegments = { [weak self] track in self?.manageSkipSegments(for: track) }
        queue.onRefresh = { [weak self] in
            self?.playbackSession.updateQueue(scrollToCurrent: true)
        }
    }

    func configurePlayerCallbacks() {
        playerBar.onAlbumSelect = { [weak self] key in self?.openAlbum(key) }
        playerBar.onArtistSelect = { [weak self] artist in self?.openArtist(artist) }
        playerBar.onGenreSelect = { [weak self] genre in self?.openGenre(genre) }
        playerBar.onTogglePlayback = { [weak self] in
            guard let self else { return }
            _ = self.playbackSession.queue.togglePlayback(
                selectedTrack: self.navigation.selectedTrack,
                shuffle: { [weak self] in self?.startShufflePlay() ?? false }
            )
        }
        playerBar.onPreviousPlayback = { [weak self] in
            _ = self?.playbackSession.queue.playPreviousQueuedTrack()
        }
        playerBar.onNextPlayback = { [weak self] in
            _ = self?.playbackSession.queue.playNextQueuedTrack()
        }
        playerBar.onToggleShuffle = { [weak self] in self?.playbackSession.queue.toggleShuffle() }
        playerBar.onCycleRepeatMode = { [weak self] in self?.playbackSession.queue.cycleRepeatMode() }
        playerBar.onCycleReplayGainMode = { [weak self] in _ = self?.playbackSession.replayGain.cycleMode() }
        playerBar.onVolumeChanged = { [weak self] volume in self?.audioSettings.setVolume(volume) }
        playbackSession.transport.onVolumeChanged = { [weak self] volume in self?.audioSettings.setVolume(volume) }
        audioSettings.onVolumeChanged = { [weak self] _ in self?.playbackSession.transport.refreshVolume() }
        playerBar.onSeek = { [weak self] seconds in _ = self?.playbackSession.transport.seek(to: seconds) }
        playerBar.onEqualizerRequested = { [weak self] in self?.showEqualizer() }
        playerBar.onOutputDeviceRequested = { [weak self] button in self?.showOutputDeviceMenu(from: button) }
        playerBar.onLyricsRequested = { [weak self] in self?.showLyrics() }
        playerBar.onSkipSegmentsRequested = { [weak self] in
            guard let self else { return }
            self.playbackSession.transport.showSkipSegments(owner: self)
        }
    }

    func configureControls() -> NSStackView {
        for button in [backButton, forwardButton] {
            button.bezelStyle = .texturedRounded
            button.contentTintColor = AppTheme.accent
        }
        backButton.target = self
        backButton.action = #selector(goBack)
        forwardButton.target = self
        forwardButton.action = #selector(goForward)
        searchField.placeholderString = "Search songs, artists, albums, genres"
        searchField.appearance = nil
        searchField.focusRingType = .exterior
        searchField.wantsLayer = true
        searchField.layer?.backgroundColor = AppTheme.cgColor(AppTheme.raised, in: searchField)
        searchField.layer?.cornerRadius = 10
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        pageTitle.font = .systemFont(ofSize: 22, weight: .semibold)
        pageTitle.textColor = AppTheme.primaryText
        pageTitle.translatesAutoresizingMaskIntoConstraints = false
        shuffleButton.bezelStyle = .rounded
        shuffleButton.contentTintColor = AppTheme.accent
        shuffleButton.target = self
        shuffleButton.action = #selector(shufflePlay)
        addRootButton.bezelStyle = .rounded
        addRootButton.contentTintColor = AppTheme.accent
        addRootButton.target = self
        addRootButton.action = #selector(addRoot)
        settingsButton.bezelStyle = .rounded
        settingsButton.contentTintColor = AppTheme.accent
        settingsButton.target = self
        settingsButton.action = #selector(showSettings)
        let topBar = NSStackView(
            views: [backButton, forwardButton, pageTitle, searchField, shuffleButton, addRootButton, settingsButton]
        )
        topBar.orientation = .horizontal
        topBar.spacing = 10
        topBar.translatesAutoresizingMaskIntoConstraints = false
        return topBar
    }

    func configureLayout(root: ThemeBackgroundView, topBar: NSStackView) {
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        playerBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(topBar)
        root.addSubview(contentHost)
        notifications.install(in: root, below: topBar, above: contentHost)
        root.addSubview(playerBar)
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            topBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            backButton.widthAnchor.constraint(equalToConstant: 32),
            forwardButton.widthAnchor.constraint(equalToConstant: 32),
            pageTitle.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            contentHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: playerBar.topAnchor),
            playerBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            playerBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            playerBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            playerBar.heightAnchor.constraint(equalToConstant: 160)
        ])
    }

    func applyInitialSettings() {
        let settings: LibraryStartupSettings?
        do {
            settings = try database?.startupSettings()
        } catch {
            report(error, message: "Could not load startup settings", kind: .database)
            settings = nil
        }
        if let settings {
            audioSettings.applySavedVolume(settings.volume)
            playbackSession.transport.applySavedSkipSilentSegments(settings.skipSilentSegments)
            playbackSession.replayGain.applySavedMode(settings.replayGainMode)
            replayGainAnalysis.applySavedFileConcurrency(settings.replayGainAnalysisFileConcurrency)
            audioSettings.applySavedOutputDevice(
                selectedUID: settings.selectedOutputDeviceUID,
                hiddenUIDs: settings.hiddenOutputDeviceUIDs
            )
        } else {
            audioSettings.applySavedVolume(1)
            playbackSession.transport.applySavedSkipSilentSegments(false)
            playbackSession.replayGain.applySavedMode(.defaultValue)
            replayGainAnalysis.applySavedFileConcurrency(ReplayGain.defaultAnalysisFileConcurrency)
            audioSettings.applySavedOutputDevice(selectedUID: nil, hiddenUIDs: [])
        }
        audioSettings.applySavedEqualizer()
        applySavedPrivateMode()
        playbackSession.refreshPresentation()
    }

    func startInitialLibraryScanIfNeeded() {
        guard !hasStartedInitialLibraryScan else { return }
        hasStartedInitialLibraryScan = true
        hasCompletedInitialLibraryScan = false
        libraryScan.rescanPersistedRoots(startReplayGain: false) { [weak self] succeeded in
            self?.initialLibraryScanDidComplete(succeeded: succeeded)
        }
    }

    private func initialLibraryScanDidComplete(succeeded: Bool) {
        hasStartedInitialLibraryScan = succeeded
        hasCompletedInitialLibraryScan = true
        guard initialLibraryScanShuffleRequest.takeAfterScanCompletes(in: navigation.currentCatalogPageContext) else {
            return
        }
        _ = beginShufflePlay()
    }

    func startInitialState() {
        refreshPlaylistCatalog()
        do {
            try audioSettings.startMonitoringDefaultOutputDevice()
            clearOperationalErrors(for: .audioOutput)
        } catch {
            report(error, message: "Could not monitor system audio output changes", kind: .audioOutput)
        }
        navigation.show(destination: .catalog(.songs), recordHistory: false)
        playbackSession.refreshPresentation()
        startInitialLibraryScanIfNeeded()
    }
}
