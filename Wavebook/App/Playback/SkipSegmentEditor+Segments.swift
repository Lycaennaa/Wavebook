import AppKit
import WavebookCore

@MainActor
final class SkipSegmentEditingController: NSObject {
    var onSegmentsChanged: (([AudioSkipSegment]) -> Bool)?
    var currentPositionProvider: (() -> TimeInterval)?

    private let positionLabel = NSTextField(labelWithString: "Position 0:00")
    private let startField = NSTextField()
    private let endField = NSTextField()
    private let setStartButton = NSButton(title: "Set Start", target: nil, action: nil)
    private let setEndButton = NSButton(title: "Set End", target: nil, action: nil)
    private let addButton = NSButton(title: "Add Segment", target: nil, action: nil)
    private let statusLabel = NSTextField(
        wrappingLabelWithString: "Orange = saved; yellow/orange lines = start/end; mint = current entry."
    )
    private let rowsView = SkipSegmentRowsView()
    private weak var waveformView: PlaybackWaveformView?
    private var trackPath: String?
    private var segments: [AudioSkipSegment] = []
    private var originalHandleSegment: AudioSkipSegment?
    private var duration: TimeInterval = 0
    private var playbackPosition: TimeInterval = 0
    private var mode: SkipSegmentEditorMode = .preview
    private let timeControls = NSStackView()

    override init() {
        super.init()
        rowsView.onRemove = { [weak self] index in
            self?.removeSegment(at: index)
        }
        configureControls()
        updateRows()
    }

    var canPreview: Bool {
        mode.canPreview
    }
    var hasDuration: Bool {
        duration > 0
    }

    func setWaveformView(_ waveformView: PlaybackWaveformView) {
        self.waveformView = waveformView
        waveformView.translatesAutoresizingMaskIntoConstraints = false
    }

    func contentViews(
        header: NSView,
        waveform: NSView,
        playbackButton: NSView,
        volumeControls: NSView
    ) -> [NSView] {
        let currentControls = NSStackView(
            views: [playbackButton, positionLabel, setStartButton, setEndButton]
        )
        currentControls.orientation = .horizontal
        currentControls.alignment = .centerY
        currentControls.spacing = 8
        return [
            header,
            waveform,
            currentControls,
            volumeControls,
            timeControls,
            statusLabel,
            rowsView.scrollView
        ]
    }

