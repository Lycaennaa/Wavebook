import AppKit

private final class PlaylistEditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func performClose(_ sender: Any?) {
        close()
    }
}

private final class PlaylistEditorPanelSurfaceView: ThemeBackgroundView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = 16
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        updateBorder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func themeDidChange() {
        super.themeDidChange()
        updateBorder()
    }

    private func updateBorder() {
        layer?.borderColor = AppTheme.cgColor(AppTheme.border, in: self)
    }
}

@MainActor
final class PlaylistEditorPanelController: NSWindowController, NSWindowDelegate {
    private let editor: PlaylistEditorView
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var isModalRunning = false

    init(title: String, editor: PlaylistEditorView) {
        self.editor = editor
        let panel = PlaylistEditorPanel(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 470),
            styleMask: [.borderless, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.appearance = AppTheme.appearance.nsAppearance
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .modalPanel
        super.init(window: panel)
        panel.isReleasedWhenClosed = true
        panel.delegate = self
        configureButtons()
        panel.contentView = makeContentView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func run() -> PlaylistEditorValues? {
        guard let panel = window else { return nil }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        editor.focusNameField()
        isModalRunning = true
        let response = NSApp.runModal(for: panel)
        isModalRunning = false
        panel.close()
        guard response == .OK else { return nil }
        return editor.values
    }

    private func configureButtons() {
        saveButton.bezelStyle = .rounded
        saveButton.bezelColor = AppTheme.accent
        saveButton.contentTintColor = .white
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.setAccessibilityLabel("Save Playlist")
        saveButton.widthAnchor.constraint(equalToConstant: 110).isActive = true
        saveButton.heightAnchor.constraint(equalToConstant: 30).isActive = true

        cancelButton.bezelStyle = .rounded
        cancelButton.bezelColor = AppTheme.raised
        cancelButton.contentTintColor = AppTheme.primaryText
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.setAccessibilityLabel("Cancel")
        cancelButton.widthAnchor.constraint(equalToConstant: 110).isActive = true
        cancelButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    private func makeContentView() -> NSView {
        let root = PlaylistEditorPanelSurfaceView()

        let iconView = NSImageView(image: NSApp.applicationIconImage)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityLabel("Wavebook")
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: window?.title ?? "")
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = AppTheme.primaryText
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let buttonStack = NSStackView(views: [cancelButton, saveButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 10
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        editor.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(iconView)
        root.addSubview(titleLabel)
        root.addSubview(editor)
        root.addSubview(buttonStack)
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            iconView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 52),
            iconView.heightAnchor.constraint(equalToConstant: 52),
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            editor.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            editor.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            editor.widthAnchor.constraint(equalToConstant: PlaylistEditorView.preferredWidth),
            buttonStack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8)
        ])
        return root
    }

    private func finish(with response: NSApplication.ModalResponse) {
        guard isModalRunning else { return }
        NSApp.stopModal(withCode: response)
    }

    @objc private func save() {
        finish(with: .OK)
    }

    @objc private func cancel() {
        finish(with: .cancel)
    }

    func windowWillClose(_ notification: Notification) {
        finish(with: .cancel)
    }
}
