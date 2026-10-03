import AppKit
import Foundation
import WavebookCore

struct UIRenderingTarget {
    let view: NSView
    let retainedObjects: [AnyObject]
    let cleanup: () -> Void

    init(view: NSView, retainedObjects: [AnyObject] = [], cleanup: @escaping () -> Void = {}) {
        self.view = view
        self.retainedObjects = retainedObjects
        self.cleanup = cleanup
    }
}

enum UIRenderingViewFixtures {
    static func sidebar() -> UIRenderingTarget {
        let controller = SidebarViewController()
        let view = controller.view
        let playlists = (0..<8).map { index in
            Playlist(
                id: Int64(index + 1),
                name: "Performance Playlist \(index + 1)",
                createdAtUTC: Date(timeIntervalSince1970: TimeInterval(index)),
                definition: .manual
            )
        }
        controller.setPlaylists(playlists)
        controller.select(.artists)
        return UIRenderingTarget(view: view, retainedObjects: [controller])
    }

    static func songRows() -> UIRenderingTarget {
        let size = NSSize(width: 760, height: 720)
        let root = ThemeBackgroundView(frame: NSRect(origin: .zero, size: size))
        let cover = artwork()
        let items = (0..<8).map { index -> SongItem in
            let item = SongItem(nibName: nil, bundle: nil)
            item.configure(with: track(index), artwork: cover)
            item.configureQueueState(isCurrent: index == 0, isPrevious: index == 1, onPlay: {})
            item.isSelected = index == 3
            item.view.frame = NSRect(x: 12, y: CGFloat(index * 88 + 10), width: 736, height: 80)
            root.addSubview(item.view)
            return item
        }
        root.layoutSubtreeIfNeeded()
        return UIRenderingTarget(view: root, retainedObjects: items)
    }

    static func browseRows() -> UIRenderingTarget {
        let size = NSSize(width: 760, height: 720)
        let root = ThemeBackgroundView(frame: NSRect(origin: .zero, size: size))
        let cover = artwork()
        let items = (0..<10).map { index -> BrowseItem in
            let item = BrowseItem(nibName: nil, bundle: nil)
            let entry = BrowseListViewController.Entry(
                title: "Album \(index + 1) — A Deliberately Long Display Title",
                subtitle: "Artist \(index + 1) · 12 tracks",
                artworkTrackPath: "benchmark-artwork-\(index)"
            )
            item.configure(with: entry, artwork: cover)
            item.isSelected = index == 4
            item.view.frame = NSRect(x: 12, y: CGFloat(index * 68 + 12), width: 736, height: 56)
            root.addSubview(item.view)
            return item
        }
        root.layoutSubtreeIfNeeded()
        return UIRenderingTarget(view: root, retainedObjects: items)
    }

    static func browseList() -> UIRenderingTarget {
        let controller = BrowseListViewController()
        let view = controller.view
        let entries = (0..<80).map { index in
            BrowseListViewController.Entry(
                title: "Browse item \(index + 1)",
                subtitle: "Artist \(index % 17) · Album \(index % 31)",
                artworkTrackPath: nil
            )
        }
        controller.setEntries(entries, selectedIndex: 17)
        return UIRenderingTarget(view: view, retainedObjects: [controller])
    }

    static func artistContent() -> UIRenderingTarget {
        let view = ArtistContentListView(frame: NSRect(x: 0, y: 0, width: 860, height: 760))
        let detail = LibraryArtistDetail(
            ownedAlbums: [],
            appearingAlbums: [],
            genres: (0..<12).map { "Genre \($0 + 1)" }
        )
        view.setContent(detail: detail, tracks: [])
        return UIRenderingTarget(view: view, retainedObjects: [view])
    }

    static func playerBar() -> UIRenderingTarget {
        let view = PlayerBarView(frame: NSRect(x: 0, y: 0, width: 1_180, height: 160))
        view.set(track: track(0), artwork: artwork(), duration: 246, isPlaying: true)
        view.setProgress(elapsed: 94, duration: 246)
        view.setVolume(0.72)
        view.setShuffleEnabled(true)
        view.setEqualizerEnabled(true)
        view.setLyricsEnabled(true)
        return UIRenderingTarget(view: view, retainedObjects: [view])
    }

    static func statisticsPage() -> UIRenderingTarget {
        let year = 2024
        let days = heatmapDays(year: year)
        let summary = ListeningStatisticsSummary(
            qualifiedPlayCount: 482,
            listenedSeconds: 92_340,
            uniqueSongCount: 267,
            uniqueArtistCount: 83,
            skipCount: 41
        )
        let rankings = Dictionary(uniqueKeysWithValues: ListeningStatisticsDimension.allCases.map { dimension in
            (dimension, (0..<10).map { index in
                ListeningRankingEntry(
                    id: "\(dimension.rawValue)-\(index)",
                    dimension: dimension,
                    displayName: "\(dimension.rawValue.capitalized) \(index + 1)",
                    qualifiedPlayCount: 90 - index,
                    listenedSeconds: Double(3_600 * (10 - index))
                )
            })
        })
        let skippedSongs = (0..<10).map { index in
            ListeningSkippedSong(
                snapshotID: Int64(index + 1),
                title: "Skipped track \(index + 1)",
                artistDisplay: "Artist \(index + 1)",
                albumTitle: "Album \(index + 1)",
                skipCount: 25 - index
            )
        }
        let snapshot = StatisticsYearSnapshot(
            year: year,
            summary: summary,
            lifetime: summary,
            heatmap: days,
            rankings: rankings,
            skippedSongs: skippedSongs
        )
        let controller = StatisticsPageViewController()
        controller.statisticsModel = StatisticsPageModel(displayedYear: year)
        controller.statisticsModel.setYearSnapshot(snapshot)
        let view = controller.view
        controller.yearLabel.stringValue = String(year)
        controller.updateSummaryRows(snapshot)
        for dimension in ListeningStatisticsDimension.allCases {
            controller.updateRankingSection(dimension: dimension, entries: rankings[dimension] ?? [])
        }
        controller.updateSkippedSection(skippedSongs)
        controller.heatmapView.reload(days: days, selectedDay: nil)
        controller.refreshStatusOnly()
        return UIRenderingTarget(view: view, retainedObjects: [controller])
    }

