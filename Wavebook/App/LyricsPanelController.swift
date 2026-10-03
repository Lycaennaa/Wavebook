import AppKit
import WavebookCore

private final class LyricsScrollView: NSScrollView {
    var onManualScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onManualScroll?()
        super.scrollWheel(with: event)
    }
}
private final class LyricsTextView: NSTextView {
    var onManualScroll: (() -> Void)?

    // macOS virtual key codes for page/home/end, arrow scroll commands, and space.
    private static let manualScrollKeyCodes: Set<UInt16> = [49, 115, 116, 119, 121, 125, 126]
    // Standard text-view commands that can move the lyrics viewport.
    private static let manualScrollCommands: Set<String> = [
        "centerSelectionInVisibleArea:",
        "moveDown:",
        "moveToBeginningOfDocument:",
        "moveToEndOfDocument:",
        "moveUp:",
        "pageDown:",
        "pageUp:",
        "scrollLineDown:",
        "scrollLineUp:",
        "scrollPageDown:",
        "scrollPageUp:",
        "scrollToBeginningOfDocument:",
        "scrollToEndOfDocument:"
    ]

    override func keyDown(with event: NSEvent) {
        let isControlPageDown = event.modifierFlags.contains(.control)
            && event.charactersIgnoringModifiers?.lowercased() == "v"
        if Self.manualScrollKeyCodes.contains(event.keyCode) || isControlPageDown {
            onManualScroll?()
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if Self.manualScrollCommands.contains(NSStringFromSelector(selector)) {
            onManualScroll?()
        }
        super.doCommand(by: selector)
    }
}

final class LyricsPanelController: NSWindowController, NSWindowDelegate {
    var onSeek: ((TimeInterval) -> Void)?
    var onDownload: ((Track) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Lyrics")
    private let artistLabel = NSTextField(labelWithString: "")
    private let downloadButton = NSButton(title: "Download Lyrics", target: nil, action: nil)
    private let autoScrollButton = NSButton(title: "Auto Scroll", target: nil, action: nil)
    private let scrollView = LyricsScrollView()
    private let textView = LyricsTextView()
    private let defaultTextContainerInset = NSSize(width: 38, height: 0)
    private var lineRanges: [NSRange] = []
    private var lineTimes: [TimeInterval] = []
    private var currentLineIndex: Int?
    private var track: Track?
    private var displayedLyrics: LRCLyrics?
    private var displayedMessage = ""
    private var autoScrollEnabled = true
    private var displayedSkipSegments: [AudioSkipSegment] = []

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Lyrics"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.minSize = NSSize(width: 400, height: 440)
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = makeContentView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func set(track: Track, lyrics: LRCLyrics?, message: String) {
        let trackChanged = self.track?.path != track.path
        let contentChanged = trackChanged || displayedLyrics != lyrics || displayedMessage != message
        self.track = track
        titleLabel.stringValue = track.title
        artistLabel.stringValue = track.artistDisplay
        if trackChanged {
            setAutoScrollEnabled(true)
            displayedSkipSegments = []
        }
        guard contentChanged else { return }
        clearCurrentLineAttributes()
        currentLineIndex = nil
        displayedLyrics = lyrics
        displayedMessage = message
        guard let lyrics else {
            lineRanges = []
            lineTimes = []
            replaceContent(messageContent(message))
            return
        }
        renderLyrics(lyrics)
    }

    private func clearCurrentLineAttributes() {
        guard let previous = currentLineIndex, lineRanges.indices.contains(previous) else { return }
        textView.layoutManager?.removeTemporaryAttribute(
            .foregroundColor,
            forCharacterRange: lineRanges[previous]
        )
    }

    private func messageContent(_ message: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(
            string: message,
            attributes: [
                .font: NSFont.systemFont(ofSize: 22, weight: .medium),
                .foregroundColor: AppTheme.secondaryText,
                .paragraphStyle: paragraph
            ]
        )
    }

    private func renderLyrics(_ lyrics: LRCLyrics) {
        let content = NSMutableAttributedString()
        var ranges: [NSRange] = []
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 20
        paragraph.lineSpacing = 5
        for (lineIndex, line) in lyrics.lines.enumerated() {
            let text = line.text.isEmpty ? "♪" : line.text
            let range = NSRange(location: content.length, length: (text as NSString).length)
            content.append(NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
                    .foregroundColor: AppTheme.secondaryText,
                    .paragraphStyle: paragraph
                ]
            ))
            if lineIndex < lyrics.lines.count - 1 {
                content.append(NSAttributedString(string: "\n"))
            }
            ranges.append(range)
        }
        lineRanges = ranges
        lineTimes = lyrics.isSynchronized ? lyrics.lines.map(\.time) : []
        replaceContent(content)
        applySkipSegmentStyles()
    }

    func setDownloadInProgress(_ inProgress: Bool) {
        downloadButton.isEnabled = !inProgress
        downloadButton.title = inProgress ? "Downloading…" : "Download Lyrics"
    }

    func setSkipSegments(_ segments: [AudioSkipSegment]) {
        displayedSkipSegments = segments
        applySkipSegmentStyles()
    }

    func setCurrentLine(_ index: Int?) {
        guard currentLineIndex != index else { return }
        if let previous = currentLineIndex, lineRanges.indices.contains(previous) {
            textView.layoutManager?.removeTemporaryAttribute(
                .foregroundColor,
                forCharacterRange: lineRanges[previous]
            )
        }
        currentLineIndex = index
        if let index, lineRanges.indices.contains(index) {
            textView.layoutManager?.setTemporaryAttributes(
                [.foregroundColor: AppTheme.accent],
                forCharacterRange: lineRanges[index]
            )
        }
        guard autoScrollEnabled else { return }
        scrollToCurrentLine()
    }

