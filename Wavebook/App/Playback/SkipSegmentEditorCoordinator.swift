import AppKit
import WavebookCore

struct SkipSegmentEditorPresentation {
    let owner: NSViewController
    let track: Track
    let duration: TimeInterval
    let elapsed: TimeInterval
    let isPlaying: Bool
    let volume: Float
    let segments: [AudioSkipSegment]
    let mode: SkipSegmentEditorMode
}
enum SkipSegmentEditorMode {
    case preview
    case editing
    case unavailable

    var canPreview: Bool {
        self == .preview
    }

    var canEdit: Bool {
        self != .unavailable
    }
}

@MainActor
final class SkipSegmentEditorCoordinator {
    private let onSeek: (TimeInterval) -> Void
    private let onSegmentsChanged: (Track, [AudioSkipSegment]) -> Bool
    private let onPlaybackToggle: () -> Bool
    private let onVolumeChanged: (Float) -> Void
    private let onPreviewEnded: () -> Void
    private let currentPositionProvider: () -> TimeInterval
    private var panel: SkipSegmentPanelController?
    private var presentedTrack: Track?
    private var presentedMode: SkipSegmentEditorMode = .unavailable

    init(
        onSeek: @escaping (TimeInterval) -> Void,
        onSegmentsChanged: @escaping (Track, [AudioSkipSegment]) -> Bool,
        onPlaybackToggle: @escaping () -> Bool,
        onVolumeChanged: @escaping (Float) -> Void,
        onPreviewEnded: @escaping () -> Void,
        currentPositionProvider: @escaping () -> TimeInterval
    ) {
        self.onSeek = onSeek
        self.onSegmentsChanged = onSegmentsChanged
        self.onPlaybackToggle = onPlaybackToggle
        self.onVolumeChanged = onVolumeChanged
        self.onPreviewEnded = onPreviewEnded
        self.currentPositionProvider = currentPositionProvider
    }

    var isVisible: Bool {
        panel?.window?.isVisible == true
    }

    func show(_ presentation: SkipSegmentEditorPresentation) {
        let panel = panel ?? makePanel()
        let wasVisible = panel.window?.isVisible == true
        presentedTrack = presentation.track
        presentedMode = presentation.mode
        panel.setCurrentPositionProvider(
            presentedMode.canPreview ? currentPositionProvider : nil
        )
        panel.set(
            track: presentation.track,
            duration: presentation.duration,
            elapsed: presentation.elapsed,
            segments: presentation.segments,
            mode: presentation.mode
        )
        panel.setPlaybackState(presentation.elapsed, isPlaying: presentation.isPlaying)
        panel.setVolume(presentation.volume)
        self.panel = panel
        panel.showWindow(presentation.owner)
        if !wasVisible {
            panel.window?.center()
        }
        panel.window?.makeKeyAndOrderFront(presentation.owner)
    }
    func updatePlaybackTrackIfVisible(
        track: Track,
        duration: TimeInterval,
        elapsed: TimeInterval,
        skipSegmentLoad: Result<[AudioSkipSegment], Error>
    ) {
        guard isVisible else { return }
        guard presentedTrack?.path == track.path else {
            switchToEditingMode()
            return
        }
        switch skipSegmentLoad {
        case .success(let segments):
            presentedTrack = track
            presentedMode = .preview
            panel?.setCurrentPositionProvider(currentPositionProvider)
            panel?.set(
                track: track,
                duration: duration,
                elapsed: elapsed,
                segments: segments,
                mode: .preview
            )
        case .failure:
            markDataUnavailable(for: track)
        }
    }
    func setPlaybackState(_ elapsed: TimeInterval, isPlaying: Bool) {
        guard presentedMode.canPreview else { return }
        panel?.setPlaybackState(elapsed, isPlaying: isPlaying)
    }

    func setVolume(_ volume: Float) {
        panel?.setVolume(volume)
    }

    func close() {
        presentedTrack = nil
        presentedMode = .unavailable
        panel?.close()
    }
    private func switchToEditingMode() {
        guard presentedMode != .unavailable else { return }
        presentedMode = .editing
        panel?.setCurrentPositionProvider(nil)
        panel?.setMode(.editing)
    }

    private func markDataUnavailable(for track: Track) {
        guard presentedTrack?.path == track.path else { return }
        presentedMode = .unavailable
        panel?.setCurrentPositionProvider(nil)
        panel?.setMode(.unavailable)
    }

    private func makePanel() -> SkipSegmentPanelController {
        let panel = SkipSegmentPanelController()
        panel.onSeek = onSeek
        panel.onSegmentsChanged = { [weak self] segments in
            guard let self,
                  self.presentedMode.canEdit,
                  let track = self.presentedTrack else { return false }
            return self.onSegmentsChanged(track, segments)
        }
        panel.onPlaybackToggle = onPlaybackToggle
        panel.onVolumeChanged = onVolumeChanged
        panel.onPlaybackPreviewEnded = { [weak self] in
            guard let self else { return }
            self.presentedTrack = nil
            self.presentedMode = .unavailable
            self.onPreviewEnded()
        }
        return panel
    }
}
