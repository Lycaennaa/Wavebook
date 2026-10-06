import XCTest

final class OnboardingLaunchPolicyTests: XCTestCase {
    func testFreshInstallShowsWelcomeOnlyOnce() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(OnboardingLaunchPolicy.shouldShowWelcome(using: defaults) { false })
        var checkedLegacyInstall = false
        XCTAssertFalse(OnboardingLaunchPolicy.shouldShowWelcome(using: defaults) {
            checkedLegacyInstall = true
            return false
        })
        XCTAssertFalse(checkedLegacyInstall)
    }

    func testLegacyInstallSkipsWelcomeAndRecordsDecision() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(OnboardingLaunchPolicy.shouldShowWelcome(using: defaults) { true })
        var checkedLegacyInstall = false
        XCTAssertFalse(OnboardingLaunchPolicy.shouldShowWelcome(using: defaults) {
            checkedLegacyInstall = true
            return false
        })
        XCTAssertFalse(checkedLegacyInstall)
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "OnboardingLaunchPolicyTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName)
    }
}