    static func settingsPanel() throws -> UIRenderingTarget {
        let controller = SettingsPanelController()
        controller.set(devices: [], selectedUID: nil, hiddenUIDs: [])
        controller.setSkipSilentSegments(true)
        controller.setReplayGainAnalysisFileConcurrency(4)
        return try windowTarget(controller)
    }

    static func equalizerPanel() throws -> UIRenderingTarget {
        let profile = EqualizerProfile(
            isBypassed: false,
            bandGains: EqualizerProfile.frequencies.indices.map { index in
                index.isMultiple(of: 2) ? 4 : -4
            }
        )
        let controller = EqualizerPanelController(profile: profile, outputDeviceName: "Benchmark Output")
        return try windowTarget(controller)
    }

    static func lyricsPanel() throws -> UIRenderingTarget {
        let controller = LyricsPanelController()
        let lyrics = LRCLyrics(lines: (0..<48).map { index in
            LRCLyricLine(time: Double(index * 5), text: "Synchronized lyric line \(index + 1) for the rendering fixture")
        })
        controller.set(track: track(0), lyrics: lyrics, message: "")
        controller.setCurrentLine(12)
        return try windowTarget(controller)
    }

    static func lyricsDownloadPanel() throws -> UIRenderingTarget {
        let controller = LyricsDownloadPanelController(track: track(0), downloader: LRCLIBLyricsDownloader())
        controller.showDownloadError("No matching lyrics were found.")
        return try windowTarget(controller)
    }

    static func playlistEditorPanel() throws -> UIRenderingTarget {
        let definition = PlaylistDefinition.smart(
            rulesJSON: "{\"rules\":[]}",
            sortField: .firstSeen,
            sortDescending: true
        )
        let editor = PlaylistEditorView(name: "Performance playlist", definition: definition, allowsKindSelection: true)
        let controller = PlaylistEditorPanelController(title: "Smart Playlist", editor: editor)
        return try windowTarget(controller)
    }

    static func skipSegmentPanel() throws -> UIRenderingTarget {
        let controller = SkipSegmentPanelController()
        let segments = (0..<24).map { index in
            AudioSkipSegment(startTime: Double(index * 8), endTime: Double(index * 8 + 3))
        }
        controller.set(track: track(0), duration: 240, elapsed: 56, segments: segments, mode: .editing)
        controller.setPlaybackState(56, isPlaying: true)
        controller.setVolume(0.68)
        return try windowTarget(controller)
    }

    private static func windowTarget(_ controller: NSWindowController) throws -> UIRenderingTarget {
        guard let window = controller.window, let view = window.contentView else {
            throw PerformanceBenchmarkError.unexpectedResult("Could not create AppKit panel content")
        }
        return UIRenderingTarget(view: view, retainedObjects: [controller], cleanup: { window.close() })
    }

    private static func track(_ index: Int) -> Track {
        Track(
            id: Int64(index + 1),
            path: "benchmark-track-\(index + 1).flac",
            title: "Track \(index + 1) — A Long Title for Truncation and Marquee Rendering",
            artistDisplay: "Artist \(index + 1); Featured Performer",
            albumTitle: "Album \(index + 1) with a Long Display Name",
            albumArtist: "Album Artist \(index + 1)",
            genreDisplay: "Alternative; Electronic",
            duration: 246,
            format: "flac",
            hasLyrics: true,
            firstSeenAtUTC: Date(timeIntervalSince1970: TimeInterval(index)),
            isFavorite: index.isMultiple(of: 2)
        )
    }

    private static func artwork() -> NSImage {
        let size = NSSize(width: 72, height: 72)
        let image = NSImage(size: size)
        image.lockFocus()
        let bounds = NSRect(origin: .zero, size: size)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.24, green: 0.18, blue: 0.54, alpha: 1),
            NSColor(calibratedRed: 0.12, green: 0.58, blue: 0.63, alpha: 1)
        ])?.draw(in: bounds, angle: 45)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let mark = NSBezierPath(ovalIn: bounds.insetBy(dx: 18, dy: 18))
        mark.lineWidth = 4
        mark.stroke()
        image.unlockFocus()
        return image
    }

    private static func heatmapDays(year: Int) -> [ListeningHeatmapDay] {
        var calendar = Calendar(identifier: .gregorian)
        guard let timeZone = TimeZone(secondsFromGMT: 0) else { return [] }
        calendar.timeZone = timeZone
        guard let firstDay = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let dayRange = calendar.range(of: .day, in: .year, for: firstDay) else {
            return []
        }
        return (0..<dayRange.count).compactMap { index in
            guard let date = calendar.date(byAdding: .day, value: index, to: firstDay) else { return nil }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let day = ListeningLocalDay(
                year: components.year ?? 0,
                month: components.month ?? 0,
                day: components.day ?? 0
            ) else {
                return nil
            }
            return ListeningHeatmapDay(day: day, qualifiedPlayCount: index % 10)
        }
    }
}