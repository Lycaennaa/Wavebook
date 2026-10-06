import Foundation

struct OnboardingCopy: Decodable {
    struct Welcome: Decodable {
        let title: String
        let libraryDescription: String
        let featureDescription: String
        let folderAccessDescription: String
        let chooseFoldersButtonTitle: String
        let chooseFoldersAccessibilityHelp: String
        let exitButtonTitle: String
        let exitAccessibilityHelp: String
    }

    let welcome: Welcome

    static let fallback = OnboardingCopy(
        welcome: Welcome(
            title: "Welcome to Wavebook",
            libraryDescription: "Browse by song, artist, album, or genre.",
            featureDescription: "Adjust playback with the equalizer and ReplayGain. "
                + "With offline lyrics and optional online search.",
            folderAccessDescription: "Wavebook scans only selected folders. Audio files are not moved or deleted.",
            chooseFoldersButtonTitle: "Choose Music Folders…",
            chooseFoldersAccessibilityHelp: "Choose one or more local folders to scan.",
            exitButtonTitle: "Exit Onboarding",
            exitAccessibilityHelp: "Open Wavebook without selecting music folders."
        )
    )

    static func bundled() -> Self {
        guard let url = Bundle.main.url(forResource: "OnboardingCopy", withExtension: "json"),
              let copy = try? load(from: url) else {
            return fallback
        }
        return copy
    }

    static func load(from url: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
