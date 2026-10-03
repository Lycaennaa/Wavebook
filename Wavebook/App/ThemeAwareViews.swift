import AppKit

private nonisolated final class ThemeChangeObserver {
    private var observer: NSObjectProtocol?

    init(
        name: Notification.Name,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        observer = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                onChange()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

class ThemeAwareView: NSView {
    var onThemeChange: (() -> Void)?
    private var themeObserver: ThemeChangeObserver?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        themeObserver = ThemeChangeObserver(name: AppTheme.appearanceDidChange) { [weak self] in
            self?.refreshTheme()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTheme()
    }

    func themeDidChange() {}

    private func refreshTheme() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            themeDidChange()
            needsDisplay = true
            onThemeChange?()
        }
    }
}

class ThemeAwareControl: NSControl {
    var onThemeChange: (() -> Void)?
    private var themeObserver: ThemeChangeObserver?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        themeObserver = ThemeChangeObserver(name: AppTheme.appearanceDidChange) { [weak self] in
            self?.refreshTheme()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTheme()
    }

    func themeDidChange() {}

    private func refreshTheme() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            themeDidChange()
            needsDisplay = true
            onThemeChange?()
        }
    }
}

class ThemeBackgroundView: ThemeAwareView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppTheme.cgColor(AppTheme.background, in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func themeDidChange() {
        super.themeDidChange()
        layer?.backgroundColor = AppTheme.cgColor(AppTheme.background, in: self)
    }
}
