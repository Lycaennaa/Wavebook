import AppKit
import Foundation

enum UIRenderingBenchmark {
    static func sidebar() async throws -> PerformanceRun {
        try await measure(
            scenario: "ui-sidebar-draw",
            description: "Offscreen-rasterize the sidebar, including system and user playlist buttons",
            size: NSSize(width: 280, height: 760),
            snapshots: 12,
            makeTarget: UIRenderingViewFixtures.sidebar
        )
    }

    static func songRows() async throws -> PerformanceRun {
        try await measure(
            scenario: "ui-song-rows-draw",
            description: "Offscreen-rasterize eight production song rows with artwork and queue controls",
            size: NSSize(width: 760, height: 720),
            snapshots: 16,
            makeTarget: UIRenderingViewFixtures.songRows
        )
    }

    static func browseRows() async throws -> PerformanceRun {
        try await measure(
            scenario: "ui-browse-rows-draw",
            description: "Offscreen-rasterize ten production browse rows with artwork and marquee labels",
            size: NSSize(width: 760, height: 720),
            snapshots: 16,
            makeTarget: UIRenderingViewFixtures.browseRows
        )
    }

    static func browseList() async throws -> PerformanceRun {
        try await measure(
            scenario: "ui-browse-list-draw",
            description: "Offscreen-rasterize the production browse collection view and scrolling surface",
            size: NSSize(width: 860, height: 760),
            snapshots: 10,
            makeTarget: UIRenderingViewFixtures.browseList
        )
    }

    static func artistContent() async throws -> PerformanceRun {
        try await measure(
            scenario: "ui-artist-content-draw",
            description: "Offscreen-rasterize the production artist detail collection with populated metadata",
            size: NSSize(width: 860, height: 760),
            snapshots: 10,
            makeTarget: UIRenderingViewFixtures.artistContent
        )
    }

    static func playerBar() async throws -> PerformanceRun {
        try await measure(
            scenario: "ui-player-bar-draw",
            description: "Offscreen-rasterize the playback bar with artwork, sliders, and transport controls",
            size: NSSize(width: 1_180, height: 160),
            snapshots: 20,
            makeTarget: UIRenderingViewFixtures.playerBar
        )
    }

    static func statisticsPage() async throws -> PerformanceRun {
        try await measure(
            scenario: "ui-statistics-page-draw",
            description: "Offscreen-rasterize the statistics page with annual heatmap and ranking rows",
            size: NSSize(width: 1_120, height: 800),
            snapshots: 8,
            makeTarget: UIRenderingViewFixtures.statisticsPage
        )
    }

    static func settingsPanel() async throws -> PerformanceRun {
        try await measure(
            scenario: "ui-settings-panel-draw",
            description: "Offscreen-rasterize settings panel controls and status text",
            size: NSSize(width: 620, height: 900),
            snapshots: 8,
            makeTarget: UIRenderingViewFixtures.settingsPanel
        )
    }

    static func equalizerPanel() async throws -> PerformanceRun {
        try await measure(
            scenario: "ui-equalizer-panel-draw",
            description: "Offscreen-rasterize the 31-band equalizer panel, curve, sliders, and import controls",
            size: NSSize(width: 1_100, height: 740),
            snapshots: 6,
            makeTarget: UIRenderingViewFixtures.equalizerPanel
        )
    }

    static func lyricsPanel() async throws -> PerformanceRun {
        try await measure(
            scenario: "ui-lyrics-panel-draw",
            description: "Offscreen-rasterize the lyrics panel with synchronized attributed text",
            size: NSSize(width: 560, height: 700),
            snapshots: 8,
            makeTarget: UIRenderingViewFixtures.lyricsPanel
        )
    }

    static func lyricsDownloadPanel() async throws -> PerformanceRun {
        try await measure(
            scenario: "ui-lyrics-download-panel-draw",
            description: "Offscreen-rasterize the lyrics search form and preview panel without network activity",
            size: NSSize(width: 680, height: 620),
            snapshots: 8,
            makeTarget: UIRenderingViewFixtures.lyricsDownloadPanel
        )
    }

    static func playlistEditorPanel() async throws -> PerformanceRun {
        try await measure(
            scenario: "ui-playlist-editor-panel-draw",
            description: "Offscreen-rasterize the smart playlist editor and standard form controls",
            size: NSSize(width: 470, height: 470),
            snapshots: 8,
            makeTarget: UIRenderingViewFixtures.playlistEditorPanel
        )
    }

    static func skipSegmentPanel() async throws -> PerformanceRun {
        try await measure(
            scenario: "ui-skip-segment-panel-draw",
            description: "Offscreen-rasterize the skip-segment editor with a populated segment list",
            size: NSSize(width: 900, height: 620),
            snapshots: 8,
            makeTarget: UIRenderingViewFixtures.skipSegmentPanel
        )
    }

    private static func measure(
        scenario: String,
        description: String,
        size: NSSize,
        snapshots: Int,
        makeTarget: @escaping () throws -> UIRenderingTarget
    ) async throws -> PerformanceRun {
        _ = NSApplication.shared.setActivationPolicy(.accessory)
        return try await PerformanceBenchmark.run(
            scenario: scenario,
            workload: PerformanceWorkload(
                description: description,
                operations: snapshots,
                dimensions: [
                    "width": Int(size.width),
                    "height": Int(size.height),
                    "snapshot_count": snapshots,
                    "pixels_per_snapshot": Int(size.width * size.height)
                ]
            ),
            prepare: {
                let target = try makeTarget()
                target.view.setFrameSize(size)
                target.view.layoutSubtreeIfNeeded()
                guard let bitmap = target.view.bitmapImageRepForCachingDisplay(in: target.view.bounds) else {
                    throw PerformanceBenchmarkError.unexpectedResult("Could not allocate AppKit UI snapshot")
                }
                return PerformancePreparedIteration(operation: { [target, bitmap] in
                    for _ in 0..<snapshots {
                        target.view.needsDisplay = true
                        target.view.cacheDisplay(in: target.view.bounds, to: bitmap)
                    }
                    guard bitmap.bitmapData != nil else {
                        throw PerformanceBenchmarkError.unexpectedResult("AppKit UI snapshot returned no bitmap")
                    }
                }, cleanup: { [target] in
                    target.cleanup()
                    withExtendedLifetime(target.retainedObjects) {}
                })
            }
        )
    }
}