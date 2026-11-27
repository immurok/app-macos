import XCTest
@testable import immurokApp

final class SecurityDefaultsTests: XCTestCase {
    func testNewInstallRequiresOptInAndPreservesExistingChoices() {
        let suite = "com.immurok.tests.SecurityDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        AppDefaults.register(in: defaults)
        for feature in ["screenUnlockEnabled", "passwordsFillEnabled", "sshAgentEnabled",
                        "cliEnabled", "quickFillEnabled", "automaticUpdateChecks", "keepAwakeDuringDisplaySleep"] {
            XCTAssertFalse(defaults.bool(forKey: "immurok.\(feature)"), feature)
        }
        defaults.set(true, forKey: "immurok.sshAgentEnabled")
        AppDefaults.register(in: defaults)
        XCTAssertTrue(defaults.bool(forKey: "immurok.sshAgentEnabled"))
    }
}
