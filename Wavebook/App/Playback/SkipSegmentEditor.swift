import AppKit
import WavebookCore

final class SkipSegmentEditor: ThemeAwareView {
    var onSegmentsChanged: (([AudioSkipSegment]) -> Bool)?
    var onSeek: ((TimeInterval) -> Void)?
    var currentPositionProvider: (() -> TimeInterval)? {
        didSet {
            segmentEditing.currentPositionProvider = currentPositionProvider
        }
    }
    var onPlaybackToggle: (() -> Bool)?
    var onVolumeChanged: ((Float) -> Void)?

    private let waveformView = PlaybackWaveformView()
    private let playPauseButton = NSButton(title: "", target: nil, action: nil)
    private let volumeSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let zoomOutButton = NSButton(title: "−", target: nil, action: nil)
    private let zoomResetButton = NSButton(title: "100%", target: nil, action: nil)
    private let zoomInButton = NSButton(title: "+", target: nil, action: nil)
    private let segmentEditing = SkipSegmentEditingController()
    private var isPlaying = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAppearance()
        segmentEditing.setWaveformView(waveformView)
        segmentEditing.currentPositionProvider = { [weak self] in
            self?.currentPositionProvider?() ?? 0
        }
        segmentEditing.onSegmentsChanged = { [weak self] segments in
            self?.onSegmentsChanged?(segments) ?? false
        }
        let title = makeTitle()
        configureWaveform()
        configurePlaybackControls()
        let controls = makeControls(title: title)
        addSubview(controls.stack)
        activateConstraints(stack: controls.stack, header: controls.header)
        themeDidChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func themeDidChange() {
        super.themeDidChange()
        layer?.backgroundColor = AppTheme.cgColor(AppTheme.raised, in: self)
    }

    func set(
        track: Track,
        duration: TimeInterval,
        elapsed: TimeInterval,
        segments: [AudioSkipSegment],
        mode: SkipSegmentEditorMode = .preview
    ) {
        segmentEditing.set(
            track: track,
            duration: Self.safeDuration(duration > 0 ? duration : track.duration),
            elapsed: elapsed,
            segments: segments,
            mode: mode
        )
        applyMode(mode)
    }

    func setMode(_ mode: SkipSegmentEditorMode) {
        segmentEditing.setMode(mode)
        if !mode.canPreview {
            isPlaying = false
        }
        applyMode(mode)
    }

    func setPlaybackPosition(_ position: TimeInterval) {
        segmentEditing.setPlaybackPosition(position)
    }

    func setPlaybackState(_ position: TimeInterval, isPlaying: Bool) {
        self.isPlaying = isPlaying
        segmentEditing.setPlaybackPosition(position)
        updatePlaybackButton()
    }

    func setVolume(_ volume: Float) {
        volumeSlider.doubleValue = min(max(Double(volume), 0), 1)
    }

    func setSegments(_ segments: [AudioSkipSegment]) {
        segmentEditing.setSegments(segments)
    }

    func prepareForClose() {
        waveformView.cancelLoading()
        segmentEditing.prepareForClose()
    }

    private var canPreview: Bool {
        segmentEditing.canPreview
    }
    private func applyMode(_ mode: SkipSegmentEditorMode) {
        volumeSlider.isEnabled = mode.canPreview
        updatePlaybackButton()
    }

    private func currentPosition() -> TimeInterval {
        segmentEditing.currentPosition()
    }
}

extension SkipSegmentEditor {
    private func configureAppearance() {
        wantsLayer = true
        layer?.backgroundColor = AppTheme.cgColor(AppTheme.raised, in: self)
        layer?.cornerRadius = 8
    }

    private func makeTitle() -> NSTextField {
        let title = NSTextField(labelWithString: "Auto-skip segments")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = AppTheme.primaryText
        title.toolTip = "Drag saved waveform handles to adjust ranges. "
            + "Saved source-time ranges are skipped on normal playback."
        return title
    }

