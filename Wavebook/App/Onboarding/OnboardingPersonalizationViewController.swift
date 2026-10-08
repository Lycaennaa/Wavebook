import AppKit
import WavebookCore

@MainActor
final class OnboardingPersonalizationViewController: NSViewController {
    private let onAppearanceChanged: (AppAppearance) -> Void
    private let onReplayGainModeChanged: (ReplayGainMode) -> Bool
    private let onSkipSilentSegmentsChanged: (Bool) -> Bool
    private let onAutoContinuePlaybackAfterOutputChange: (Bool) -> Bool
    private let onOpenEqualizer: () -> Void
    private let onBack: () -> Void
    private let onReturnToLibrary: () -> Void
    private let appearance: AppAppearance
    private var replayGainMode: ReplayGainMode
    private var skipSilentSegments: Bool
    private var autoContinuePlaybackAfterOutputChange: Bool

    private let titleLabel = NSTextField(labelWithString: "Make Wavebook yours")
    private let descriptionLabel = NSTextField(
        wrappingLabelWithString: "Choose how Wavebook looks and handles playback. Changes apply immediately."
    )
    private let appearancePopup = NSPopUpButton()
    private let appearanceDescription = NSTextField(
        wrappingLabelWithString: "System is the default; Light, Dark, and AMOLED Black are also available."
    )
    private let replayGainPopup = NSPopUpButton()
    private let replayGainDescription = NSTextField(
        wrappingLabelWithString:
            "Keeps songs from suddenly sounding much louder or quieter. "
                + "Track balances each song; Album preserves an album's volume differences; Off makes no changes."
    )
    private let skipSilentSegmentsButton = NSButton(
        checkboxWithTitle: "Skip silence at the start and end of songs",
        target: nil,
        action: nil
    )
    private let autoContinuePlaybackAfterOutputChangeButton = NSButton(
        checkboxWithTitle: "Continue playback after output changes",
        target: nil,
        action: nil
    )
    private let equalizerButton = NSButton(title: "Open 31-band EQ…", target: nil, action: nil)
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let skipStepButton = NSButton(title: "Skip Step", target: nil, action: nil)
    private let exitButton = NSButton(title: "Exit Onboarding", target: nil, action: nil)
    private let finishButton = NSButton(title: "Finish", target: nil, action: nil)

