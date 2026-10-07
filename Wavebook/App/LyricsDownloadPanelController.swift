import AppKit
import WavebookCore

final class LyricsDownloadPanel: NSPanel {
    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown,
              let editor = firstResponder as? NSTextView,
              editor.isFieldEditor,
              let shortcut = TextEditingShortcut(event: event, controlPolicy: .all) else {
            super.sendEvent(event)
            return
        }
        shortcut.perform(on: editor)
    }
}

final class LyricsDownloadPanelController: NSWindowController, NSWindowDelegate {
    var onDownload: ((Track, LRCLIBLyricsSearchResult) -> Void)?
    var onSeek: ((TimeInterval) -> Void)?
    var onClose: (() -> Void)?

    private let track: Track
    private let downloader: LRCLIBLyricsDownloader
    private let titleCheck = NSButton(checkboxWithTitle: "Title", target: nil, action: nil)
    private let artistCheck = NSButton(checkboxWithTitle: "Artist", target: nil, action: nil)
    private let albumCheck = NSButton(checkboxWithTitle: "Album", target: nil, action: nil)
    private let keywordsCheck = NSButton(checkboxWithTitle: "Keywords", target: nil, action: nil)
    private let titleField = NSTextField(string: "")
    private let artistField = NSTextField(string: "")
    private let albumField = NSTextField(string: "")
    private let keywordsField = NSTextField(string: "")
    private let resultPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusLabel = NSTextField(labelWithString: "")
    private let privacyDisclosureLabel = NSTextField(
        wrappingLabelWithString:
            "Only checked, non-empty title, artist, album, and keyword values are sent "
                + "to lrclib.net when you click Search LRCLIB. No audio files are sent."
    )
    private let previewTextView = NSTextView()
    private let searchButton = NSButton(title: "Search LRCLIB", target: nil, action: nil)
    private let downloadButton = NSButton(title: "Download Selected", target: nil, action: nil)
    private var results: [LRCLIBLyricsSearchResult] = []
    private var searchTask: Task<Void, Never>?
    private var searchGeneration: UUID?
    private var isSearching = false
    private var isDownloading = false
    private var previewLyrics: LRCLyrics?
    private var previewLineRanges: [NSRange] = []
    private var previewLineTimes: [TimeInterval] = []
    private var currentPreviewLineIndex: Int?
    private var playbackElapsed: TimeInterval?

    init(track: Track, downloader: LRCLIBLyricsDownloader) {
        self.track = track
        self.downloader = downloader
        let panel = LyricsDownloadPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Download Lyrics"
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 560, height: 520)
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = makeContentView()
        configureInitialValues()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setDownloadInProgress(_ inProgress: Bool) {
        isDownloading = inProgress
        downloadButton.title = inProgress ? "Downloading…" : "Download Selected"
        updateButtons()
    }

    func showDownloadError(_ message: String) {
        setStatus(message)
        setDownloadInProgress(false)
    }

    func setPlaybackPosition(_ elapsed: TimeInterval, trackPath: String?) {
        guard trackPath == track.path, elapsed.isFinite else {
            playbackElapsed = nil
            setCurrentPreviewLine(nil)
            return
        }
        playbackElapsed = max(0, elapsed)
        updateCurrentPreviewLine()
    }

    func windowWillClose(_ notification: Notification) {
        searchGeneration = nil
        searchTask?.cancel()
        searchTask = nil
        onClose?()
    }

    private func configureInitialValues() {
        titleCheck.state = .on
        artistCheck.state = .on
        albumCheck.state = track.albumTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .off : .on
        keywordsCheck.state = .off
        titleField.stringValue = track.title
        artistField.stringValue = track.artistDisplay
        albumField.stringValue = track.albumTitle
        statusLabel.stringValue = "Select metadata to search, then choose a result."
        resultPicker.addItem(withTitle: "Search to load results")
        showPreview(message: "Search results will appear here.")
        updateButtons()
    }
    private func setStatus(_ message: String) {
        statusLabel.stringValue = message
        NSAccessibility.post(element: statusLabel, notification: .valueChanged)
    }

