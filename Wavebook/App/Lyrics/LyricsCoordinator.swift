import AppKit
import OSLog
import WavebookCore

@MainActor
final class LyricsCoordinator {
    private static let logger = Logger(subsystem: "Wavebook", category: "lyrics")

    private let databaseProvider: () -> LibraryDatabase?
    private let loader: LRCLyricsLoader
    private let downloader: LRCLIBLyricsDownloader

    private var lyricsTask: Task<Void, Never>?
    private var lyricsGeneration: UUID?
    private var downloadTask: Task<Void, Never>?
    private var downloadGeneration: UUID?
    private var currentTrack: Track?
    private var currentLyrics: LRCLyrics?
    private var currentLyricIndex: Int?
    private var currentSkipSegments: [AudioSkipSegment] = []
    private var lyricsStatus = "Lyrics unavailable"
    private var lyricsPanel: LyricsPanelController?
    private var downloadPanel: LyricsDownloadPanelController?
    private weak var windowOwner: NSViewController?

    private(set) var isEnabled = false
    private(set) var preview = LyricsPlaybackPreview.unavailable

    var onStateChanged: (() -> Void)?
    var onLibraryChanged: (() -> Void)?
    var onSeek: ((TimeInterval) -> Void)?
    var playbackPositionProvider: () -> (elapsed: TimeInterval, trackPath: String?) = { (0, nil) }

    init(
        databaseProvider: @escaping () -> LibraryDatabase?,
        loader: LRCLyricsLoader,
        downloader: LRCLIBLyricsDownloader
    ) {
        self.databaseProvider = databaseProvider
        self.loader = loader
        self.downloader = downloader
    }

    deinit {
        lyricsTask?.cancel()
        downloadTask?.cancel()
    }

    func showLyrics(owner: NSViewController) {
        guard let currentTrack else { return }
        windowOwner = owner
        let panel = lyricsPanel ?? LyricsPanelController()
        panel.onSeek = { [weak self] seconds in
            guard let self, self.currentTrack != nil else { return }
            self.onSeek?(seconds)
        }
        panel.onDownload = { [weak self] track in
            self?.showDownloadDialog(for: track)
        }
        panel.set(track: currentTrack, lyrics: currentLyrics, message: lyricsStatus)
        panel.setSkipSegments(currentSkipSegments)
        panel.setCurrentLine(currentLyricIndex)
        panel.setDownloadInProgress(downloadTask != nil)
        lyricsPanel = panel
        panel.showWindow(owner)
        panel.window?.makeKeyAndOrderFront(owner)
    }

    func showDownloadDialog(for track: Track, owner: NSViewController? = nil) {
        if let owner { windowOwner = owner }
        guard let owner = windowOwner else { return }
        guard downloadTask == nil else {
            downloadPanel?.showWindow(owner)
            downloadPanel?.window?.makeKeyAndOrderFront(owner)
            return
        }

        downloadPanel?.onClose = nil
        downloadPanel?.close()
        downloadPanel = nil

        let panel = LyricsDownloadPanelController(track: track, downloader: downloader)
        panel.onDownload = { [weak self, weak panel] track, result in
            guard let panel else { return }
            self?.downloadLyrics(result, for: track, panel: panel)
        }
        panel.onSeek = { [weak self] seconds in
            guard let self, self.playbackPositionProvider().trackPath == track.path else { return }
            self.onSeek?(seconds)
        }
        panel.onClose = { [weak self, weak panel] in
            guard let self, self.downloadPanel === panel else { return }
            self.downloadPanel = nil
        }
        let position = playbackPositionProvider()
        panel.setPlaybackPosition(position.elapsed, trackPath: position.trackPath)
        downloadPanel = panel
        panel.showWindow(owner)
        panel.window?.center()
        panel.window?.makeKeyAndOrderFront(owner)
    }