    init(
        appearance: AppAppearance,
        replayGainMode: ReplayGainMode,
        skipSilentSegments: Bool,
        autoContinuePlaybackAfterOutputChange: Bool,
        onAppearanceChanged: @escaping (AppAppearance) -> Void,
        onReplayGainModeChanged: @escaping (ReplayGainMode) -> Bool,
        onSkipSilentSegmentsChanged: @escaping (Bool) -> Bool,
        onAutoContinuePlaybackAfterOutputChange: @escaping (Bool) -> Bool,
        onOpenEqualizer: @escaping () -> Void,
        onBack: @escaping () -> Void,
        onReturnToLibrary: @escaping () -> Void
    ) {
        self.appearance = appearance
        self.replayGainMode = replayGainMode
        self.skipSilentSegments = skipSilentSegments
        self.autoContinuePlaybackAfterOutputChange = autoContinuePlaybackAfterOutputChange
        self.onAppearanceChanged = onAppearanceChanged
        self.onReplayGainModeChanged = onReplayGainModeChanged
        self.onSkipSilentSegmentsChanged = onSkipSilentSegmentsChanged
        self.onAutoContinuePlaybackAfterOutputChange = onAutoContinuePlaybackAfterOutputChange
        self.onOpenEqualizer = onOpenEqualizer
        self.onBack = onBack
        self.onReturnToLibrary = onReturnToLibrary
        super.init(nibName: nil, bundle: nil)
        skipSilentSegmentsButton.state = skipSilentSegments ? .on : .off
        autoContinuePlaybackAfterOutputChangeButton.state = autoContinuePlaybackAfterOutputChange ? .on : .off
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        configureControls()
        let root = ThemeBackgroundView()
        let content = makeContent()
        root.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            content.widthAnchor.constraint(equalToConstant: 620)
        ])
        view = root
    }

    private func configureControls() {
        titleLabel.font = .systemFont(ofSize: 26, weight: .semibold)
        titleLabel.textColor = AppTheme.primaryText
        descriptionLabel.font = .systemFont(ofSize: 14)
        descriptionLabel.textColor = AppTheme.secondaryText
        descriptionLabel.alignment = .center
        descriptionLabel.maximumNumberOfLines = 0
        descriptionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 600).isActive = true

        appearancePopup.addItems(withTitles: AppAppearance.allCases.map(\.title))
        for (item, value) in zip(appearancePopup.itemArray, AppAppearance.allCases) {
            item.representedObject = value
        }
        select(appearance, in: appearancePopup)
        appearancePopup.target = self
        appearancePopup.action = #selector(appearanceChanged)
        appearancePopup.setAccessibilityLabel("Interface Appearance")
        appearanceDescription.font = .systemFont(ofSize: 12)
        appearanceDescription.textColor = AppTheme.secondaryText
        appearanceDescription.maximumNumberOfLines = 0

        replayGainPopup.addItems(withTitles: ReplayGainMode.allCases.map { title(for: $0) })
        for (item, value) in zip(replayGainPopup.itemArray, ReplayGainMode.allCases) {
            item.representedObject = value
        }
        select(replayGainMode, in: replayGainPopup)
        replayGainPopup.target = self
        replayGainPopup.action = #selector(replayGainModeChanged)
        replayGainPopup.setAccessibilityLabel("ReplayGain Mode")
        replayGainDescription.font = .systemFont(ofSize: 12)
        replayGainDescription.textColor = AppTheme.secondaryText
        replayGainDescription.maximumNumberOfLines = 0

        skipSilentSegmentsButton.target = self
        skipSilentSegmentsButton.action = #selector(skipSilentSegmentsChanged)
        skipSilentSegmentsButton.contentTintColor = AppTheme.accent
        skipSilentSegmentsButton.setAccessibilityHelp(
            "Skip detected silence at the beginning and end of each song."
        )
        autoContinuePlaybackAfterOutputChangeButton.target = self
        autoContinuePlaybackAfterOutputChangeButton.action = #selector(autoContinuePlaybackAfterOutputChangeChanged)
        autoContinuePlaybackAfterOutputChangeButton.contentTintColor = AppTheme.accent
        autoContinuePlaybackAfterOutputChangeButton.setAccessibilityHelp(
            "Automatically resume the current song at its current position after the audio output changes."
        )

        equalizerButton.target = self
        equalizerButton.action = #selector(openEqualizer)
        equalizerButton.bezelStyle = .rounded
        equalizerButton.contentTintColor = AppTheme.accent
        equalizerButton.setAccessibilityHelp("Open the existing 31-band equalizer editor.")

        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.bezelStyle = .rounded
        skipStepButton.target = self
        skipStepButton.action = #selector(returnToLibrary)
        skipStepButton.bezelStyle = .rounded
        exitButton.target = self
        exitButton.action = #selector(returnToLibrary)
        exitButton.bezelStyle = .rounded
        finishButton.target = self
        finishButton.action = #selector(returnToLibrary)
        finishButton.bezelStyle = .rounded
        finishButton.keyEquivalent = "\r"
        finishButton.contentTintColor = AppTheme.accent
    }

    private func makeContent() -> NSStackView {
        let appearanceLabel = NSTextField(labelWithString: "Appearance")
        appearanceLabel.textColor = AppTheme.secondaryText
        let appearanceRow = NSStackView(views: [appearanceLabel, appearancePopup])
        appearanceRow.orientation = .horizontal
        appearanceRow.alignment = .centerY
        appearanceRow.spacing = 14
        appearancePopup.widthAnchor.constraint(equalToConstant: 190).isActive = true
        let appearanceSection = NSStackView(views: [appearanceRow, appearanceDescription])
        appearanceSection.orientation = .vertical
        appearanceSection.alignment = .leading
        appearanceSection.spacing = 7

        let replayGainLabel = NSTextField(labelWithString: "ReplayGain")
        replayGainLabel.textColor = AppTheme.secondaryText
        let replayGainSection = NSStackView(views: [replayGainLabel, replayGainPopup, replayGainDescription])
        replayGainSection.orientation = .vertical
        replayGainSection.alignment = .leading
        replayGainSection.spacing = 7
        replayGainPopup.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let equalizerDescription = NSTextField(
            wrappingLabelWithString:
                "Make the sound your own with the 31-band EQ. "
                    + "Your personal EQ settings are saved separately for each output device."
        )
        equalizerDescription.textColor = AppTheme.secondaryText
        equalizerDescription.maximumNumberOfLines = 0
        let equalizerSection = NSStackView(views: [equalizerDescription, equalizerButton])
        equalizerSection.orientation = .vertical
        equalizerSection.alignment = .leading
        equalizerSection.spacing = 7

        let navigation = NSStackView(views: [backButton, skipStepButton, exitButton, finishButton])
        navigation.orientation = .horizontal
        navigation.alignment = .centerY
        navigation.spacing = 10
        let content = NSStackView(views: [
            titleLabel, descriptionLabel, appearanceSection, replayGainSection,
            skipSilentSegmentsButton, autoContinuePlaybackAfterOutputChangeButton, equalizerSection, navigation
        ])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 16
        appearanceSection.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        appearanceRow.widthAnchor.constraint(equalTo: appearanceSection.widthAnchor).isActive = true
        appearanceDescription.widthAnchor.constraint(equalTo: appearanceSection.widthAnchor).isActive = true
        replayGainSection.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        replayGainDescription.widthAnchor.constraint(equalTo: replayGainSection.widthAnchor).isActive = true
        skipSilentSegmentsButton.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        autoContinuePlaybackAfterOutputChangeButton.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        equalizerSection.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        equalizerDescription.widthAnchor.constraint(equalTo: equalizerSection.widthAnchor).isActive = true
        navigation.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        return content
    }

    @objc private func appearanceChanged() {
        guard let appearance = appearancePopup.selectedItem?.representedObject as? AppAppearance else { return }
        onAppearanceChanged(appearance)
    }

    @objc private func replayGainModeChanged() {
        guard let mode = replayGainPopup.selectedItem?.representedObject as? ReplayGainMode else { return }
        guard onReplayGainModeChanged(mode) else {
            select(replayGainMode, in: replayGainPopup)
            return
        }
        replayGainMode = mode
    }

    @objc private func skipSilentSegmentsChanged() {
        let enabled = skipSilentSegmentsButton.state == .on
        guard onSkipSilentSegmentsChanged(enabled) else {
            skipSilentSegmentsButton.state = skipSilentSegments ? .on : .off
            return
        }
        skipSilentSegments = enabled
    }

    @objc private func autoContinuePlaybackAfterOutputChangeChanged() {
        let enabled = autoContinuePlaybackAfterOutputChangeButton.state == .on
        guard onAutoContinuePlaybackAfterOutputChange(enabled) else {
            autoContinuePlaybackAfterOutputChangeButton.state = autoContinuePlaybackAfterOutputChange ? .on : .off
            return
        }
        autoContinuePlaybackAfterOutputChange = enabled
    }

    @objc private func openEqualizer() {
        onOpenEqualizer()
    }

    @objc private func goBack() {
        onBack()
    }

    @objc private func returnToLibrary() {
        onReturnToLibrary()
    }

    private func select(_ appearance: AppAppearance, in popup: NSPopUpButton) {
        guard let index = popup.itemArray.firstIndex(where: {
            ($0.representedObject as? AppAppearance) == appearance
        }) else { return }
        popup.selectItem(at: index)
    }

    private func select(_ mode: ReplayGainMode, in popup: NSPopUpButton) {
        guard let index = popup.itemArray.firstIndex(where: {
            ($0.representedObject as? ReplayGainMode) == mode
        }) else { return }
        popup.selectItem(at: index)
    }

    private func title(for mode: ReplayGainMode) -> String {
        switch mode {
        case .off: "Off"
        case .track: "Track"
        case .album: "Album"
        }
    }
}