    func activateConstraints(stack: NSStackView, header: NSStackView, parent: NSView) {
        guard let waveformView else { return }
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            waveformView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            waveformView.heightAnchor.constraint(lessThanOrEqualToConstant: 420),
            startField.widthAnchor.constraint(equalToConstant: 78),
            endField.widthAnchor.constraint(equalToConstant: 78),
            stack.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: parent.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -10),
            waveformView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rowsView.scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        rowsView.activateConstraints()
    }

    func set(
        track: Track,
        duration: TimeInterval,
        elapsed: TimeInterval,
        segments: [AudioSkipSegment],
        mode: SkipSegmentEditorMode
    ) {
        let trackChanged = trackPath != track.path
        trackPath = track.path
        self.duration = duration
        playbackPosition = Self.clamp(elapsed, to: duration)
        self.mode = mode
        self.segments = Self.sorted(segments)
        if trackChanged {
            originalHandleSegment = nil
            startField.stringValue = ""
            endField.stringValue = ""
            waveformView?.load(from: URL(fileURLWithPath: track.path))
        }
        updateDraftSegment()
        updateWaveform()
        setPlaybackPosition(playbackPosition)
        updatePreviewAvailabilityMessage()
        updateEditingControls()
        updateRows()
    }

    func setMode(_ mode: SkipSegmentEditorMode) {
        self.mode = mode
        updatePreviewAvailabilityMessage()
        updateEditingControls()
        updateRows()
    }

    func setPlaybackPosition(_ position: TimeInterval) {
        playbackPosition = Self.clamp(position, to: duration)
        let position = PlaybackTimecode.string(from: playbackPosition, includingFractionalSeconds: false)
        positionLabel.stringValue = "Position \(position)"
        waveformView?.setElapsed(playbackPosition)
    }

    func setSegments(_ segments: [AudioSkipSegment]) {
        self.segments = Self.sorted(segments)
        updateWaveform()
        updateRows()
    }

    func prepareForClose() {
        trackPath = nil
        originalHandleSegment = nil
        updateDraftSegment()
    }

    func previewSegmentHandle(_ segment: AudioSkipSegment) {
        guard mode.canEdit else { return }
        if originalHandleSegment == nil {
            originalHandleSegment = segments.first(where: { $0.id == segment.id })
        }
        guard let index = segments.firstIndex(where: { $0.id == segment.id }) else { return }
        segments[index] = segment
        startField.stringValue = PlaybackTimecode.string(from: segment.startTime)
        endField.stringValue = PlaybackTimecode.string(from: segment.endTime)
        statusLabel.stringValue = "Adjusting \(startField.stringValue)–\(endField.stringValue). Release to save."
    }

    func commitSegmentHandle(_ segment: AudioSkipSegment) {
        guard mode.canEdit else { return }
        guard let original = originalHandleSegment else { return }
        originalHandleSegment = nil
        guard segment != original else { return }
        let proposedSegments = Self.sorted(segments)
        guard onSegmentsChanged?(proposedSegments) == true else {
            if let index = segments.firstIndex(where: { $0.id == original.id }) {
                segments[index] = original
            }
            startField.stringValue = ""
            endField.stringValue = ""
            updateDraftSegment()
            statusLabel.stringValue = "Could not save the skip segment change."
            updateWaveform()
            updateRows()
            return
        }
        segments = proposedSegments
        startField.stringValue = ""
        endField.stringValue = ""
        updateDraftSegment()
        let start = PlaybackTimecode.string(from: segment.startTime)
        let end = PlaybackTimecode.string(from: segment.endTime)
        statusLabel.stringValue = "Saved \(start)–\(end)."
        updateWaveform()
        updateRows()
    }

    @objc private func setStart() {
        guard mode.canEdit else { return }
        startField.stringValue = PlaybackTimecode.string(from: currentPosition())
        updateDraftSegment()
        statusLabel.stringValue = "Start set at \(startField.stringValue). Set the end or type one."
    }

    @objc private func setEnd() {
        guard mode.canEdit else { return }
        endField.stringValue = PlaybackTimecode.string(from: currentPosition())
        updateDraftSegment()
        statusLabel.stringValue = "End set at \(endField.stringValue). Add the segment when ready."
    }

    @objc private func addSegment() {
        guard mode.canEdit else { return }
        guard let start = PlaybackTimecode.parse(startField.stringValue) else {
            statusLabel.stringValue = "Enter a valid start time as m:ss, h:mm:ss, or seconds."
            return
        }
        guard let end = PlaybackTimecode.parse(endField.stringValue) else {
            statusLabel.stringValue = "Enter a valid end time as m:ss, h:mm:ss, or seconds."
            return
        }
        guard start < end else {
            statusLabel.stringValue = "End must be after the start time."
            return
        }
        guard duration > 0 else {
            statusLabel.stringValue = "The current track has no usable duration."
            return
        }
        guard start < duration else {
            statusLabel.stringValue = "Start must be before the end of the track."
            return
        }
        guard end <= duration else {
            statusLabel.stringValue = "End must be within the track duration."
            return
        }
        let proposedSegment = AudioSkipSegment(startTime: start, endTime: end)
        guard !segments.contains(where: { existing in
            proposedSegment.startTime < existing.endTime && existing.startTime < proposedSegment.endTime
        }) else {
            statusLabel.stringValue = "This segment overlaps a saved segment."
            return
        }
        let proposedSegments = Self.sorted(segments + [proposedSegment])
        guard onSegmentsChanged?(proposedSegments) == true else {
            statusLabel.stringValue = "Could not save the skip segment."
            return
        }
        segments = proposedSegments
        startField.stringValue = ""
        endField.stringValue = ""
        updateDraftSegment()
        statusLabel.stringValue = "Saved \(PlaybackTimecode.string(from: start))–\(PlaybackTimecode.string(from: end))."
        updateWaveform()
        updateRows()
    }

    private func removeSegment(at index: Int) {
        guard mode.canEdit else { return }
        guard segments.indices.contains(index) else { return }
        var proposedSegments = segments
        proposedSegments.remove(at: index)
        guard onSegmentsChanged?(proposedSegments) == true else {
            statusLabel.stringValue = "Could not remove the skip segment."
            return
        }
        segments = proposedSegments
        statusLabel.stringValue = "Saved segments are skipped during normal playback."
        updateWaveform()
        updateRows()
    }

    private func configureControls() {
        positionLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        positionLabel.textColor = AppTheme.secondaryText
        positionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        for button in [setStartButton, setEndButton, addButton] {
            button.bezelStyle = .rounded
            button.contentTintColor = AppTheme.accent
        }
        setStartButton.target = self
        setStartButton.action = #selector(setStart)
        setStartButton.toolTip = "Copy the current playback position into the start time"
        setStartButton.setAccessibilityLabel("Set Skip Segment Start From Current Position")
        setEndButton.target = self
        setEndButton.action = #selector(setEnd)
        setEndButton.toolTip = "Copy the current playback position into the end time"
        setEndButton.setAccessibilityLabel("Set Skip Segment End From Current Position")
        addButton.target = self
        addButton.action = #selector(addSegment)
        addButton.setAccessibilityLabel("Add Auto-skip Segment")

        configureTimeField(startField, label: "Start")
        configureTimeField(endField, label: "End")
        startField.target = self
        startField.action = #selector(addSegment)
        endField.target = self
        endField.action = #selector(addSegment)
        startField.delegate = self
        endField.delegate = self
        let startControls = timeControls(label: "Start", field: startField)
        let endControls = timeControls(label: "End", field: endField)
        timeControls.orientation = .horizontal
        timeControls.alignment = .centerY
        timeControls.spacing = 8
        timeControls.addArrangedSubview(startControls)
        timeControls.addArrangedSubview(endControls)
        timeControls.addArrangedSubview(addButton)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = AppTheme.secondaryText
        statusLabel.maximumNumberOfLines = 2
        updateEditingControls()
    }

    private func configureTimeField(_ field: NSTextField, label: String) {
        field.placeholderString = "0:00"
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.alignment = .right
        field.toolTip = "Enter m:ss, h:mm:ss, or seconds"
        field.setAccessibilityLabel("Skip Segment \(label) Time")
    }

    private func timeControls(label: String, field: NSTextField) -> NSStackView {
        let label = NSTextField(labelWithString: label)
        label.textColor = AppTheme.secondaryText
        let stack = NSStackView(views: [label, field])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        return stack
    }

    private func updatePreviewAvailabilityMessage() {
        switch mode {
        case .preview:
            statusLabel.stringValue = "Orange = saved; yellow/orange lines = start/end; mint = current entry."
        case .editing:
            statusLabel.stringValue =
                "Preview unavailable while this track is not playing. " +
                "Enter times or drag the waveform."
        case .unavailable:
            statusLabel.stringValue = "Skip segments are unavailable because saved data could not be loaded."
        }
    }

    private func updateEditingControls() {
        let enabled = mode.canEdit
        setStartButton.isEnabled = enabled
        setEndButton.isEnabled = enabled
        startField.isEnabled = enabled
        endField.isEnabled = enabled
        addButton.isEnabled = enabled && duration > 0
    }

    private func updateDraftSegment() {
        waveformView?.setDraftSegment(
            start: PlaybackTimecode.parse(startField.stringValue),
            end: PlaybackTimecode.parse(endField.stringValue)
        )
    }

    private func updateWaveform() {
        waveformView?.set(duration: duration, elapsed: playbackPosition, skipSegments: segments)
    }
    private func updateRows() {
        rowsView.setSegments(segments, canEdit: mode.canEdit)
    }

    func currentPosition() -> TimeInterval {
        guard mode.canPreview, let provider = currentPositionProvider else { return playbackPosition }
        return Self.clamp(provider(), to: duration)
    }

    private static func sorted(_ segments: [AudioSkipSegment]) -> [AudioSkipSegment] {
        segments.sorted { lhs, rhs in
            lhs.startTime == rhs.startTime ? lhs.endTime < rhs.endTime : lhs.startTime < rhs.startTime
        }
    }

    private static func clamp(_ value: TimeInterval, to duration: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), duration)
    }
}

extension SkipSegmentEditingController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard mode.canEdit else { return }
        updateDraftSegment()
    }
}
