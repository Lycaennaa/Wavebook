import AppKit

enum AppTheme {
    static let appearanceDidChange = Notification.Name("Wavebook.appearanceDidChange")

    private static let appearanceKey = "Wavebook.appearance"

    static var appearance: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: appearanceKey) ?? "") ?? .system
    }

    static func hasPersistedAppearance(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: appearanceKey) != nil
    }
    static let background = dynamicColor(named: "background") { mode, appearance in
        mode == .amoled ? .black : resolved(.windowBackgroundColor, with: appearance)
    }

    static let panel = dynamicColor(named: "panel") { mode, appearance in
        mode == .amoled
            ? NSColor(calibratedWhite: 0.035, alpha: 1)
            : resolved(.controlBackgroundColor, with: appearance)
    }

    static let raised = dynamicColor(named: "raised") { mode, appearance in
        guard mode != .amoled else { return NSColor(calibratedWhite: 0.07, alpha: 1) }
        let colors = NSColor.alternatingContentBackgroundColors
        return resolved(colors.last ?? .controlBackgroundColor, with: appearance)
    }

    static let border = NSColor.separatorColor
    static let primaryText = dynamicColor(named: "primaryText") { mode, appearance in
        mode == .amoled || isDark(appearance) ? .white : .black
    }
    static let secondaryText = primaryText
    static let accent = NSColor.controlAccentColor

    static let selection = dynamicColor(named: "selection") { mode, appearance in
        let color = resolved(mode == .amoled ? .systemMint : .selectedContentBackgroundColor, with: appearance)
        return color.withAlphaComponent(0.18)
    }

    static let skipSegment = NSColor.systemOrange
    static let textOnAccent = dynamicColor(named: "textOnAccent") { _, appearance in
        resolved(.selectedControlTextColor, with: appearance)
    }

    @MainActor
    static func applySavedAppearance() {
        apply(appearance)
    }

    @MainActor
    static func apply(_ appearance: AppAppearance) {
        UserDefaults.standard.set(appearance.rawValue, forKey: appearanceKey)
        let nsAppearance = appearance.nsAppearance
        NSApp.appearance = nsAppearance
        NSApp.windows.forEach { window in
            window.appearance = nsAppearance
            if window.isOpaque {
                window.backgroundColor = background
            }
            if let contentView = window.contentView {
                invalidate(contentView)
            }
        }
        NotificationCenter.default.post(name: appearanceDidChange, object: appearance)
    }

    @MainActor
    static func cgColor(_ color: NSColor, in view: NSView) -> CGColor? {
        var colorValue: CGColor?
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            colorValue = color.cgColor
        }
        return colorValue
    }

    private static func dynamicColor(
        named name: String,
        provider: @escaping (AppAppearance, NSAppearance) -> NSColor
    ) -> NSColor {
        NSColor(name: NSColor.Name("Wavebook.\(name)")) { effectiveAppearance in
            provider(AppTheme.appearance, effectiveAppearance)
        }
    }

    private static func resolved(_ color: NSColor, with appearance: NSAppearance) -> NSColor {
        var resolvedColor = color
        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = color.usingColorSpace(.deviceRGB) ?? color
        }
        return resolvedColor
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    @MainActor
    private static func invalidate(_ view: NSView) {
        view.needsDisplay = true
        view.subviews.forEach(invalidate)
    }
}
