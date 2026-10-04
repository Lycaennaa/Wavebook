import AppKit
import WavebookCore

private enum PlaylistPageLimitError: LocalizedError {
    case itemLimitReached

    var errorDescription: String? {
        "This playlist exceeds the maximum displayed item count."
    }
}

@MainActor
final class PlaylistPageViewController: NSViewController, NavigationHost, PlaylistNavigationHost {

    private static let pageSize = 100
    private let loadCoordinator = PlaylistPageLoadCoordinator()
    private let playbackLoadCoordinator = PlaylistPlaybackLoadCoordinator()
    private var loadedContent: PlaylistPageLoadedContent?
    private var playlistKind: PlaylistKind?
    private var playlistDefinition: PlaylistDefinition?
    private var isActive = false

    private var workflowContext: PlaylistPageWorkflowContext {
        PlaylistPageWorkflowContext(
            destination: playlistDestination,
            kind: playlistKind,
            definition: playlistDefinition,
            query: query,
            selectedItemIDs: manualItemList.selectedItemIDs,
            isActive: isActive
        )
    }

    private lazy var workflow: PlaylistPageWorkflow = {
        let workflow = PlaylistPageWorkflow(
            databaseProvider: { [weak self] in self?.databaseProvider?() },
            contextProvider: { [weak self] in self?.workflowContext ?? .empty }
        )
        workflow.onError = { [weak self] error in self?.onError?(error) }
        workflow.onPlaylistMutation = { [weak self] in self?.onPlaylistMutation?() }
        workflow.onSelectDestination = { [weak self] destination in self?.onSelectDestination?(destination) }
        workflow.onPlaylistDeleted = { [weak self] id in self?.onPlaylistDeleted?(id) }
        workflow.onRefresh = { [weak self] in self?.refresh() }
        workflow.onStateChanged = { [weak self] in
            self?.cancelPlaybackLoading()
        }
        return workflow
    }()

    var databaseProvider: (() -> LibraryDatabase?)?
    var onPlayPlaylist: ((PlaybackQueue) -> Void)?
    var onPlaybackIntent: (() -> Void)?
    var onError: ((Error) -> Void)?

    var onPlaylistMutation: (() -> Void)?
    var onSelectDestination: ((PlaylistDestination) -> Void)?
    var onPlaylistDeleted: ((Int64) -> Void)?
    var onToggleFavorite: (([Track]) -> Void)?
    var onManageSkipSegments: ((Track) -> Void)?
    var playlistDestination: PlaylistDestination = .system(.recentlyAdded)