    private func makeContentView() -> NSView {
        let root = ThemeBackgroundView()
        configureMetadataFields()
        let form = makeMetadataForm()
        let resultsLabel = NSTextField(labelWithString: "LRCLIB result")
        configureResultControls()
        let previewLabel = NSTextField(labelWithString: "Lyrics preview")
        configurePreviewLabel(previewLabel)
        let previewScrollView = makePreviewScrollView()
        let buttons = makeActionButtons()
        let stack = makeContentStack(
            form: form,
            resultsLabel: resultsLabel,
            previewLabel: previewLabel,
            previewScrollView: previewScrollView,
            buttons: buttons
        )
        activateContentLayout(root: root, stack: stack)
        return root
    }

    private func configureMetadataFields() {
        for field in [titleField, artistField, albumField, keywordsField] {
            field.isEditable = true
            field.isSelectable = true
            field.usesSingleLineMode = true
            field.cell?.isScrollable = true
            field.textColor = AppTheme.primaryText
            field.backgroundColor = AppTheme.raised
            field.isBezeled = true
            field.drawsBackground = true
            field.bezelStyle = .roundedBezel
            field.font = .systemFont(ofSize: 13)
            field.placeholderString = "Not sent when unchecked"
        }
        keywordsField.placeholderString = "Optional free-text search"
        titleField.setAccessibilityLabel("Track title search text")
        artistField.setAccessibilityLabel("Artist search text")
        albumField.setAccessibilityLabel("Album search text")
        keywordsField.setAccessibilityLabel("Search keywords")
    }

    private func makeMetadataForm() -> NSStackView {
        let form = NSStackView(views: [
            fieldRow(check: titleCheck, field: titleField),
            fieldRow(check: artistCheck, field: artistField),
            fieldRow(check: albumCheck, field: albumField),
            fieldRow(check: keywordsCheck, field: keywordsField)
        ])
        form.orientation = .vertical
        form.spacing = 8
        form.alignment = .width
        return form
    }

    private func configureResultControls() {
        resultPicker.target = self
        resultPicker.action = #selector(resultChanged)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = AppTheme.secondaryText
        statusLabel.lineBreakMode = .byTruncatingTail
        resultPicker.setAccessibilityLabel("LRCLIB search results")
        statusLabel.setAccessibilityLabel("Lyrics search status")
        privacyDisclosureLabel.font = .systemFont(ofSize: 12)
        privacyDisclosureLabel.textColor = AppTheme.secondaryText
        privacyDisclosureLabel.maximumNumberOfLines = 0
        privacyDisclosureLabel.setAccessibilityLabel("Lyrics lookup privacy notice")
    }

    private func configurePreviewLabel(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = AppTheme.secondaryText
    }

