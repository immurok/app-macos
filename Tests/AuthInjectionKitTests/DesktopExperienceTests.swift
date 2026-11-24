import XCTest
@testable import AuthInjectionKit

final class DesktopExperienceTests: XCTestCase {
    func testSSHOnlyNeedsNeitherPasswordNorAccessibilityNorPAM() {
        let plan = SetupPlan(features: [.ssh])
        XCTAssertFalse(plan.needsPassword)
        XCTAssertFalse(plan.needsAccessibility)
        XCTAssertFalse(plan.needsPAM)
    }
    func testAdministratorNeedsPAMButNoSavedPassword() {
        let plan = SetupPlan(features: [.administrator])
        XCTAssertTrue(plan.needsPAM)
        XCTAssertFalse(plan.needsPassword)
        XCTAssertFalse(plan.needsAccessibility)
    }
    func testReadinessNeverTreatsConnectionAsVerification() {
        var input = DeviceReadinessInput()
        input.connected = true
        input.paired = true
        input.fingerprintCount = 1
        input.features = [.ssh]
        XCTAssertEqual(input.status, .unverified)
        input.verified = true
        XCTAssertEqual(input.status, .ready)
        input.features.insert(.screenUnlock)
        XCTAssertEqual(input.status, .password)
        input.hasPassword = true
        XCTAssertEqual(input.status, .accessibility)
        input.accessibility = true
        XCTAssertEqual(input.status, .ready)
        input.passwordSuspended = true
        XCTAssertEqual(input.status, .password)
        input.permissionDenied = true
        XCTAssertEqual(input.status, .bluetoothPermission)
    }
    func testPAMAndBatteryReadinessAreIndependent() {
        var input = DeviceReadinessInput()
        input.connected = true; input.paired = true; input.verified = true
        input.fingerprintCount = 1; input.features = [.administrator]; input.battery = 10
        XCTAssertEqual(input.status, .administrator)
        input.pamReady = true
        XCTAssertEqual(input.status, .lowBattery)
        input.battery = 75
        XCTAssertEqual(input.status, .ready)
    }
    func testCommandPresentationExposesHiddenControlsAndPreservesLongText() {
        XCTAssertEqual(ApprovalPresentation.visible("echo\nhello\u{202E}"), "echo\\u{000A}hello\\u{202E}")
        let command = String(repeating: "a", count: 1000) + " --delete"
        XCTAssertEqual(ApprovalPresentation.visible(command), command)
    }
}
