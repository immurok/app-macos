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
        XCTAssertTrue(byKey["passwords"]!.usesLoginPassword)
        XCTAssertFalse(byKey["1password"]!.usesLoginPassword)
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
        XCTAssertEqual(Set(items.map { $0.builtinKey }), ["appstore", "passwords", "touchid", "1password", "bitwarden"])
        // Touch ID auto-fill 紧跟 Passwords，复用登录密码。
        let keys = items.map { $0.builtinKey! }
        XCTAssertEqual(keys.firstIndex(of: "touchid"), keys.firstIndex(of: "passwords")! + 1)
        let tid = items.first { $0.isTouchIDAutoFill }!
        XCTAssertEqual(tid.name, "Touch ID auto-fill")
        XCTAssertEqual(tid.secretService, "com.immurok.password")
        XCTAssertTrue(tid.usesLoginPassword)
        XCTAssertEqual(tid.bundleIDs, [AutomationItem.localAuthUIAgentBundleID])
        // 老存盘（无 touchid）刷新后，新条目插在 Passwords 之后而不是末尾。
        let old = items.filter { !$0.isTouchIDAutoFill }
        let refreshedKeys = AutomationItem.refreshingBuiltinIdentity(old).map { $0.builtinKey! }
        XCTAssertEqual(refreshedKeys, ["appstore", "passwords", "touchid", "1password", "bitwarden"])
        let pw = items.first { $0.builtinKey == "passwords" }!
        XCTAssertTrue(pw.bundleIDs.contains("com.apple.Passwords"))
        XCTAssertTrue(pw.bundleIDs.contains("com.apple.AuthKitUI.AKAuthorizationRemoteViewService"))
        let bw = items.first { $0.builtinKey == "bitwarden" }!
        XCTAssertEqual(bw.targetKind, .browserExtension)
        XCTAssertEqual(bw.submitStrategy, .belowButton)
    }
    func testPasswordsBuiltinCoversSafariHostedUnlock() {
        // Safari 内的 Passwords 解锁 sheet（如 Safari 设置 → 密码）密码框属主是 com.apple.Safari，
        // 条目必须覆盖它才能被 AuthContextDetector 命中。
        let pw = AutomationItem.builtinDefaults().first { $0.builtinKey == "passwords" }!
        XCTAssertTrue(pw.bundleIDs.contains("com.apple.Safari"))
        XCTAssertTrue(pw.isValid)
    }

    func testPasswordsBuiltinCoversPasskeySheetInThirdPartyBrowsers() {
        // Chrome 等用 Apple Passwords 通行密钥登录时，要 Mac 账户密码的 sheet 里，
        // 密码框属主是 AuthenticationServices.Helper（实测 2026-11-23，macOS 27）。
        let pw = AutomationItem.builtinDefaults().first { $0.builtinKey == "passwords" }!
        XCTAssertTrue(pw.bundleIDs.contains("com.apple.AuthenticationServices.Helper"))
        XCTAssertTrue(pw.isValid)
    }

    func testRefreshBuiltinIdentityUpdatesStoredItems() {
        // 存盘的旧内置项（bundleIDs 缺 Safari）刷新后拿到新身份，但保留 id/enabled。
        let defaults = AutomationItem.builtinDefaults()
        var oldPw = defaults.first { $0.builtinKey == "passwords" }!
        let keptID = UUID()
        oldPw.id = keptID
        oldPw.enabled = true
        oldPw.bundleIDs = ["com.apple.Passwords"]   // 模拟旧版存盘
        let custom = AutomationItem(id: UUID(), name: "Mine", enabled: true, builtinKey: nil,
            targetKind: .app, bundleIDs: ["com.example.app"], signing: .applePlatform,
            extensionOrigin: nil, urlFragment: nil, fieldAXIdentifier: nil, submitStrategy: .generic)

        let refreshed = AutomationItem.refreshingBuiltinIdentity([oldPw, custom])

        let pw = refreshed.first { $0.builtinKey == "passwords" }!
        XCTAssertEqual(pw.id, keptID)
        XCTAssertTrue(pw.enabled)
        XCTAssertTrue(pw.bundleIDs.contains("com.apple.Safari"))
        // 自定义项原样保留
        XCTAssertEqual(refreshed.first { $0.builtinKey == nil }, custom)
        // 存盘里缺失的内置项被补上（enabled 默认 false）
        for key in ["appstore", "1password", "bitwarden"] {
            let added = refreshed.first { $0.builtinKey == key }
            XCTAssertNotNil(added, key)
            XCTAssertEqual(added?.enabled, false, key)
        }
    }

    func testMatchesAndValidity() {
        let item = AutomationItem.builtinDefaults().first { $0.builtinKey == "1password" }!
        XCTAssertTrue(item.matches(bundleID: "com.1password.1password"))
        XCTAssertFalse(item.matches(bundleID: "com.other"))
        XCTAssertTrue(item.isValid)
        var bad = item; bad.bundleIDs = ["bad\" injection"]
        XCTAssertFalse(bad.isValid)
    }

    func testRefreshDropsRetiredBuiltinItems() {
        // 旧版本存过、现已不在内置表里的内置项（如一度存在的 sysauth）刷新时被丢弃，
        // 否则它不可删、会一直留在列表里。
        let retired = AutomationItem(id: UUID(), name: "System Authentication", enabled: true, builtinKey: "sysauth",
            targetKind: .app, bundleIDs: ["com.apple.LocalAuthentication.UIAgent"], signing: .applePlatform,
            extensionOrigin: nil, urlFragment: nil, fieldAXIdentifier: nil, submitStrategy: .generic)
        let refreshed = AutomationItem.refreshingBuiltinIdentity(AutomationItem.builtinDefaults() + [retired])
        XCTAssertNil(refreshed.first { $0.builtinKey == "sysauth" })
        XCTAssertEqual(refreshed.count, AutomationItem.builtinDefaults().count)
    }
}
