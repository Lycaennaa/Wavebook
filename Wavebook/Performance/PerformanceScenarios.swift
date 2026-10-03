import Foundation

enum PerformanceScenarios {
    private enum Name: String, CaseIterable {
        case libraryScan = "library-scan"
        case libraryScanMedium = "library-scan-medium"
        case libraryScanLarge = "library-scan-large"
        case libraryRescanLarge = "library-rescan-large"
        case libraryOneChangeLarge = "library-one-change-large"
        case metadataRead = "metadata-read"
        case artworkEmbedded = "artwork-embedded"
        case artworkSidecar = "artwork-sidecar"
        case artworkCacheFingerprint = "artwork-cache-fingerprint"
        case artworkDecode = "artwork-decode"
        case lyricsParse = "lyrics-parse"
        case lyricsSidecar = "lyrics-sidecar"
        case lyricsTimeline = "lyrics-timeline"
        case replayGainMeasure = "replaygain-measure"
        case replayGainAlbumMeasure = "replaygain-album-measure"
        case waveformPeaks = "waveform-peaks"
        case waveformDiskLoad = "waveform-disk-load"
        case waveformRepeatedLoad = "waveform-repeated-load"
        case waveformDraw = "waveform-draw"
        case catalogQuery = "catalog-query"
        case catalogTrackSearch = "catalog-track-search"
        case catalogArtistPage = "catalog-artist-page"
        case catalogAlbumPage = "catalog-album-page"
        case catalogGenrePage = "catalog-genre-page"
        case playbackQueue = "playback-queue"
        case playbackQueueShuffledNavigation = "playback-queue-shuffled-navigation"
        case equalizerProfileImport = "equalizer-profile-import"
        case equalizerApply = "equalizer-apply"
        case equalizerRenderActive = "equalizer-render-active"
        case equalizerRenderBypassed = "equalizer-render-bypassed"
        case uiSidebarDraw = "ui-sidebar-draw"
        case uiSongRowsDraw = "ui-song-rows-draw"
        case uiBrowseRowsDraw = "ui-browse-rows-draw"
        case uiBrowseListDraw = "ui-browse-list-draw"
        case uiArtistContentDraw = "ui-artist-content-draw"
        case uiPlayerBarDraw = "ui-player-bar-draw"
        case uiStatisticsPageDraw = "ui-statistics-page-draw"
        case uiSettingsPanelDraw = "ui-settings-panel-draw"
        case uiEqualizerPanelDraw = "ui-equalizer-panel-draw"
        case uiLyricsPanelDraw = "ui-lyrics-panel-draw"
        case uiLyricsDownloadPanelDraw = "ui-lyrics-download-panel-draw"
        case uiPlaylistEditorPanelDraw = "ui-playlist-editor-panel-draw"
        case uiSkipSegmentPanelDraw = "ui-skip-segment-panel-draw"
    }

    static let names = Name.allCases.map(\.rawValue)

    static func run(_ name: String) async throws -> PerformanceRun {
        guard let scenario = Name(rawValue: name) else {
            throw PerformanceBenchmarkError.unexpectedResult("Unknown scenario: \(name)")
        }
        return try await dispatch(scenario)
    }

    private static func dispatch(_ scenario: Name) async throws -> PerformanceRun {
        switch scenario {
        case .libraryScan: try await LibraryScanBenchmark.run()
        case .libraryScanLarge: try await LibraryScanBenchmark.large()
        case .libraryRescanLarge: try await LibraryScanBenchmark.rescanLarge()
        case .libraryOneChangeLarge: try await LibraryScanBenchmark.oneChangeLarge()
        case .libraryScanMedium: try await LibraryScanBenchmark.medium()
        case .metadataRead: try await AudioProcessingBenchmark.metadataRead()
        case .artworkEmbedded: try await ArtworkBenchmark.embeddedRead()
        case .artworkSidecar: try await ArtworkBenchmark.sidecarRead()
        case .artworkCacheFingerprint: try await ArtworkBenchmark.cacheFingerprint()
        case .artworkDecode: try await ArtworkBenchmark.decode()
        case .lyricsParse: try await LyricsBenchmark.parse()
        case .lyricsSidecar: try await LyricsBenchmark.sidecarRead()
        case .lyricsTimeline: try await LyricsBenchmark.timelineLookup()
        case .replayGainMeasure: try await AudioProcessingBenchmark.replayGainMeasure()
        case .replayGainAlbumMeasure: try await AudioProcessingBenchmark.replayGainAlbumMeasure()
        case .equalizerProfileImport: try await AudioProcessingBenchmark.equalizerProfileImport()
        case .equalizerApply: try await AudioProcessingBenchmark.equalizerApply()
        case .equalizerRenderActive: try await EqualizerRenderBenchmark.active()
        case .equalizerRenderBypassed: try await EqualizerRenderBenchmark.bypassed()
        case .waveformPeaks: try await AudioProcessingBenchmark.waveformPeaks()
        case .waveformDiskLoad: try await WaveformLoadBenchmark.singleLoad()
        case .waveformRepeatedLoad: try await WaveformLoadBenchmark.repeatedLoad()
        case .waveformDraw: try await AudioProcessingBenchmark.waveformDraw()
        case .catalogQuery: try await CatalogBenchmark.query()
        case .catalogTrackSearch: try await CatalogBenchmark.trackSearch()
        case .catalogArtistPage: try await CatalogBenchmark.artistPage()
        case .catalogAlbumPage: try await CatalogBenchmark.albumPage()
        case .catalogGenrePage: try await CatalogBenchmark.genrePage()
        case .playbackQueue: try await PlaybackQueueBenchmark.navigation()
        case .playbackQueueShuffledNavigation: try await PlaybackQueueBenchmark.shuffledNavigation()
        case .uiSidebarDraw: try await UIRenderingBenchmark.sidebar()
        case .uiSongRowsDraw: try await UIRenderingBenchmark.songRows()
        case .uiBrowseRowsDraw: try await UIRenderingBenchmark.browseRows()
        case .uiBrowseListDraw: try await UIRenderingBenchmark.browseList()
        case .uiArtistContentDraw: try await UIRenderingBenchmark.artistContent()
        case .uiPlayerBarDraw: try await UIRenderingBenchmark.playerBar()
        case .uiStatisticsPageDraw: try await UIRenderingBenchmark.statisticsPage()
        case .uiSettingsPanelDraw: try await UIRenderingBenchmark.settingsPanel()
        case .uiEqualizerPanelDraw: try await UIRenderingBenchmark.equalizerPanel()
        case .uiLyricsPanelDraw: try await UIRenderingBenchmark.lyricsPanel()
        case .uiLyricsDownloadPanelDraw: try await UIRenderingBenchmark.lyricsDownloadPanel()
        case .uiPlaylistEditorPanelDraw: try await UIRenderingBenchmark.playlistEditorPanel()
        case .uiSkipSegmentPanelDraw: try await UIRenderingBenchmark.skipSegmentPanel()
        }
    }
}