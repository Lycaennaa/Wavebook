import AppKit

@MainActor
final class OnboardingWelcomeViewController: NSViewController {
    private var copy: OnboardingCopy
    private let onChooseFolders: () -> Void
    private let onExit: () -> Void
    private let titleLabel = NSTextField(labelWithString: "")
    private let libraryDescription = NSTextField(wrappingLabelWithString: "")
    private let featureDescription = NSTextField(wrappingLabelWithString: "")
    private let folderAccessDescription = NSTextField(wrappingLabelWithString: "")
    private let chooseFoldersButton = NSButton(title: "", target: nil, action: nil)
    private let exitButton = NSButton(title: "", target: nil, action: nil)

    init(copy: OnboardingCopy, onChooseFolders: @escaping () -> Void, onExit: @escaping () -> Void) {
        self.copy = copy
        self.onChooseFolders = onChooseFolders
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = ThemeBackgroundView()
        titleLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        titleLabel.textColor = AppTheme.primaryText
        titleLabel.alignment = .center

        libraryDescription.font = .systemFont(ofSize: 15)
        libraryDescription.textColor = AppTheme.secondaryText
        libraryDescription.alignment = .center
        libraryDescription.maximumNumberOfLines = 0
        libraryDescription.widthAnchor.constraint(lessThanOrEqualToConstant: 520).isActive = true

        featureDescription.font = .systemFont(ofSize: 13)
        featureDescription.textColor = AppTheme.secondaryText
        featureDescription.alignment = .center
        featureDescription.maximumNumberOfLines = 0
        featureDescription.widthAnchor.constraint(lessThanOrEqualToConstant: 600).isActive = true
        folderAccessDescription.font = .systemFont(ofSize: 12)
        folderAccessDescription.textColor = AppTheme.secondaryText
        folderAccessDescription.alignment = .center
        folderAccessDescription.maximumNumberOfLines = 0
        folderAccessDescription.widthAnchor.constraint(lessThanOrEqualToConstant: 520).isActive = true

        chooseFoldersButton.target = self
        chooseFoldersButton.action = #selector(chooseFolders(_:))
        chooseFoldersButton.bezelStyle = .rounded
        chooseFoldersButton.keyEquivalent = "\r"

        exitButton.target = self
        exitButton.action = #selector(exitOnboarding(_:))
        exitButton.bezelStyle = .rounded

        applyCopy()

        let buttons = NSStackView(views: [chooseFoldersButton, exitButton])
        buttons.orientation = .vertical
        buttons.alignment = .centerX
        buttons.spacing = 10

        let content = NSStackView(
            views: [titleLabel, libraryDescription, featureDescription, folderAccessDescription, buttons]
        )
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 18
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)

        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 32),
            content.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -32),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        ])
        view = root
    }

    func update(copy: OnboardingCopy) {
        self.copy = copy
        guard isViewLoaded else { return }
        applyCopy()
    }

    private func applyCopy() {
        titleLabel.stringValue = copy.welcome.title
        libraryDescription.stringValue = copy.welcome.libraryDescription
        featureDescription.stringValue = copy.welcome.featureDescription
        folderAccessDescription.stringValue = copy.welcome.folderAccessDescription
        chooseFoldersButton.title = copy.welcome.chooseFoldersButtonTitle
        chooseFoldersButton.setAccessibilityHelp(copy.welcome.chooseFoldersAccessibilityHelp)
        exitButton.title = copy.welcome.exitButtonTitle
        exitButton.setAccessibilityHelp(copy.welcome.exitAccessibilityHelp)
    }

    @objc private func chooseFolders(_ sender: Any?) {
        onChooseFolders()
    }

    @objc private func exitOnboarding(_ sender: Any?) {
        onExit()
    }
}
