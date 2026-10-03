import AppKit
import WavebookCore

private final class SkipSegmentPanel: NSPanel {
    var onKeyboardShortcut: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown,
              canHandleKeyboardShortcut,
              onKeyboardShortcut?(event) == true else {
            super.sendEvent(event)
            return
        }
    }

    private var canHandleKeyboardShortcut: Bool {
        guard let responder = firstResponder else { return true }
        return !(responder is NSControl || responder is NSTextView || responder is NSScrollView)
    }
}

final class SkipSegmentPanelController: NSWindowController, NSWindowDelegate {
    var onSeek: ((TimeInterval) -> Void)?
    var onSegmentsChanged: (([AudioSkipSegment]) -> Bool)?
    var onPlaybackToggle: (() -> Bool)?
    var onVolumeChanged: ((Float) -> Void)?
    var onPlaybackPreviewEnded: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Auto-skip Segments")
    private let artistLabel = NSTextField(labelWithString: "")
    private let editor = SkipSegmentEditor()

    init() {
        let panel = SkipSegmentPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Auto-skip Segments"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.minSize = NSSize(width: 560, height: 430)
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = makeContentView()
        editor.onSeek = { [weak self] seconds in
            self?.onSeek?(seconds)
        }
        editor.onSegmentsChanged = { [weak self] segments in
            self?.onSegmentsChanged?(segments) ?? false
        }
        editor.onPlaybackToggle = { [weak self] in
            self?.onPlaybackToggle?() ?? false
        }
        editor.onVolumeChanged = { [weak self] volume in
            self?.onVolumeChanged?(volume)
        }
        panel.onKeyboardShortcut = { [weak self] event in
            self?.editor.handleKeyboardShortcut(event) ?? false
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func set(
        track: Track,
        duration: TimeInterval,
        elapsed: TimeInterval,
        segments: [AudioSkipSegment],
        mode: SkipSegmentEditorMode = .preview
    ) {
        titleLabel.stringValue = track.title
        artistLabel.stringValue = track.artistDisplay
        editor.set(
            track: track,
            duration: duration,
            elapsed: elapsed,
            segments: segments,
            mode: mode
        )
    }
    func setMode(_ mode: SkipSegmentEditorMode) {
        editor.setMode(mode)
    }

    func setPlaybackPosition(_ elapsed: TimeInterval) {
        editor.setPlaybackPosition(elapsed)
    }
    func setPlaybackState(_ elapsed: TimeInterval, isPlaying: Bool) {
        editor.setPlaybackState(elapsed, isPlaying: isPlaying)
    }
    func setVolume(_ volume: Float) {
        editor.setVolume(volume)
    }

    func setSegments(_ segments: [AudioSkipSegment]) {
        editor.setSegments(segments)
    }

    func setCurrentPositionProvider(_ provider: (() -> TimeInterval)?) {
        editor.currentPositionProvider = provider
    }

    private func makeContentView() -> NSView {
        let root = ThemeBackgroundView()

        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = AppTheme.primaryText
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail

        artistLabel.font = .systemFont(ofSize: 14, weight: .medium)
        artistLabel.textColor = AppTheme.secondaryText
        artistLabel.alignment = .center
        artistLabel.lineBreakMode = .byTruncatingTail

        let header = NSStackView(views: [titleLabel, artistLabel])
        header.orientation = .vertical
        header.spacing = 5
        header.alignment = .width

        let stack = NSStackView(views: [header, editor])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.alignment = .leading
        stack.distribution = .fill
        header.translatesAutoresizingMaskIntoConstraints = false
        editor.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            editor.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return root
    }
    func windowWillClose(_ notification: Notification) {
        editor.prepareForClose()
        onPlaybackPreviewEnded?()
    }
}
