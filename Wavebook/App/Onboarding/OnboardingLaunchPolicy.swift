import Foundation

enum OnboardingLaunchPolicy {
    private static let firstLaunchHandledKey = "Wavebook.onboarding.firstLaunchHandled"

    static func shouldShowWelcome(
        using defaults: UserDefaults = .standard,
        isLegacyInstall: () -> Bool
    ) -> Bool {
        guard defaults.object(forKey: firstLaunchHandledKey) == nil else { return false }
        let shouldShowWelcome = !isLegacyInstall()
        defaults.set(true, forKey: firstLaunchHandledKey)
        return shouldShowWelcome
    }
}
