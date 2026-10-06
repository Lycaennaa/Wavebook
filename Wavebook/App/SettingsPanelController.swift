import AppKit
import WavebookCore

final class SettingsPanelController: NSWindowController, NSWindowDelegate {
    var onOutputDeviceChanged: ((String?) -> Void)?
    var onHiddenOutputDeviceUIDsChanged: ((Set<String>) -> Void)?
    var onReplayGainAnalysisFileConcurrencyChanged: ((Int) -> Void)?
    var onSkipSilentSegmentsChanged: ((Bool) -> Void)?

    private let popup = NSPopUpButton()
    private let appearancePopup = NSPopUpButton()
    private let skipSilentSegmentsButton = NSButton(
        checkboxWithTitle: "Skip silent segments at the start and end of songs",
        target: nil,
        action: nil
    )
    private let hiddenUIDField = NSTextField(string: "")
    private let outputStatusLabel = NSTextField(labelWithString: "Follows system output")
    private let analysisStatusLabel = NSTextField(labelWithString: "Analysis unavailable")
    private let analysisCountsLabel = NSTextField(labelWithString: "Completed: 0   Pending: 0   Running: 0   Failed: 0")
    private let currentItemLabel = NSTextField(labelWithString: "Current: —")
    private let analysisFileConcurrencyPopup = NSPopUpButton()
    private let analysisErrorLabel = NSTextField(wrappingLabelWithString: "")
    private let failuresLabel = NSTextField(labelWithString: "Failures")
    private let failuresTextView = NSTextView()
    private let cancelAnalysisButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let rescanAllButton = NSButton(title: "Rescan All", target: nil, action: nil)
    private let separator = NSBox()
    private let libraryFoldersView = LibraryFoldersSettingsView(frame: .zero)
    private var replayGainService: ReplayGainAnalysisService?
    private var refreshTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var actionErrorReason: String?
    private var actionInProgress = false

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 900),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Settings"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = makeContentView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        refreshTask?.cancel()
        actionTask?.cancel()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        startRefreshingReplayGainStatus()
    }

    func windowWillClose(_ notification: Notification) {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func set(devices: [OutputDevice], selectedUID: String?, hiddenUIDs: Set<String>) {
        popup.removeAllItems()
        popup.addItem(withTitle: "System Default")
        popup.item(at: 0)?.representedObject = ""

        for device in devices {
            popup.addItem(withTitle: device.isDefault ? "\(device.name) (Default)" : device.name)
            popup.lastItem?.representedObject = device.uid
        }

        if let selectedUID, !devices.contains(where: { $0.uid == selectedUID }) {
            popup.addItem(withTitle: "Missing: \(selectedUID)")
            popup.lastItem?.representedObject = selectedUID
        }

        hiddenUIDField.stringValue = hiddenUIDs.sorted().joined(separator: ", ")
        setSelectedOutputDeviceUID(selectedUID)
    }

    func setSelectedOutputDeviceUID(_ selectedUID: String?) {
        let index = popup.itemArray.firstIndex { ($0.representedObject as? String) == (selectedUID ?? "") } ?? 0
        popup.selectItem(at: index)
        outputStatusLabel.stringValue = selectedUID == nil
            ? "Follows system output"
            : "Uses this output until the system output changes"
    }
    func configureLibraryFolders(_ actions: LibraryFolderSettingsActions) {
        libraryFoldersView.configure(actions)
    }
    private func setAppearance(_ appearance: AppAppearance) {
        guard let index = appearancePopup.itemArray.firstIndex(where: { item in
            guard let itemAppearance = item.representedObject as? AppAppearance else { return false }
            return itemAppearance == appearance
        }) else { return }
        appearancePopup.selectItem(at: index)
    }

    func setSkipSilentSegments(_ enabled: Bool) {
        skipSilentSegmentsButton.state = enabled ? .on : .off
    }

    func setReplayGainService(_ service: ReplayGainAnalysisService?) {
        replayGainService = service
        actionErrorReason = nil
        updateAnalysisControls(isRunning: false)
        if window?.isVisible == true {
            startRefreshingReplayGainStatus()
        }
    }

    func setReplayGainAnalysisFileConcurrency(_ value: Int) {
        analysisFileConcurrencyPopup.selectItem(withTitle: String(ReplayGain.clampedAnalysisFileConcurrency(value)))
    }

    func showReplayGainActionError(_ message: String) {
        actionErrorReason = message
        analysisErrorLabel.stringValue = message
        analysisErrorLabel.isHidden = false
    }

}
extension SettingsPanelController {
    private func makeContentView() -> NSView {
        let root = ThemeBackgroundView()
        let failuresScrollView = makeFailuresScrollView()
        let views = makeAppearanceViews() + [libraryFoldersView] + makeOutputViews()
        let analysisViews = makeAnalysisViews(failuresScrollView: failuresScrollView)
        let stack = NSStackView(views: views + analysisViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: outputStatusLabel)
        stack.setCustomSpacing(16, after: separator)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            popup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hiddenUIDField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            skipSilentSegmentsButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            libraryFoldersView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            libraryFoldersView.heightAnchor.constraint(equalToConstant: 212),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            analysisStatusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            analysisCountsLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            currentItemLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            analysisErrorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            failuresScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            failuresScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
        updateAnalysisControls(isRunning: false)
        return root
    }

