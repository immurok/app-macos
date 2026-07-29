import XCTest
@testable import AuthInjectionKit

final class InjectionPolicyTests: XCTestCase {
    func testApplePlatformRequirementString() {
        let req = SigningRequirement.applePlatform
        XCTAssertEqual(req.securityRequirementString(bundleID: "com.apple.AppStore"),
                       "anchor apple and identifier \"com.apple.AppStore\"")
    }

    func testDeveloperIDRequirementString() {
        let req = SigningRequirement.developerID(teamID: "2BUA8C4S2C")
        XCTAssertEqual(req.securityRequirementString(bundleID: "com.1password.1password"),
                       "anchor apple generic and identifier \"com.1password.1password\" and certificate leaf[subject.OU] = \"2BUA8C4S2C\"")
    }

    func testTableHasAppleEntries() {
        XCTAssertEqual(InjectionPolicy.entry(forBundleID: "com.apple.AppStore")?.kind, .appleIDPassword)
        XCTAssertEqual(InjectionPolicy.entry(forBundleID: "com.apple.AppStore")?.signing, .applePlatform)
        XCTAssertEqual(InjectionPolicy.entry(forBundleID: "com.apple.Passwords")?.kind, .loginPassword)
        XCTAssertEqual(InjectionPolicy.entry(forBundleID: "com.apple.AuthKitUI.AKAuthorizationRemoteViewService")?.kind, .loginPassword)
    }

    func testTableHasOnePasswordEntry() {
        let e = InjectionPolicy.entry(forBundleID: "com.1password.1password")
        XCTAssertEqual(e?.kind, .onePasswordPassword)
        XCTAssertEqual(e?.signing, .developerID(teamID: "2BUA8C4S2C"))
    }

    func testUnknownBundleReturnsNil() {
        XCTAssertNil(InjectionPolicy.entry(forBundleID: "com.google.Chrome"))
        XCTAssertNil(InjectionPolicy.entry(forBundleID: "com.evil.fake"))
    }
}