    private let titleLabel = NSTextField(labelWithString: "Playlists")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let playButton = NSButton(title: "Play", target: nil, action: nil)
    private let createButton = NSButton(title: "New", target: nil, action: nil)
    private let renameButton = NSButton(title: "Rename", target: nil, action: nil)
    private let editSmartButton = NSButton(title: "Edit Rules…", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let clearUnavailableButton = NSButton(title: "Clear Unavailable", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove Selected", target: nil, action: nil)
    private let lyricsFilterControl = LyricsPlaylistFilterControl(frame: .zero)
    private let liveSongList = SongListViewController()
    private let manualItemList = PlaylistItemListViewController()

    var page: LibraryPage { .playlists }

    var selectedTrack: Track? {
        switch loadedContent {
        case .manual: return manualItemList.selectedTrack
        case .tracks: return liveSongList.selectedTrack
        case nil: return nil
        }
    }

    var tracks: [Track] { loadedContent?.tracks ?? [] }

    override func loadView() {
        configureView()
    }

    func select(destination: PlaylistDestination) {
        guard playlistDestination != destination else { return }
        loadCoordinator.cancel()
        playbackLoadCoordinator.cancel()
        workflow.resetPendingRefresh()
        workflow.cancel()
        playlistDestination = destination
        loadedContent = nil
        playlistKind = nil
        playlistDefinition = nil
        if isViewLoaded {
            clearRenderedContent()
            updateControls()
        }
    }

    func setQuery(_ query: String) {
        self.query = query
    }

    func updateQuery(_ query: String) {
        guard self.query != query else { return }
        self.query = query
        refresh()
    }

    func activate() {
        isActive = true
        liveSongList.activate()
        manualItemList.activate()
        workflow.activate()
        updateControls()
    }

    func deactivate() {
        isActive = false
        cancelLoading()
        workflow.cancel()
        liveSongList.deactivate()
        manualItemList.deactivate()
        loadedContent = nil
        playlistKind = nil
        playlistDefinition = nil
        clearRenderedContent()
    }

    func cancelPlaybackLoading() {
        playbackLoadCoordinator.cancel()
        updateControls()
    }

    func cancelLoading() {
        loadCoordinator.cancel()
        cancelPlaybackLoading()
    }

    func refresh() {
        loadCoordinator.cancel()
        playbackLoadCoordinator.cancel()
        loadedContent = nil
        playlistKind = nil
        playlistDefinition = nil
        clearRenderedContent()
        updateControls()
        guard let database = databaseProvider?() else { return }
        startLoad(
            database: database,
            offset: 0,
            replacing: true
        )
    }

    private var query = ""

    private func startLoad(database: LibraryDatabase, offset: Int, replacing: Bool) {
        let request = PlaylistPageLoadRequest(
            selection: PlaylistRequestSelection.from(playlistDestination, filter: lyricsFilterControl.filter),
            query: query,
            limit: Self.pageSize,
            offset: offset
        )
        loadCoordinator.start(
            database: database,
            request: request,
            onSuccess: { [weak self] result in
                guard let self, result.destination == self.playlistDestination else { return }
                self.apply(result, replacing: replacing)
            },
            onFailure: { [weak self] request, error in
                guard let self, request.destination == self.playlistDestination else { return }
                if replacing {
                    self.clearRenderedContent()
                    self.loadedContent = nil
                    self.playlistKind = nil
                    self.playlistDefinition = nil
                    self.updateControls()
                }
                self.onError?(error)
            }
        )
    }

    private func loadMore() {
        guard isActive,
              !loadCoordinator.isLoading,
              !workflow.isRunning,
              let database = databaseProvider?(),
              let loadedContent,
              loadedContent.hasMore else { return }
        startLoad(database: database, offset: loadedContent.count, replacing: false)
    }

    private var playbackSource: ListeningPlaybackSource {
        switch playlistDestination {
        case let .system(kind):
            return ListeningPlaybackSource(
                kind: .playlist,
                persistentID: kind.playbackPersistentID,
                sourceName: kind.displayName
            )
        case let .user(id):
            return ListeningPlaybackSource(
                kind: .playlist,
                persistentID: id,
                sourceName: titleLabel.stringValue
            )
        }
    }

    private func startPlaylistPlayback(startingAt start: PlaylistPlaybackStart = .beginning) {
        guard isActive,
              !workflow.isRunning,
              loadedContent != nil,
              let database = databaseProvider?() else { return }

        let pageQuery = query
        let trimmedQuery = pageQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let playbackQuery: String
        if trimmedQuery.isEmpty || start != .beginning {
            playbackQuery = trimmedQuery.isEmpty ? "" : pageQuery
        } else {
            let alert = NSAlert()
            alert.messageText = "Play Playlist"
            alert.informativeText = "Play the filtered results or the entire playlist?"
            alert.addButton(withTitle: "Play Filtered")
            alert.addButton(withTitle: "Play Entire Playlist")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                playbackQuery = pageQuery
            case .alertSecondButtonReturn:
                playbackQuery = ""
            default:
                return
            }
        }

        let request = PlaylistPlaybackLoadRequest(
            selection: PlaylistRequestSelection.from(playlistDestination, filter: lyricsFilterControl.filter),
            query: playbackQuery,
            source: playbackSource,
            startingAt: start
        )
        onPlaybackIntent?()
        playbackLoadCoordinator.start(
            database: database,
            request: request,
            onSuccess: { [weak self] queue in
                guard let self,
                      self.isActive,
                      self.playlistDestination == request.destination,
                      self.query == pageQuery else { return }
                self.updateControls()
                self.onPlayPlaylist?(queue)
            },
            onFailure: { [weak self] _, error in
                guard let self,
                      self.isActive,
                      self.playlistDestination == request.destination,
                      self.query == pageQuery else { return }
                self.updateControls()
                self.onError?(error)
            }
        )
        updateControls()
    }

    private var mutationsAllowed: Bool {
        !workflow.isRunning
    }

    private var reorderAllowed: Bool {
        mutationsAllowed
            && playlistKind == .manual
            && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && loadedContent?.hasMore == false
    }

    private func renderContent() {
        switch loadedContent {
        case let .manual(items, hasMore, totalCount):
            liveSongList.view.isHidden = true
            manualItemList.view.isHidden = false
            liveSongList.setTracks([], hasMore: false)
            manualItemList.setItems(
                items,
                hasMore: hasMore,
                canReorder: reorderAllowed
            )
            let unavailableCount = items.reduce(into: 0) { count, item in
                if !item.isAvailable { count += 1 }
            }
            subtitleLabel.stringValue = "\(totalCount) items"
            if !hasMore, totalCount == items.count, unavailableCount > 0 {
                subtitleLabel.stringValue += " • \(unavailableCount) unavailable"
            }
        case let .tracks(items, hasMore, totalCount):
            liveSongList.view.isHidden = false
            manualItemList.view.isHidden = true
            manualItemList.clear()
            liveSongList.setTracks(items, hasMore: hasMore)
            subtitleLabel.stringValue = "\(totalCount) tracks"
        case nil:
            clearRenderedContent()
            subtitleLabel.stringValue = ""
        }
    }

    private func clearRenderedContent() {
        liveSongList.view.isHidden = true
        manualItemList.view.isHidden = true
        liveSongList.setTracks([], hasMore: false)
        manualItemList.clear()
    }

    private func updateControls() {
        let isManual = playlistKind == .manual
        let isSmart = playlistKind == .smart
        let isUser = playlistDestination.isUser
        createButton.isHidden = false
        renameButton.isHidden = !isUser
        editSmartButton.isHidden = !isSmart
        deleteButton.isHidden = !isUser
        clearUnavailableButton.isHidden = !isManual
        removeButton.isHidden = !isManual
        lyricsFilterControl.show(for: playlistDestination)
        playButton.isEnabled = loadedContent != nil
            && !workflow.isRunning
            && !playbackLoadCoordinator.isLoading
        let canMutate = mutationsAllowed
        for button in [
            createButton, renameButton, editSmartButton, deleteButton, clearUnavailableButton, removeButton
        ] {
            button.isEnabled = canMutate
        }
        manualItemList.setCanReorder(reorderAllowed)
    }

    @objc private func createClicked() {
        workflow.create()
    }

    @objc private func renameClicked() {
        workflow.renameCurrent()
    }

    func beginRename(playlistID id: Int64) {
        workflow.rename(playlistID: id)
    }

    @objc private func editSmartClicked() {
        workflow.editSmart()
    }

    @objc private func deleteClicked() {
        workflow.deleteCurrent()
    }

    func beginDelete(playlistID id: Int64) {
        workflow.delete(playlistID: id)
    }

    @objc private func clearUnavailableClicked() {
        workflow.clearUnavailable()
    }

    @objc private func removeClicked() {
        workflow.removeSelected()
    }

    private func reorderItem(_ itemID: Int64, to ordinal: Int) {
        workflow.reorder(itemID: itemID, to: ordinal)
    }

    @objc private func playClicked() {
        startPlaylistPlayback()
    }

}

private extension PlaylistPageViewController {