    private func makeAppearanceViews() -> [NSView] {
        let appearanceTitle = sectionTitle("Appearance")
        let appearanceLabel = NSTextField(labelWithString: "Interface appearance")
        appearanceLabel.textColor = AppTheme.secondaryText
        appearancePopup.addItems(withTitles: AppAppearance.allCases.map(\.title))
        for (item, appearance) in zip(appearancePopup.itemArray, AppAppearance.allCases) {
            item.representedObject = appearance
        }
        appearancePopup.target = self
        appearancePopup.action = #selector(appearanceChanged)
        appearancePopup.setAccessibilityLabel("Interface Appearance")
        setAppearance(AppTheme.appearance)
        let appearanceStack = NSStackView(views: [appearanceLabel, appearancePopup])
        appearanceStack.orientation = .horizontal
        appearanceStack.alignment = .centerY
        appearanceStack.spacing = 10
        return [appearanceTitle, appearanceStack]
    }

    private func makeOutputViews() -> [NSView] {
        let outputTitle = sectionTitle("Output device")
        let playbackTitle = sectionTitle("Playback")
        popup.target = self
        popup.action = #selector(outputChanged)
        popup.translatesAutoresizingMaskIntoConstraints = false
        let hiddenLabel = sectionTitle("Hidden output UIDs")
        hiddenUIDField.placeholderString = "UIDs separated by comma, space, or newline"
        hiddenUIDField.textColor = AppTheme.primaryText
        hiddenUIDField.backgroundColor = AppTheme.raised
        hiddenUIDField.isBezeled = true
        hiddenUIDField.target = self
        hiddenUIDField.action = #selector(applyHiddenUIDs)
        hiddenUIDField.translatesAutoresizingMaskIntoConstraints = false
        let applyHiddenButton = NSButton(
            title: "Apply Hidden UIDs",
            target: self,
            action: #selector(applyHiddenUIDs)
        )
        applyHiddenButton.bezelStyle = .rounded
        applyHiddenButton.contentTintColor = AppTheme.accent
        outputStatusLabel.textColor = AppTheme.secondaryText
        skipSilentSegmentsButton.target = self
        skipSilentSegmentsButton.action = #selector(skipSilentSegmentsChanged)
        skipSilentSegmentsButton.contentTintColor = AppTheme.accent
        separator.boxType = .separator
        return [
            outputTitle,
            popup,
            hiddenLabel,
            hiddenUIDField,
            applyHiddenButton,
            outputStatusLabel,
            playbackTitle,
            skipSilentSegmentsButton,
            separator
        ]
    }

    private func configureAnalysisLabels() {
        for label in [analysisStatusLabel, analysisCountsLabel, currentItemLabel] {
            label.textColor = AppTheme.secondaryText
            label.lineBreakMode = .byTruncatingMiddle
        }
        currentItemLabel.toolTip = "File currently being analyzed"
    }

