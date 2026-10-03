import AppKit
import WavebookCore

private final class ReplayGainCaptionField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let pointer events reach the button underneath.
        nil
    }
}

final class PlaybackBarControlsView: NSView {
    var onTogglePlayback: (() -> Void)?
    var onPreviousPlayback: (() -> Void)?
    var onNextPlayback: (() -> Void)?
    var onToggleShuffle: (() -> Void)?
    var onCycleRepeatMode: (() -> Void)?
    var onCycleReplayGainMode: (() -> Void)?
    var onEqualizerRequested: (() -> Void)?
    var onOutputDeviceRequested: ((NSButton) -> Void)?
    var onTogglePrivateMode: (() -> Void)?
    var onSkipSegmentsRequested: (() -> Void)?

    private let previousButton = NSButton(title: "⏮", target: nil, action: nil)
    private let playButton = NSButton(title: "▶︎", target: nil, action: nil)
    private let nextButton = NSButton(title: "⏭", target: nil, action: nil)
    private let shuffleButton = NSButton(title: "", target: nil, action: nil)
    private let repeatButton = NSButton(title: "", target: nil, action: nil)
    private let replayGainButton = NSButton(title: "", target: nil, action: nil)
    private let replayGainCaption = ReplayGainCaptionField(frame: .zero)
    private let eqButton = NSButton(title: "", target: nil, action: nil)
    private let outputButton = NSButton(title: "", target: nil, action: nil)
    private let privateModeButton = NSButton(title: "", target: nil, action: nil)
    private let skipSegmentsButton = NSButton(title: "", target: nil, action: nil)
    private var isEQEnabled = false
    private var isPrivateMode = false
    private var repeatMode: PlaybackRepeatMode = .off

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureTransportButtons()
        configureModeButtons()
        configureOutputButtons()
        configureLayout()
    }

    private func configureTransportButtons() {
        previousButton.bezelStyle = .rounded
        previousButton.font = .systemFont(ofSize: 15)
        previousButton.contentTintColor = AppTheme.accent
        previousButton.target = self
        previousButton.action = #selector(previousPlayback)
        previousButton.setAccessibilityLabel("Previous Track")
        playButton.bezelStyle = .rounded
        playButton.font = .systemFont(ofSize: 16)
        playButton.contentTintColor = AppTheme.accent
        playButton.target = self
        playButton.action = #selector(togglePlayback)
        playButton.setAccessibilityLabel("Play")
        nextButton.bezelStyle = .rounded
        nextButton.font = .systemFont(ofSize: 15)
        nextButton.contentTintColor = AppTheme.accent
        nextButton.target = self
        nextButton.action = #selector(nextPlayback)
        nextButton.setAccessibilityLabel("Next Track")
    }

    private func configureModeButtons() {
        shuffleButton.bezelStyle = .rounded
        shuffleButton.imagePosition = .imageOnly
        shuffleButton.image = NSImage(systemSymbolName: "shuffle", accessibilityDescription: "Shuffle")
        shuffleButton.target = self
        shuffleButton.action = #selector(toggleShuffle)
        setShuffleEnabled(false)
        repeatButton.bezelStyle = .rounded
        repeatButton.font = .systemFont(ofSize: 11)
        repeatButton.imagePosition = .imageLeading
        repeatButton.target = self
        repeatButton.action = #selector(cycleRepeatMode)
        updateRepeatButton()
        replayGainButton.bezelStyle = .rounded
        replayGainButton.imagePosition = .noImage
        replayGainButton.target = self
        replayGainButton.action = #selector(cycleReplayGainMode)
        replayGainCaption.font = .systemFont(ofSize: 10, weight: .medium)
        replayGainCaption.alignment = .center
        replayGainCaption.maximumNumberOfLines = 2
        replayGainCaption.lineBreakMode = .byWordWrapping
        replayGainCaption.isBezeled = false
        replayGainCaption.drawsBackground = false
        replayGainCaption.isEditable = false
        replayGainCaption.isSelectable = false
        replayGainCaption.setAccessibilityElement(false)
        replayGainCaption.translatesAutoresizingMaskIntoConstraints = false
        replayGainButton.addSubview(replayGainCaption)
        NSLayoutConstraint.activate([
            replayGainCaption.leadingAnchor.constraint(equalTo: replayGainButton.leadingAnchor, constant: 4),
            replayGainCaption.trailingAnchor.constraint(equalTo: replayGainButton.trailingAnchor, constant: -4),
            replayGainCaption.centerYAnchor.constraint(equalTo: replayGainButton.centerYAnchor),
            replayGainCaption.heightAnchor.constraint(equalToConstant: 28)
        ])
        setReplayGainMode(.defaultValue)
        eqButton.bezelStyle = .rounded
        eqButton.imagePosition = .noImage
        eqButton.font = .systemFont(ofSize: 11, weight: .medium)
        eqButton.target = self
        eqButton.action = #selector(toggleEQ)
        eqButton.setAccessibilityLabel("EQ")
        updateEQButton()
        privateModeButton.bezelStyle = .rounded
        privateModeButton.imagePosition = .imageOnly
        privateModeButton.target = self
        privateModeButton.action = #selector(togglePrivateMode)
        setPrivateMode(false)
    }

    private func configureOutputButtons() {
        outputButton.bezelStyle = .rounded
        outputButton.imagePosition = .imageOnly
        outputButton.image = NSImage(
            systemSymbolName: "speaker.wave.2",
            accessibilityDescription: "Output Device"
        )
        outputButton.contentTintColor = AppTheme.secondaryText
        outputButton.target = self
        outputButton.action = #selector(changeOutputDevice)
        outputButton.setAccessibilityLabel("Audio Output")
        skipSegmentsButton.bezelStyle = .rounded
        skipSegmentsButton.imagePosition = .imageOnly
        skipSegmentsButton.image = NSImage(
            systemSymbolName: "scissors",
            accessibilityDescription: "Auto-skip Segments"
        )
        skipSegmentsButton.contentTintColor = AppTheme.secondaryText
        skipSegmentsButton.target = self
        skipSegmentsButton.action = #selector(showSkipSegments)
        skipSegmentsButton.toolTip = "Edit auto-skip segments"
        skipSegmentsButton.setAccessibilityLabel("Edit Auto-skip Segments")
        skipSegmentsButton.isEnabled = false
    }

    private func configureLayout() {
        let transportButtons = [shuffleButton, previousButton, playButton, nextButton, repeatButton]
        let utilityButtons = [replayGainButton, outputButton, eqButton, privateModeButton, skipSegmentsButton]
        let buttonSize = NSSize(width: 48, height: 48)
        let transportRow = NSStackView()
        transportRow.orientation = .horizontal
        transportRow.alignment = .centerY
        transportRow.spacing = 6
        transportButtons.forEach { transportRow.addArrangedSubview($0) }
        let utilityRow = NSStackView()
        utilityRow.orientation = .horizontal
        utilityRow.alignment = .centerY
        utilityRow.spacing = 6
        utilityButtons.forEach { utilityRow.addArrangedSubview($0) }
        let rowSpacing: CGFloat = 4
        let controls = NSView()
        transportRow.translatesAutoresizingMaskIntoConstraints = false
        utilityRow.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(transportRow)
        controls.addSubview(utilityRow)
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        for button in transportButtons + utilityButtons {
            button.controlSize = .large
            button.widthAnchor.constraint(equalToConstant: buttonSize.width).isActive = true
            button.heightAnchor.constraint(equalToConstant: buttonSize.height).isActive = true
        }
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor),
            controls.topAnchor.constraint(equalTo: topAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor),
            controls.heightAnchor.constraint(equalToConstant: buttonSize.height * 2 + rowSpacing),
            transportRow.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            transportRow.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            transportRow.topAnchor.constraint(equalTo: controls.topAnchor),
            utilityRow.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            utilityRow.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            utilityRow.topAnchor.constraint(equalTo: transportRow.bottomAnchor, constant: rowSpacing),
            utilityRow.bottomAnchor.constraint(equalTo: controls.bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTrackAvailable(_ available: Bool) {
        skipSegmentsButton.isEnabled = available
    }

    func setPlaying(_ isPlaying: Bool) {
        playButton.title = isPlaying ? "⏸" : "▶︎"
        playButton.setAccessibilityLabel(isPlaying ? "Pause" : "Play")
    }

    func setEqualizerEnabled(_ enabled: Bool) {
        isEQEnabled = enabled
        updateEQButton()
    }

    func setShuffleEnabled(_ enabled: Bool) {
        shuffleButton.contentTintColor = enabled ? AppTheme.accent : AppTheme.secondaryText
        shuffleButton.setAccessibilityLabel(enabled ? "Shuffle On" : "Shuffle Off")
    }

    func setRepeatMode(_ mode: PlaybackRepeatMode) {
        repeatMode = mode
        updateRepeatButton()
    }

    func setReplayGainMode(_ mode: ReplayGainMode) {
        let value: String
        switch mode {
        case .off: value = "Off"
        case .track: value = "Track"
        case .album: value = "Album"
        }
        let tint = mode == .off ? AppTheme.secondaryText : AppTheme.accent
        replayGainButton.contentTintColor = tint
        replayGainCaption.stringValue = "RG\n\(value)"
        replayGainCaption.textColor = tint
        replayGainButton.setAccessibilityLabel("ReplayGain Mode")
        replayGainButton.setAccessibilityValue(value)
    }

    func setPrivateMode(_ enabled: Bool) {
        isPrivateMode = enabled
        privateModeButton.image = NSImage(
            systemSymbolName: enabled ? "eye.slash.fill" : "eye",
            accessibilityDescription: "Private Listening"
        )
        privateModeButton.contentTintColor = enabled ? AppTheme.accent : AppTheme.secondaryText
        privateModeButton.toolTip = enabled
            ? "Private listening is on; click to record listening again"
            : "Private listening is off; click to stop recording listening"
        privateModeButton.setAccessibilityLabel("Private Listening")
        privateModeButton.setAccessibilityValue(enabled ? "On" : "Off")
    }

    @objc private func togglePlayback() {
        onTogglePlayback?()
    }

    @objc private func previousPlayback() {
        onPreviousPlayback?()
    }

    @objc private func nextPlayback() {
        onNextPlayback?()
    }

    @objc private func toggleShuffle() {
        onToggleShuffle?()
    }

    @objc private func cycleRepeatMode() {
        onCycleRepeatMode?()
    }

    @objc private func cycleReplayGainMode() {
        onCycleReplayGainMode?()
    }

    @objc private func toggleEQ() {
        onEqualizerRequested?()
    }

    @objc private func changeOutputDevice() {
        onOutputDeviceRequested?(outputButton)
    }

    @objc private func togglePrivateMode() {
        onTogglePrivateMode?()
    }

    @objc private func showSkipSegments() {
        onSkipSegmentsRequested?()
    }

    func updateThemeAppearance() {
        updateEQButton()
    }

    private func updateEQButton() {
        eqButton.title = "EQ"
        eqButton.image = nil
        eqButton.contentTintColor = isEQEnabled
            ? AppTheme.accent
            : AppTheme.appearance == .amoled ? .white : AppTheme.secondaryText
    }

    private func updateRepeatButton() {
        repeatButton.image = NSImage(
            systemSymbolName: repeatMode == .one ? "repeat.1" : "repeat",
            accessibilityDescription: "Repeat"
        )
        repeatButton.contentTintColor = repeatMode == .off ? AppTheme.secondaryText : AppTheme.accent
        switch repeatMode {
        case .off:
            repeatButton.title = "Off"
            repeatButton.toolTip = "Repeat is off"
            repeatButton.setAccessibilityLabel("Repeat Off")
        case .all:
            repeatButton.title = "All"
            repeatButton.toolTip = "Repeat all tracks"
            repeatButton.setAccessibilityLabel("Repeat All")
        case .one:
            repeatButton.title = "One"
            repeatButton.toolTip = "Repeat current track"
            repeatButton.setAccessibilityLabel("Repeat One")
        }
    }
}