    func configureView() {
        let root = ThemeBackgroundView()
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = AppTheme.primaryText
        subtitleLabel.textColor = AppTheme.secondaryText
        for button in [
            playButton, createButton, renameButton, editSmartButton, deleteButton,
            clearUnavailableButton, removeButton
        ] {
            button.bezelStyle = .rounded
            button.target = self
        }
        playButton.action = #selector(playClicked)
        createButton.action = #selector(createClicked)
        renameButton.action = #selector(renameClicked)
        editSmartButton.action = #selector(editSmartClicked)
        deleteButton.action = #selector(deleteClicked)
        clearUnavailableButton.action = #selector(clearUnavailableClicked)
        removeButton.action = #selector(removeClicked)
        lyricsFilterControl.onFilterChange = { [weak self] in self?.refresh() }

        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3
        let header = NSStackView(
            views: [
                titleStack, lyricsFilterControl, playButton, createButton, renameButton, editSmartButton, deleteButton,
                clearUnavailableButton, removeButton
            ]
        )
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        configureListCallbacks()

        liveSongList.view.translatesAutoresizingMaskIntoConstraints = false
        manualItemList.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(liveSongList.view)
        root.addSubview(manualItemList.view)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            liveSongList.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            liveSongList.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            liveSongList.view.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            liveSongList.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            manualItemList.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            manualItemList.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            manualItemList.view.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            manualItemList.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
        updateControls()
        renderContent()
    }
    func configureListCallbacks() {
        liveSongList.onPlay = { [weak self] track in
            self?.startPlaylistPlayback(startingAt: .track(track))
        }
        liveSongList.onRequestMore = { [weak self] in self?.loadMore() }
        liveSongList.onToggleFavorite = { [weak self] tracks in self?.onToggleFavorite?(tracks) }
        liveSongList.onManageSkipSegments = { [weak self] track in self?.onManageSkipSegments?(track) }
        manualItemList.onPlay = { [weak self] item in
            guard let self else { return }
            do {
                let start = try PlaylistPlaybackSelection.start(for: item, in: self.manualItemList.items)
                self.startPlaylistPlayback(startingAt: start)
            } catch {
                self.onError?(error)
            }
        }
        manualItemList.onRequestMore = { [weak self] in self?.loadMore() }
        manualItemList.onToggleFavorite = { [weak self] tracks in self?.onToggleFavorite?(tracks) }
        manualItemList.onRemove = { [weak self] _ in self?.workflow.removeSelected() }
        manualItemList.onReorder = { [weak self] itemID, ordinal in
            self?.workflow.reorder(itemID: itemID, to: ordinal)
        }
    }

    private func apply(_ result: PlaylistPageLoadResult, replacing: Bool) {
        titleLabel.stringValue = result.title
        playlistKind = result.kind
        playlistDefinition = result.definition
        let update = PlaylistPageLoadedContent.applying(
            result.content,
            to: loadedContent,
            replacing: replacing
        )
        loadedContent = update.content
        if update.reachedItemLimit {
            onError?(PlaylistPageLimitError.itemLimitReached)
        }
        updateControls()
        renderContent()
    }
}
