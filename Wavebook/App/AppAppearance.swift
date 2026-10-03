import AppKit

enum AppAppearance: String, CaseIterable, Sendable {
    case system
    case light
    case dark
    case amoled

    var title: String {
        switch self {
        case .system: "System (Apple)"
        case .light: "Light"
        case .dark: "Dark"
        case .amoled: "AMOLED Black"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark, .amoled: NSAppearance(named: .darkAqua)
        }
    }
}