    private func configureWaveform() {
        waveformView.onZoomChanged = { [weak self] scale in
            self?.updateZoomButton(scale)
        }
        waveformView.onSeek = { [weak self] seconds in
            guard let self else { return }
            if self.canPreview {
                self.onSeek?(seconds)
            } else {
                self.setPlaybackPosition(seconds)
            }
        }
        waveformView.onSegmentHandleChanged = { [weak self] segment in
            self?.segmentEditing.previewSegmentHandle(segment)
        }
        waveformView.onSegmentHandleChangeEnded = { [weak self] segment in
            self?.segmentEditing.commitSegmentHandle(segment)
        }
        waveformView.toolTip = "Click or drag to scrub; use zoom controls, pinch, or scroll to explore the waveform"
        for button in [zoomOutButton, zoomResetButton, zoomInButton] {
            button.bezelStyle = .rounded
            button.contentTintColor = AppTheme.secondaryText
        }
        zoomOutButton.target = self
        zoomOutButton.action = #selector(zoomOut)
        zoomOutButton.setAccessibilityLabel("Zoom Out Waveform")
        zoomInButton.target = self
        zoomInButton.action = #selector(zoomIn)
        zoomInButton.setAccessibilityLabel("Zoom In Waveform")
        zoomResetButton.target = self
        zoomResetButton.action = #selector(resetZoom)
        zoomResetButton.setAccessibilityLabel("Reset Waveform Zoom")
        updateZoomButton(1)
        waveformView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configurePlaybackControls() {
        playPauseButton.bezelStyle = .rounded
        playPauseButton.imagePosition = .imageOnly
        playPauseButton.contentTintColor = AppTheme.accent
        playPauseButton.target = self
        playPauseButton.action = #selector(togglePlayback)
        playPauseButton.toolTip = "Play or pause without recording listening history"
        updatePlaybackButton()
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        volumeSlider.controlSize = .small
        volumeSlider.isContinuous = true
        volumeSlider.setAccessibilityLabel("Segment Preview Volume")
        volumeSlider.toolTip = "Adjust playback volume"
        volumeSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
    }

    private func makeControls(title: NSTextField) -> (stack: NSStackView, header: NSStackView) {
        let volumeLabel = NSTextField(labelWithString: "Volume")
        volumeLabel.textColor = AppTheme.secondaryText
        let volumeControls = NSStackView(views: [volumeLabel, volumeSlider])
        volumeControls.orientation = .horizontal
        volumeControls.alignment = .centerY
        volumeControls.spacing = 5
        let headerSpacer = NSView()
        let header = NSStackView(views: [title, headerSpacer, zoomControls()])
        header.orientation = .horizontal
        header.alignment = .centerY
        let stack = NSStackView(
            views: segmentEditing.contentViews(
                header: header,
                waveform: waveformView,
                playbackButton: playPauseButton,
                volumeControls: volumeControls
            )
        )
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.distribution = .fill
        return (stack, header)
    }

    private func zoomControls() -> NSStackView {
        let controls = NSStackView(views: [zoomOutButton, zoomResetButton, zoomInButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 4
        return controls
    }

    private func activateConstraints(stack: NSStackView, header: NSStackView) {
        segmentEditing.activateConstraints(stack: stack, header: header, parent: self)
    }

    private func updateZoomButton(_ scale: Double) {
        let percentage = Int((scale * 100).rounded())
        zoomResetButton.title = "\(percentage)%"
        zoomResetButton.setAccessibilityValue("\(percentage) percent")
    }

    private func updatePlaybackButton() {
        let symbolName = isPlaying ? "pause.fill" : "play.fill"
        let actionName = isPlaying ? "Pause" : "Play"
        playPauseButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: actionName)
        playPauseButton.setAccessibilityLabel("\(actionName) Segment Preview")
        playPauseButton.isEnabled = canPreview && segmentEditing.hasDuration
    }

    @objc private func zoomOut() {
        waveformView.zoomOut()
    }

    @objc private func zoomIn() {
        waveformView.zoomIn()
    }

    @objc private func resetZoom() {
        waveformView.resetZoom()
    }

    @objc private func togglePlayback() {
        _ = onPlaybackToggle?()
    }

    internal func handleKeyboardShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isDisjoint(with: [.command, .control, .option, .shift]) else { return false }

        if event.keyCode == 49 {
            guard segmentEditing.hasDuration, canPreview, onPlaybackToggle != nil else { return false }
            if !event.isARepeat {
                togglePlayback()
            }
            return true
        }

        guard segmentEditing.hasDuration,
              !canPreview || onSeek != nil,
              event.specialKey == .leftArrow || event.specialKey == .rightArrow else {
            return false
        }
        return waveformView.handleKeyboardSeek(event, from: segmentEditing.currentPosition())
    }

    @objc private func volumeChanged() {
        onVolumeChanged?(Float(volumeSlider.doubleValue))
    }

    private static func safeDuration(_ value: TimeInterval) -> TimeInterval {
        value.isFinite && value > 0 ? value : 0
    }

}