    private func makePreviewScrollView() -> NSScrollView {
        previewTextView.isEditable = false
        previewTextView.isSelectable = true
        previewTextView.drawsBackground = true
        previewTextView.backgroundColor = AppTheme.background
        previewTextView.textColor = AppTheme.primaryText
        previewTextView.font = .systemFont(ofSize: 15)
        previewTextView.textContainerInset = NSSize(width: 14, height: 14)
        previewTextView.isVerticallyResizable = true
        previewTextView.isHorizontallyResizable = false
        previewTextView.textContainer?.widthTracksTextView = true
        previewTextView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        previewTextView.setAccessibilityLabel("Lyrics preview")
        previewTextView.toolTip = "Click a synced lyric to seek"
        previewTextView.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(previewLyricClicked(_:)))
        )
        let previewScrollView = NSScrollView()
        previewScrollView.drawsBackground = false
        previewScrollView.hasVerticalScroller = true
        previewScrollView.autohidesScrollers = true
        previewScrollView.borderType = .bezelBorder
        previewScrollView.documentView = previewTextView
        previewScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        return previewScrollView
    }

    private func makeActionButtons() -> NSStackView {
        searchButton.bezelStyle = .rounded
        searchButton.target = self
        searchButton.action = #selector(search)
        searchButton.setAccessibilityLabel("Search LRCLIB")
        searchButton.setAccessibilityHelp(
            "Sends only checked, non-empty metadata values to lrclib.net. No audio files are sent."
        )
        downloadButton.bezelStyle = .rounded
        downloadButton.target = self
        downloadButton.action = #selector(downloadSelected)
        downloadButton.setAccessibilityLabel("Download Selected Lyrics")
        let buttons = NSStackView(views: [searchButton, downloadButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY
        return buttons
    }

    private func makeContentStack(
        form: NSStackView,
        resultsLabel: NSTextField,
        previewLabel: NSTextField,
        previewScrollView: NSScrollView,
        buttons: NSStackView
    ) -> NSStackView {
        let stack = NSStackView(
            views: [
                form, resultsLabel, resultPicker, statusLabel, previewLabel, previewScrollView,
                privacyDisclosureLabel, buttons
            ]
        )
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .width
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func activateContentLayout(root: NSView, stack: NSStackView) {
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            resultPicker.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

}
extension LyricsDownloadPanelController {
    private func fieldRow(check: NSButton, field: NSTextField) -> NSView {
        check.setContentHuggingPriority(.required, for: .horizontal)
        check.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let row = NSStackView(views: [check, field])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        return row
    }

    @objc private func search() {
        let query = LRCLIBLyricsSearchQuery(
            trackName: selectedValue(check: titleCheck, field: titleField),
            artistName: selectedValue(check: artistCheck, field: artistField),
            albumName: selectedValue(check: albumCheck, field: albumField),
            keywords: selectedValue(check: keywordsCheck, field: keywordsField)
        )
        let generation = UUID()
        searchGeneration = generation
        searchTask?.cancel()
        results = []
        resultPicker.removeAllItems()
        resultPicker.addItem(withTitle: "Searching…")
        setStatus("Searching LRCLIB…")
        showPreview(message: "Search results will appear here.")
        isSearching = true
        updateButtons()

        let downloader = downloader
        searchTask = Task(priority: .userInitiated) { [weak self] in
            do {
                let results = try await downloader.searchLyrics(query)
                try Task.checkCancellation()
                self?.searchFinished(results, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                self?.searchFailed(error, generation: generation)
            }
        }
    }

    private func searchFinished(_ results: [LRCLIBLyricsSearchResult], generation: UUID) {
        guard searchGeneration == generation else { return }
        searchTask = nil
        searchGeneration = nil
        isSearching = false
        self.results = results
        resultPicker.removeAllItems()

        if results.isEmpty {
            resultPicker.addItem(withTitle: "No results")
            setStatus("No LRCLIB results matched the selected metadata.")
            showPreview(message: "No lyrics available to preview.")
        } else {
            for result in results {
                resultPicker.addItem(withTitle: resultTitle(result))
            }
            resultPicker.selectItem(at: 0)
            setStatus("Found \(results.count) result\(results.count == 1 ? "" : "s").")
            updatePreview()
        }
        updateButtons()
    }

    private func searchFailed(_ error: Error, generation: UUID) {
        guard searchGeneration == generation else { return }
        searchTask = nil
        searchGeneration = nil
        isSearching = false
        results = []
        resultPicker.removeAllItems()
        resultPicker.addItem(withTitle: "Search failed")
        setStatus(error.localizedDescription)
        showPreview(message: "Lyrics preview unavailable.")
        updateButtons()
    }

    @objc private func resultChanged() {
        updatePreview()
        updateButtons()
    }

    @objc private func previewLyricClicked(_ recognizer: NSClickGestureRecognizer) {
        let characterIndex = previewTextView.characterIndexForInsertion(at: recognizer.location(in: previewTextView))
        guard let lineIndex = previewLineRanges.firstIndex(where: {
            NSLocationInRange(characterIndex, $0) || characterIndex == NSMaxRange($0)
        }), previewLineTimes.indices.contains(lineIndex) else { return }
        onSeek?(previewLineTimes[lineIndex])
    }

    @objc private func downloadSelected() {
        let index = resultPicker.indexOfSelectedItem
        guard results.indices.contains(index), results[index].previewLyrics != nil else { return }
        onDownload?(track, results[index])
    }

    private func selectedValue(check: NSButton, field: NSTextField) -> String? {
        guard check.state == .on else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func updateButtons() {
        let index = resultPicker.indexOfSelectedItem
        let canDownload = results.indices.contains(index) && results[index].previewLyrics != nil
        searchButton.isEnabled = !isSearching && !isDownloading
        resultPicker.isEnabled = !isSearching && !isDownloading && !results.isEmpty
        downloadButton.isEnabled = !isSearching && !isDownloading && canDownload
    }

    private func updatePreview() {
        let index = resultPicker.indexOfSelectedItem
        guard results.indices.contains(index) else {
            showPreview(message: "Select a result to preview its lyrics.")
            return
        }
        guard let lyrics = results[index].previewLyrics else {
            showPreview(message: "This result has no valid lyrics to preview.")
            return
        }
        showPreview(lyrics: lyrics)
    }

    private func showPreview(message: String) {
        previewLyrics = nil
        previewLineRanges = []
        previewLineTimes = []
        currentPreviewLineIndex = nil
        previewTextView.string = message
        previewTextView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private func showPreview(lyrics: LRCLyrics) {
        let content = NSMutableAttributedString()
        var ranges: [NSRange] = []
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 10
        paragraph.lineSpacing = 3

        for line in lyrics.lines {
            let text = line.text.isEmpty ? "♪" : line.text
            let range = NSRange(location: content.length, length: (text as NSString).length)
            content.append(NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                    .foregroundColor: AppTheme.secondaryText,
                    .paragraphStyle: paragraph
                ]
            ))
            content.append(NSAttributedString(string: "\n\n"))
            ranges.append(range)
        }

        previewLyrics = lyrics
        previewLineRanges = ranges
        previewLineTimes = lyrics.isSynchronized ? lyrics.lines.map(\.time) : []
        currentPreviewLineIndex = nil
        previewTextView.textStorage?.setAttributedString(content)
        previewTextView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        updateCurrentPreviewLine()
    }

    private func updateCurrentPreviewLine() {
        guard let previewLyrics, let playbackElapsed else {
            setCurrentPreviewLine(nil)
            return
        }
        setCurrentPreviewLine(previewLyrics.lineIndex(at: playbackElapsed, leadTime: 0.8))
    }

    private func setCurrentPreviewLine(_ index: Int?) {
        guard currentPreviewLineIndex != index else { return }
        if let previous = currentPreviewLineIndex, previewLineRanges.indices.contains(previous) {
            previewTextView.textStorage?.addAttributes([
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: AppTheme.secondaryText
            ], range: previewLineRanges[previous])
        }
        currentPreviewLineIndex = index
        guard let index, previewLineRanges.indices.contains(index) else { return }
        previewTextView.textStorage?.addAttributes([
            .font: NSFont.systemFont(ofSize: 18, weight: .bold),
            .foregroundColor: AppTheme.primaryText
        ], range: previewLineRanges[index])
        previewTextView.scrollRangeToVisible(previewLineRanges[index])
    }

    private func resultTitle(_ result: LRCLIBLyricsSearchResult) -> String {
        let type: String
        if result.isInstrumental {
            type = "Instrumental"
        } else if result.hasSyncedLyrics {
            type = "Synced"
        } else if result.hasPlainLyrics {
            type = "Plain"
        } else {
            type = "No lyrics"
        }
        let duration = result.duration.map(Self.durationText) ?? "Unknown length"
        return [result.trackName, result.artistName, result.albumName, duration, type]
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        guard duration.isFinite, duration >= 0, duration <= 7 * 24 * 60 * 60 else { return "Unknown length" }
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
