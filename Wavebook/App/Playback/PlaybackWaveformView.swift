import AppKit
import WavebookCore

private final class WaveformTaskLifetime {
    var task: Task<Void, Never>?

    deinit {
        task?.cancel()
    }
}

final class PlaybackWaveformView: ThemeAwareView {
    var onSeek: ((TimeInterval) -> Void)?
    var onZoomChanged: ((Double) -> Void)?
    var onSegmentHandleChanged: ((AudioSkipSegment) -> Void)?
    var onSegmentHandleChangeEnded: ((AudioSkipSegment) -> Void)?

    private let horizontalInset: CGFloat = 10
    private let verticalInset: CGFloat = 20
    private var viewport = PlaybackWaveformViewport()
    private var duration: TimeInterval { viewport.duration }
    private var viewportStart: TimeInterval { viewport.start }
    private var viewportEnd: TimeInterval { viewport.end }
    private var visibleDuration: TimeInterval { viewport.visibleDuration }
    private var elapsed: TimeInterval = 0
    private var peaks: [Float] = []
    private var skipSegments: [AudioSkipSegment] = []
    private var draftStart: TimeInterval?
    private var draftEnd: TimeInterval?
    private var isScrubbing = false
    private var magnificationStartZoom = 1.0
    private var activeSegmentHandle: PlaybackWaveformSegmentHandle?
    private var isLoading = false
    private var loadFailed = false
    private var waveformGeneration = UUID()
    private let waveformTask = WaveformTaskLifetime()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppTheme.cgColor(AppTheme.raised, in: self)
        layer?.cornerRadius = 8
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Playback Waveform")
        setAccessibilityHelp(
            "Click or drag to seek. Use arrow keys to seek in five-second steps. "
                + "Scroll when zoomed to pan."
        )
        addGestureRecognizer(NSMagnificationGestureRecognizer(target: self, action: #selector(magnify(_:))))
        updateAccessibilityValue()
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

    override var acceptsFirstResponder: Bool { duration > 0 }

    func set(duration: TimeInterval, elapsed: TimeInterval, skipSegments: [AudioSkipSegment]) {
        viewport.setDuration(duration)
        self.elapsed = Self.clamp(elapsed, to: viewport.duration)
        self.skipSegments = skipSegments
        updateAccessibilityValue()
        needsDisplay = true
    }

    func setElapsed(_ elapsed: TimeInterval) {
        self.elapsed = Self.clamp(elapsed, to: duration)
        updateAccessibilityValue()
        needsDisplay = true
    }
    func setDraftSegment(start: TimeInterval?, end: TimeInterval?) {
        draftStart = start.flatMap { $0.isFinite ? Self.clamp($0, to: duration) : nil }
        draftEnd = end.flatMap { $0.isFinite ? Self.clamp($0, to: duration) : nil }
        needsDisplay = true
    }

    func zoomIn() {
        setZoomScale(min(viewport.zoomScale * 2, PlaybackWaveformViewport.maximumZoomScale), centeredAt: elapsed)
    }

    func zoomOut() {
        setZoomScale(max(viewport.zoomScale / 2, 1), centeredAt: elapsed)
    }

    func resetZoom() {
        guard viewport.resetZoom() else { return }
        onZoomChanged?(viewport.zoomScale)
        needsDisplay = true
    }

    func load(from url: URL) {
        waveformTask.task?.cancel()
        resetZoom()
        draftStart = nil
        draftEnd = nil
        let generation = UUID()
        waveformGeneration = generation
        peaks = []
        isLoading = true
        loadFailed = false
        needsDisplay = true

        waveformTask.task = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                try PlaybackWaveformLoader.load(from: url, shouldCancel: { Task.isCancelled })
            }
            do {
                let peaks = try await withTaskCancellationHandler(
                    operation: { try await worker.value },
                    onCancel: { worker.cancel() }
                )
                guard !Task.isCancelled else { return }
                self?.finishWaveformLoad(peaks, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.failWaveformLoad(generation: generation)
            }
        }
    }

    func cancelLoading() {
        waveformTask.task?.cancel()
        waveformTask.task = nil
        waveformGeneration = UUID()
        isLoading = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let plotRect = bounds.insetBy(dx: horizontalInset, dy: verticalInset)
        guard plotRect.width > 0, plotRect.height > 0 else { return }
        PlaybackWaveformRenderer.draw(
            in: plotRect,
            peaks: peaks,
            options: PlaybackWaveformDrawOptions(
                duration: duration,
                elapsed: elapsed,
                viewportStart: viewportStart,
                viewportEnd: viewportEnd,
                skipSegments: skipSegments,
                draftStart: draftStart,
                draftEnd: draftEnd,
                activeHandle: activeSegmentHandle,
                isLoading: isLoading,
                loadFailed: loadFailed
            )
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let plotRect = bounds.insetBy(dx: horizontalInset, dy: verticalInset)
        guard plotRect.contains(point) else { return }
        window?.makeFirstResponder(self)
        if let handle = segmentHandle(at: point.x, in: plotRect) {
            activeSegmentHandle = handle
            updateSegmentHandle(at: point.x)
            return
        }
        guard let seconds = time(at: point.x) else { return }
        isScrubbing = true
        seek(to: seconds)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if activeSegmentHandle != nil {
            updateSegmentHandle(at: point.x)
            return
        }
        guard isScrubbing, let seconds = time(at: point.x) else { return }
        seek(to: seconds)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let activeSegmentHandle {
            updateSegmentHandle(at: point.x)
            if let segment = skipSegments.first(where: { $0.id == activeSegmentHandle.id }) {
                onSegmentHandleChangeEnded?(segment)
            }
            self.activeSegmentHandle = nil
            return
        }
        guard isScrubbing else { return }
        if let seconds = time(at: point.x) {
            seek(to: seconds)
        }
        isScrubbing = false
    }

    override func scrollWheel(with event: NSEvent) {
        guard viewport.zoomScale > 1, viewport.duration > 0 else {
            super.scrollWheel(with: event)
            return
        }
        let delta: CGFloat
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            delta = event.scrollingDeltaX
        } else {
            delta = event.scrollingDeltaY
        }
        guard delta != 0 else {
            super.scrollWheel(with: event)
            return
        }
        let plotWidth = max(bounds.width - horizontalInset * 2, 1)
        if viewport.pan(byFraction: -Double(delta) / Double(plotWidth)) {
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        guard handleKeyboardSeek(event) else {
            interpretKeyEvents([event])
            return
        }
    }

    func handleKeyboardSeek(_ event: NSEvent, from position: TimeInterval? = nil) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isDisjoint(with: [.command, .control, .option, .shift]),
              let target = keyboardTarget(for: event, from: position) else { return false }
        seek(to: target)
        return true
    }

    @objc private func magnify(_ recognizer: NSMagnificationGestureRecognizer) {
        switch recognizer.state {
        case .began:
            magnificationStartZoom = viewport.zoomScale
        case .changed, .ended:
            let point = recognizer.location(in: self)
            let focus = time(at: point.x) ?? elapsed
            let scale = min(
                max(magnificationStartZoom * pow(2, Double(recognizer.magnification)), 1),
                PlaybackWaveformViewport.maximumZoomScale
            )
            setZoomScale(scale, centeredAt: focus)
        default:
            break
        }
    }

    private func finishWaveformLoad(_ peaks: [Float], generation: UUID) {
        guard waveformGeneration == generation else { return }
        waveformTask.task = nil
        self.peaks = peaks
        isLoading = false
        loadFailed = peaks.isEmpty
        needsDisplay = true
    }

    private func failWaveformLoad(generation: UUID) {
        guard waveformGeneration == generation else { return }
        waveformTask.task = nil
        peaks = []
        isLoading = false
        loadFailed = true
        needsDisplay = true
    }

    private func segmentHandle(at xPosition: CGFloat, in plotRect: NSRect) -> PlaybackWaveformSegmentHandle? {
        let hitRadius: CGFloat = 8
        for segment in skipSegments {
            guard segment.startTime >= viewportStart, segment.startTime <= viewportEnd else {
                continue
            }
            if abs(xPosition - self.x(for: segment.startTime, in: plotRect)) <= hitRadius {
                return PlaybackWaveformSegmentHandle(id: segment.id, edge: .start)
            }
            if segment.endTime >= viewportStart,
               segment.endTime <= viewportEnd,
               abs(xPosition - self.x(for: segment.endTime, in: plotRect)) <= hitRadius {
                return PlaybackWaveformSegmentHandle(id: segment.id, edge: .end)
            }
        }
        return nil
    }

    private func updateSegmentHandle(at xPosition: CGFloat) {
        guard let activeSegmentHandle,
              let index = skipSegments.firstIndex(where: { $0.id == activeSegmentHandle.id }),
              let seconds = time(at: xPosition) else {
            return
        }
        let current = skipSegments[index]
        let minimumDuration = min(0.01, max(current.duration / 2, 0.000001))
        let previousEnd = index > 0 ? skipSegments[index - 1].endTime : 0
        let nextStart = index + 1 < skipSegments.count ? skipSegments[index + 1].startTime : duration
        let updated: AudioSkipSegment
        switch activeSegmentHandle.edge {
        case .start:
            let latestStart = current.endTime - minimumDuration
            guard latestStart >= previousEnd else { return }
            let start = min(max(seconds, previousEnd), latestStart)
            updated = AudioSkipSegment(id: current.id, startTime: start, endTime: current.endTime)
        case .end:
            let earliestEnd = current.startTime + minimumDuration
            guard earliestEnd <= nextStart else { return }
            let end = max(min(seconds, nextStart), earliestEnd)
            updated = AudioSkipSegment(id: current.id, startTime: current.startTime, endTime: end)
        }
        guard updated != current else { return }
        skipSegments[index] = updated
        needsDisplay = true
        onSegmentHandleChanged?(updated)
    }

    private func time(at xPosition: CGFloat) -> TimeInterval? {
        guard viewport.duration > 0 else { return nil }
        let plotRect = bounds.insetBy(dx: horizontalInset, dy: verticalInset)
        guard plotRect.width > 0 else { return nil }
        let fraction = min(max((xPosition - plotRect.minX) / plotRect.width, 0), 1)
        return viewport.time(at: Double(fraction))
    }

    private func keyboardTarget(for event: NSEvent, from position: TimeInterval? = nil) -> TimeInterval? {
        guard duration > 0 else { return nil }
        let basePosition = Self.clamp(position ?? elapsed, to: duration)
        switch event.specialKey {
        case .leftArrow:
            return max(basePosition - 5, 0)
        case .rightArrow:
            return min(basePosition + 5, duration)
        case .pageUp:
            return max(basePosition - 30, 0)
        case .pageDown:
            return min(basePosition + 30, duration)
        case .home:
            return 0
        case .end:
            return duration
        default:
            return nil
        }
    }

    private func seek(to seconds: TimeInterval) {
        elapsed = Self.clamp(seconds, to: duration)
        ensureVisible(elapsed)
        updateAccessibilityValue()
        needsDisplay = true
        onSeek?(elapsed)
    }

    private func setZoomScale(_ scale: Double, centeredAt focus: TimeInterval) {
        guard viewport.setZoomScale(scale, centeredAt: focus) else { return }
        onZoomChanged?(viewport.zoomScale)
        needsDisplay = true
    }

    private func ensureVisible(_ seconds: TimeInterval) {
        if viewport.ensureVisible(seconds) {
            needsDisplay = true
        }
    }

    private func x(for seconds: TimeInterval, in plotRect: NSRect) -> CGFloat {
        plotRect.minX + plotRect.width * CGFloat(viewport.fraction(for: seconds))
    }

    private func updateAccessibilityValue() {
        setAccessibilityValue(PlaybackTimecode.string(from: elapsed, includingFractionalSeconds: false))
    }

    private static func clamp(_ value: TimeInterval, to duration: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), duration)
    }
}