    func load(for track: Track) {
        lyricsTask?.cancel()
        let generation = UUID()
        lyricsGeneration = generation
        currentTrack = track
        currentLyrics = nil
        currentLyricIndex = nil
        currentSkipSegments = []
        lyricsStatus = "Searching library for lyrics…"
        isEnabled = true
        preview = .loading
        onStateChanged?()
        lyricsPanel?.set(track: track, lyrics: nil, message: lyricsStatus)
        lyricsPanel?.setSkipSegments([])

        let loader = loader
        let database = databaseProvider()
        let audioURL = URL(fileURLWithPath: track.path)
        lyricsTask = Task(priority: .utility) { [weak self] in
            do {
                let lyrics = try await loader.lyrics(for: audioURL, database: database)
                try Task.checkCancellation()
                self?.lyricsLoaded(lyrics, for: track, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                self?.lyricsLoadFailed(error, for: track, generation: generation)
            }
        }
    }

    func update(elapsed: TimeInterval) {
        guard let currentLyrics else { return }
        let panelIndex = currentLyrics.lineIndex(at: elapsed, leadTime: Self.lyricsLeadTime)
        let nextPreview = LyricsPlaybackPreview(lyrics: currentLyrics, elapsed: elapsed)
        guard currentLyricIndex != panelIndex || preview != nextPreview else { return }
        currentLyricIndex = panelIndex
        preview = nextPreview
        lyricsPanel?.setCurrentLine(panelIndex)
    }

    func setPlaybackPosition(_ elapsed: TimeInterval) {
        downloadPanel?.setPlaybackPosition(elapsed, trackPath: currentTrack?.path)
    }

    func setSkipSegments(_ segments: [AudioSkipSegment]) {
        currentSkipSegments = segments
        lyricsPanel?.setSkipSegments(segments)
    }

    func applyDownloadedLyrics(_ lyrics: LRCLyrics, for track: Track) {
        guard currentTrack?.path == track.path else { return }
        lyricsTask?.cancel()
        lyricsTask = nil
        lyricsGeneration = nil
        currentLyrics = lyrics
        currentLyricIndex = nil
        lyricsStatus = ""
        preview = .unavailable
        lyricsPanel?.set(track: track, lyrics: lyrics, message: "")
        update(elapsed: playbackPositionProvider().elapsed)
        onStateChanged?()
    }

    func cancelForPlaybackFailure() {
        cancelLyricsTask()
        cancelDownloadTaskAndPanel()
        lyricsPanel?.close()
        lyricsPanel = nil
        windowOwner = nil
        currentTrack = nil
        currentLyrics = nil
        currentLyricIndex = nil
        currentSkipSegments = []
        lyricsStatus = "Lyrics unavailable"
        isEnabled = false
        preview = .unavailable
        onStateChanged?()
    }

    func cancelForViewDisappearance() {
        cancelLyricsTask()
        cancelDownloadTaskAndPanel()
        lyricsPanel?.setDownloadInProgress(false)
    }

    private func downloadLyrics(
        _ result: LRCLIBLyricsSearchResult,
        for track: Track,
        panel: LyricsDownloadPanelController
    ) {
        guard downloadTask == nil else { return }

        let generation = UUID()
        downloadGeneration = generation
        panel.setDownloadInProgress(true)
        lyricsPanel?.setDownloadInProgress(true)

        let downloader = downloader
        let database = databaseProvider()
        downloadTask = Task(priority: .userInitiated) { [weak self] in
            do {
                let download = try await downloader.downloadLyrics(result, for: track)
                var indexWarning: String?
                do {
                    guard let database else { throw LibraryDatabaseError.inMemoryRequired }
                    try database.registerLyricFile(download.fileURL, forTrackPath: track.path)
                } catch {
                    indexWarning = error.localizedDescription
                    Self.logger.error(
                        """
                        Lyrics saved but indexing failed for \(track.path, privacy: .private): \
                        \(error.localizedDescription, privacy: .public)
                        """
                    )
                }
                self?.downloadSucceeded(
                    download,
                    for: track,
                    panel: panel,
                    generation: generation,
                    indexWarning: indexWarning
                )
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error(
                    """
                    LRCLIB download failed for \(track.path, privacy: .private): \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
                self?.downloadFailed(error, for: track, panel: panel, generation: generation)
            }
        }
    }

    private func downloadSucceeded(
        _ download: LRCLIBLyricsDownload,
        for track: Track,
        panel: LyricsDownloadPanelController,
        generation: UUID,
        indexWarning: String?
    ) {
        guard downloadGeneration == generation else { return }
        downloadTask = nil
        downloadGeneration = nil
        panel.setDownloadInProgress(false)
        lyricsPanel?.setDownloadInProgress(false)
        applyDownloadedLyrics(download.lyrics, for: track)
        onLibraryChanged?()
        if indexWarning != nil {
            panel.showDownloadError("Lyrics saved, but the library index could not be updated")
            return
        }
        panel.close()
    }

    private func downloadFailed(
        _ error: Error,
        for track: Track,
        panel: LyricsDownloadPanelController,
        generation: UUID
    ) {
        guard downloadGeneration == generation else { return }
        downloadTask = nil
        downloadGeneration = nil
        if downloadPanel === panel {
            panel.showDownloadError(error.localizedDescription)
        }
        lyricsPanel?.setDownloadInProgress(false)
        if currentTrack?.path == track.path, currentLyrics == nil {
            lyricsStatus = error.localizedDescription
            lyricsPanel?.set(track: track, lyrics: nil, message: error.localizedDescription)
        }
    }

    private func lyricsLoaded(_ lyrics: LRCLyrics?, for track: Track, generation: UUID) {
        guard lyricsGeneration == generation, currentTrack?.path == track.path else { return }
        lyricsTask = nil
        lyricsGeneration = nil
        currentLyrics = lyrics
        currentLyricIndex = nil

        guard let lyrics else {
            lyricsStatus = "Lyrics not found"
            preview = .unavailable
            onStateChanged?()
            lyricsPanel?.set(track: track, lyrics: nil, message: lyricsStatus)
            return
        }

        lyricsStatus = ""
        preview = .unavailable
        lyricsPanel?.set(track: track, lyrics: lyrics, message: "")
        update(elapsed: playbackPositionProvider().elapsed)
        onStateChanged?()
    }

    private func lyricsLoadFailed(_ error: Error, for track: Track, generation: UUID) {
        guard lyricsGeneration == generation, currentTrack?.path == track.path else { return }
        lyricsTask = nil
        lyricsGeneration = nil
        lyricsStatus = "Could not load lyrics"
        preview = .unavailable
        onStateChanged?()
        Self.logger.error(
            """
            Lyrics load failed for \(track.path, privacy: .private): \
            \(error.localizedDescription, privacy: .public)
            """
        )
        lyricsPanel?.set(track: track, lyrics: nil, message: lyricsStatus)
    }

    private func cancelLyricsTask() {
        lyricsGeneration = nil
        lyricsTask?.cancel()
        lyricsTask = nil
    }

    private func cancelDownloadTaskAndPanel() {
        downloadGeneration = nil
        downloadTask?.cancel()
        downloadTask = nil
        downloadPanel?.onClose = nil
        downloadPanel?.close()
        downloadPanel = nil
    }

    static let lyricsLeadTime: TimeInterval = 0.8
}