    private func makeContentView() -> NSView {
        let root = ThemeBackgroundView()

        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.textColor = AppTheme.primaryText
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail

        artistLabel.font = .systemFont(ofSize: 14, weight: .medium)
        artistLabel.textColor = AppTheme.secondaryText
        artistLabel.alignment = .center
        artistLabel.lineBreakMode = .byTruncatingTail

        downloadButton.bezelStyle = .rounded
        downloadButton.target = self
        downloadButton.action = #selector(downloadLyrics)
        downloadButton.toolTip = "Download lyrics from LRCLIB"

        autoScrollButton.bezelStyle = .rounded
        autoScrollButton.target = self
        autoScrollButton.action = #selector(enableAutoScroll)
        autoScrollButton.setAccessibilityLabel("Auto Scroll Lyrics")
        updateAutoScrollButton()

        configureTextView()

        let controls = NSStackView(views: [downloadButton, autoScrollButton])
        controls.orientation = .horizontal
        controls.spacing = 8

        let header = NSStackView(views: [titleLabel, artistLabel, controls])
        header.orientation = .vertical
        header.spacing = 5

        let stack = NSStackView(views: [header, scrollView])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)
        ])
        return root
    }

    private func configureTextView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = AppTheme.background
        textView.textContainerInset = defaultTextContainerInset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.toolTip = "Click a lyric to seek"
        textView.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(lyricClicked(_:)))
        )
        textView.onManualScroll = { [weak self] in
            self?.pauseAutoScroll()
        }
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.onManualScroll = { [weak self] in
            self?.pauseAutoScroll()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(manualScrollDetected(_:)),
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
    }

    private func scrollToTop() {
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private func scrollToCurrentLine() {
        guard let index = currentLineIndex, lineRanges.indices.contains(index) else {
            scrollToTop()
            return
        }

        window?.contentView?.layoutSubtreeIfNeeded()
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            textView.scrollRangeToVisible(lineRanges[index])
            return
        }
        layoutManager.ensureLayout(for: textContainer)

        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: lineRanges[index],
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else {
            textView.scrollRangeToVisible(lineRanges[index])
            return
        }

        let lineRect = layoutManager
            .boundingRect(forGlyphRange: glyphRange, in: textContainer)
            .offsetBy(
                dx: textView.textContainerOrigin.x,
                dy: textView.textContainerOrigin.y
            )
        let visibleRect = textView.visibleRect
        guard visibleRect.height > 0 else {
            textView.scrollRangeToVisible(lineRanges[index])
            return
        }

        let minY = textView.bounds.minY
        let maxY = max(minY, textView.bounds.maxY - visibleRect.height)
        let centeredY = lineRect.midY - (visibleRect.height / 2)
        let targetY = min(max(centeredY, minY), maxY)
        let clipView = scrollView.contentView
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
    }

    private func applySkipSegmentStyles() {
        guard let textStorage = textView.textStorage else { return }
        for (index, range) in lineRanges.enumerated() {
            let isSkipped = lineTimes.indices.contains(index)
                && displayedSkipSegments.contains { segment in
                    lineTimes[index] >= segment.startTime && lineTimes[index] < segment.endTime
                }
            textStorage.addAttribute(
                .foregroundColor,
                value: isSkipped
                    ? AppTheme.secondaryText.withAlphaComponent(0.42)
                    : AppTheme.secondaryText,
                range: range
            )
        }
    }

    private func replaceContent(_ content: NSAttributedString) {
        textView.textStorage?.setAttributedString(content)
        if autoScrollEnabled {
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
    }

    private func pauseAutoScroll() {
        guard autoScrollEnabled else { return }
        setAutoScrollEnabled(false)
    }

    @objc private func manualScrollDetected(_ notification: Notification) {
        pauseAutoScroll()
    }

    func windowDidResize(_ notification: Notification) {
        guard autoScrollEnabled else { return }
        scrollToCurrentLine()
    }

    private func setAutoScrollEnabled(_ enabled: Bool) {
        autoScrollEnabled = enabled
        updateAutoScrollButton()
    }

    private func updateAutoScrollButton() {
        autoScrollButton.title = autoScrollEnabled ? "Auto Scroll" : "Resume Auto Scroll"
        autoScrollButton.contentTintColor = autoScrollEnabled ? AppTheme.secondaryText : AppTheme.accent
        autoScrollButton.toolTip = autoScrollEnabled
            ? "Lyrics automatically follow playback"
            : "Resume automatic lyric scrolling"
    }

    @objc private func enableAutoScroll() {
        setAutoScrollEnabled(true)
        scrollToCurrentLine()
    }

    @objc private func lyricClicked(_ recognizer: NSClickGestureRecognizer) {
        let characterIndex = textView.characterIndexForInsertion(at: recognizer.location(in: textView))
        guard let lineIndex = lineRanges.firstIndex(where: {
            NSLocationInRange(characterIndex, $0) || characterIndex == NSMaxRange($0)
        }),
        lineTimes.indices.contains(lineIndex) else { return }
        onSeek?(lineTimes[lineIndex])
    }

    @objc private func downloadLyrics() {
        guard let track else { return }
        onDownload?(track)
    }
}