    private func makeConcurrencyLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "Files processed at once")
        label.textColor = AppTheme.secondaryText
        analysisFileConcurrencyPopup.addItems(
            withTitles: (1...ReplayGain.maximumAnalysisFileConcurrency).map(String.init)
        )
        analysisFileConcurrencyPopup.target = self
        analysisFileConcurrencyPopup.action = #selector(replayGainAnalysisFileConcurrencyChanged)
        analysisFileConcurrencyPopup.selectItem(withTitle: String(ReplayGain.defaultAnalysisFileConcurrency))
        return label
    }

    private func makeFailuresScrollView() -> NSScrollView {
        failuresTextView.isEditable = false
        failuresTextView.isSelectable = true
        failuresTextView.drawsBackground = true
        failuresTextView.backgroundColor = AppTheme.raised
        failuresTextView.textColor = AppTheme.primaryText
        failuresTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        failuresTextView.textContainerInset = NSSize(width: 8, height: 8)
        failuresTextView.isVerticallyResizable = true
        failuresTextView.isHorizontallyResizable = false
        failuresTextView.autoresizingMask = [.width]
        failuresTextView.textContainer?.widthTracksTextView = true
        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = failuresTextView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        return scrollView
    }

    private func makeAnalysisViews(failuresScrollView: NSScrollView) -> [NSView] {
        let analysisTitle = sectionTitle("ReplayGain analysis")
        configureAnalysisLabels()
        let concurrencyLabel = makeConcurrencyLabel()
        let concurrencyStack = NSStackView(views: [concurrencyLabel, analysisFileConcurrencyPopup])
        concurrencyStack.orientation = .horizontal
        concurrencyStack.alignment = .centerY
        concurrencyStack.spacing = 10
        analysisErrorLabel.textColor = .systemRed
        analysisErrorLabel.maximumNumberOfLines = 2
        analysisErrorLabel.isHidden = true
        cancelAnalysisButton.target = self
        cancelAnalysisButton.action = #selector(cancelReplayGainAnalysis)
        cancelAnalysisButton.bezelStyle = .rounded
        cancelAnalysisButton.contentTintColor = AppTheme.accent
        rescanAllButton.target = self
        rescanAllButton.action = #selector(rescanAllReplayGain)
        rescanAllButton.bezelStyle = .rounded
        rescanAllButton.contentTintColor = AppTheme.accent
        let actionStack = NSStackView(views: [cancelAnalysisButton, rescanAllButton])
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = 10
        return [
            analysisTitle,
            analysisStatusLabel,
            analysisCountsLabel,
            currentItemLabel,
            concurrencyStack,
            analysisErrorLabel,
            actionStack,
            failuresLabel,
            failuresScrollView
        ]
    }

    private func sectionTitle(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = AppTheme.primaryText
        return label
    }

    private func startRefreshingReplayGainStatus() {
        refreshTask?.cancel()
        guard let replayGainService else {
            analysisStatusLabel.stringValue = "Analysis unavailable"
            analysisCountsLabel.stringValue = [
                "Tracks: 0/0",
                "Album values: 0/0",
                "Queue: 0 pending",
                "Running: 0",
                "Failed: 0"
            ].joined(separator: "   ")
            currentItemLabel.stringValue = "Current: —"
            failuresLabel.stringValue = "Failures"
            failuresTextView.string = ""
            updateAnalysisControls(isRunning: false)
            return
        }

        refreshTask = Task { [weak self] in
            var lastStatus: ReplayGainAnalysisServiceStatus?
            var lastFailures: [ReplayGainAnalysisFailure]?
            var refreshInterval: TimeInterval = 10
            while !Task.isCancelled {
                do {
                    let status = try await replayGainService.status()
                    try Task.checkCancellation()
                    let statusChanged = status != lastStatus
                    if statusChanged || !status.isRunning {
                        let failures = try await replayGainService.failures()
                        try Task.checkCancellation()
                        if statusChanged || failures != lastFailures {
                            self?.apply(status: status, failures: failures)
                        }
                        lastStatus = status
                        lastFailures = failures
                    }
                    refreshInterval = status.isRunning ? 1 : 10
                } catch is CancellationError {
                    return
                } catch {
                    refreshInterval = 10
                    self?.showReplayGainActionError(error.localizedDescription)
                }

                do {
                    try await Task.sleep(for: .seconds(refreshInterval))
                } catch {
                    return
                }
            }
        }
    }

    private func apply(status: ReplayGainAnalysisServiceStatus, failures: [ReplayGainAnalysisFailure]) {
        switch status.stage {
        case .tracks:
            analysisStatusLabel.stringValue = "Analysis: Track pass"
        case .albums:
            analysisStatusLabel.stringValue = "Analysis: Album pass"
        case .recovering:
            analysisStatusLabel.stringValue = "Analysis: Recovering"
        case .waiting:
            analysisStatusLabel.stringValue = "Analysis: Waiting"
        case .idle:
            analysisStatusLabel.stringValue = "Analysis: Idle"
        }
        analysisCountsLabel.stringValue = [
            "Tracks: \(status.progress.trackCompleted)/\(status.progress.total)",
            "Album values: \(status.progress.albumCompleted)/\(status.progress.total)",
            "Queue: \(status.counts.pending) pending",
            "Running: \(status.counts.running)",
            "Failed: \(status.counts.failed)"
        ].joined(separator: "   ")
        analysisCountsLabel.toolTip = [
            "Track and album values complete separately.",
            "Album values count tracks with a completed album value and may wait for all tracks in an album."
        ].joined(separator: " ")
        let currentNames = status.currentPaths.map { URL(fileURLWithPath: $0).lastPathComponent }
        let currentLabel = status.stage == .albums ? "Album" : "Track"
        currentItemLabel.stringValue = status.currentPaths.isEmpty
            ? "Current: —"
            : "Current \(currentLabel) (\(status.currentPaths.count)): \(currentNames.joined(separator: ", "))"
        currentItemLabel.toolTip = status.currentPaths.joined(separator: "\n")

        let errorReason = actionErrorReason ?? status.serviceErrorReason
        analysisErrorLabel.stringValue = errorReason ?? ""
        analysisErrorLabel.isHidden = errorReason == nil

        failuresLabel.stringValue = status.counts.failed > failures.count
            ? "Failures (showing latest \(failures.count) of \(status.counts.failed))"
            : "Failures (\(status.counts.failed))"
        failuresTextView.string = failures.map { failure in
            let timestamp = DateFormatter.localizedString(
                from: failure.timestamp,
                dateStyle: .short,
                timeStyle: .medium
            )
            return "\(timestamp) — \(failure.reason)\n\(failure.path)"
        }.joined(separator: "\n\n")
        updateAnalysisControls(isRunning: status.isRunning)
    }

    private func updateAnalysisControls(isRunning: Bool) {
        cancelAnalysisButton.isEnabled = replayGainService != nil && isRunning && !actionInProgress
        rescanAllButton.isEnabled = replayGainService != nil && !actionInProgress
        analysisFileConcurrencyPopup.isEnabled = onReplayGainAnalysisFileConcurrencyChanged != nil && !actionInProgress
    }

    @objc private func appearanceChanged() {
        guard let appearance = appearancePopup.selectedItem?.representedObject as? AppAppearance else { return }
        AppTheme.apply(appearance)
    }

    @objc private func outputChanged() {
        let uid = popup.selectedItem?.representedObject as? String
        onOutputDeviceChanged?(uid?.isEmpty == false ? uid : nil)
    }
    @objc private func skipSilentSegmentsChanged() {
        onSkipSilentSegmentsChanged?(skipSilentSegmentsButton.state == .on)
    }

    @objc private func applyHiddenUIDs() {
        let uids = Set(hiddenUIDField.stringValue.split { $0 == "," || $0 == ";" || $0.isWhitespace }.map(String.init))
        onHiddenOutputDeviceUIDsChanged?(uids)
    }

    @objc private func replayGainAnalysisFileConcurrencyChanged() {
        onReplayGainAnalysisFileConcurrencyChanged?(analysisFileConcurrencyPopup.indexOfSelectedItem + 1)
    }

    @objc private func cancelReplayGainAnalysis() {
        guard let replayGainService, !actionInProgress else { return }
        actionInProgress = true
        actionErrorReason = nil
        updateAnalysisControls(isRunning: true)
        actionTask = Task { [weak self] in
            await replayGainService.cancel()
            guard let self else { return }
            actionInProgress = false
            updateAnalysisControls(isRunning: false)
            if window?.isVisible == true {
                startRefreshingReplayGainStatus()
            }
        }
    }

    @objc private func rescanAllReplayGain() {
        guard let replayGainService, !actionInProgress else { return }
        actionInProgress = true
        actionErrorReason = nil
        updateAnalysisControls(isRunning: false)
        actionTask = Task { [weak self] in
            do {
                try await replayGainService.rescanAll()
            } catch {
                self?.actionErrorReason = error.localizedDescription
            }
            guard let self else { return }
            actionInProgress = false
            updateAnalysisControls(isRunning: true)
            if window?.isVisible == true {
                startRefreshingReplayGainStatus()
            }
        }
    }
}
