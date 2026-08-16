import XCTest
@testable import AuthInjectionKit

final class IdentityValidationTests: XCTestCase {
    func testValidBundleID() {
        XCTAssertTrue(IdentityValidation.isValidBundleID("com.apple.AppStore"))
        XCTAssertTrue(IdentityValidation.isValidBundleID("company.thebrowser.Browser"))
    }
    func testRejectsInjectionInBundleID() {
        XCTAssertFalse(IdentityValidation.isValidBundleID("com.x\" or true"))
        XCTAssertFalse(IdentityValidation.isValidBundleID("com.x and certificate leaf"))
        XCTAssertFalse(IdentityValidation.isValidBundleID(""))
        XCTAssertFalse(IdentityValidation.isValidBundleID("com.x\\y"))
    }
    func testValidTeamID() {
        XCTAssertTrue(IdentityValidation.isValidTeamID("2BUA8C4S2C"))
        XCTAssertFalse(IdentityValidation.isValidTeamID("short"))
        XCTAssertFalse(IdentityValidation.isValidTeamID("2bua8c4s2c")) // 小写不允许
        XCTAssertFalse(IdentityValidation.isValidTeamID("2BUA8C4S2C\""))
    }
    func testValidatedRequirementStringRejectsBadInput() {
        XCTAssertNil(SigningRequirement.applePlatform.validatedRequirementString(bundleID: "bad\" x"))
        XCTAssertNil(SigningRequirement.developerID(teamID: "BAD").validatedRequirementString(bundleID: "com.ok.app"))
        XCTAssertEqual(
            SigningRequirement.applePlatform.validatedRequirementString(bundleID: "com.apple.AppStore"),
            "anchor apple and identifier \"com.apple.AppStore\"")
    }
    func testSigningRequirementCodableRoundTrip() throws {
        for req in [SigningRequirement.applePlatform, .developerID(teamID: "2BUA8C4S2C")] {
            let data = try JSONEncoder().encode(req)
            XCTAssertEqual(try JSONDecoder().decode(SigningRequirement.self, from: data), req)
        }
    }
}
