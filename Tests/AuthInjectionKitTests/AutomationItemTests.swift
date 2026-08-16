import XCTest
@testable import AuthInjectionKit

final class AutomationItemTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let item = AutomationItem(
            id: UUID(), name: "My App", enabled: true, builtinKey: nil,
            targetKind: .app, bundleIDs: ["com.example.app"],
            signing: .developerID(teamID: "ABCDE12345"),
            extensionOrigin: nil, urlFragment: nil,
            fieldAXIdentifier: "pwField", submitStrategy: .generic)
        let data = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(AutomationItem.self, from: data), item)
    }
    func testBuiltinSecretServiceMapping() {
        let items = AutomationItem.builtinDefaults()
        let byKey = Dictionary(uniqueKeysWithValues: items.map { ($0.builtinKey!, $0) })
        XCTAssertEqual(byKey["appstore"]!.secretService, "com.immurok.appleid-password")
        XCTAssertEqual(byKey["passwords"]!.secretService, "com.immurok.password")
        XCTAssertEqual(byKey["1password"]!.secretService, "com.immurok.onepassword-password")
        XCTAssertEqual(byKey["bitwarden"]!.secretService, "com.immurok.bitwarden-password")
    }
    func testCustomSecretServiceUsesUUID() {
        let id = UUID()
        let item = AutomationItem(id: id, name: "x", enabled: true, builtinKey: nil,
            targetKind: .app, bundleIDs: ["com.x.y"], signing: .applePlatform,
            extensionOrigin: nil, urlFragment: nil, fieldAXIdentifier: nil, submitStrategy: .generic)
        XCTAssertEqual(item.secretService, "com.immurok.automation.\(id.uuidString)")
    }
    func testBuiltinDefaultsShape() {
        let items = AutomationItem.builtinDefaults()
        XCTAssertEqual(Set(items.map { $0.builtinKey }), ["appstore", "passwords", "1password", "bitwarden"])
        let pw = items.first { $0.builtinKey == "passwords" }!
        XCTAssertTrue(pw.bundleIDs.contains("com.apple.Passwords"))
        XCTAssertTrue(pw.bundleIDs.contains("com.apple.AuthKitUI.AKAuthorizationRemoteViewService"))
        let bw = items.first { $0.builtinKey == "bitwarden" }!
        XCTAssertEqual(bw.targetKind, .browserExtension)
        XCTAssertEqual(bw.submitStrategy, .belowButton)
    }
    func testMatchesAndValidity() {
        let item = AutomationItem.builtinDefaults().first { $0.builtinKey == "1password" }!
        XCTAssertTrue(item.matches(bundleID: "com.1password.1password"))
        XCTAssertFalse(item.matches(bundleID: "com.other"))
        XCTAssertTrue(item.isValid)
        var bad = item; bad.bundleIDs = ["bad\" injection"]
        XCTAssertFalse(bad.isValid)
    }
}
