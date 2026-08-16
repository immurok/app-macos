import XCTest
@testable import AuthInjectionKit

final class AutomationCryptoTests: XCTestCase {
    private func samplePayload() -> AutomationExportPayload {
        let item = AutomationItem(id: UUID(), name: "X", enabled: true, builtinKey: nil,
            targetKind: .app, bundleIDs: ["com.x.y"], signing: .applePlatform,
            extensionOrigin: nil, urlFragment: nil, fieldAXIdentifier: nil, submitStrategy: .generic)
        return AutomationExportPayload(items: [item], secrets: [item.secretService: "s3cr3t"])
    }
    func testRoundTrip() throws {
        let payload = samplePayload()
        let blob = try AutomationCrypto.encrypt(payload, password: "hunter2")
        let back = try AutomationCrypto.decrypt(blob, password: "hunter2")
        XCTAssertEqual(back.items, payload.items)
        XCTAssertEqual(back.secrets, payload.secrets)
    }
    func testWrongPasswordFails() throws {
        let blob = try AutomationCrypto.encrypt(samplePayload(), password: "right")
        XCTAssertThrowsError(try AutomationCrypto.decrypt(blob, password: "wrong")) {
            XCTAssertEqual($0 as? AutomationCrypto.CryptoError, .wrongPasswordOrCorrupted)
        }
    }
    func testTamperDetected() throws {
        var blob = try AutomationCrypto.encrypt(samplePayload(), password: "pw")
        var obj = try JSONSerialization.jsonObject(with: blob) as! [String: Any]
        var ct = obj["ciphertext"] as! String
        let idx = ct.index(ct.startIndex, offsetBy: 4)
        ct.replaceSubrange(idx...idx, with: ct[idx] == "A" ? "B" : "A")
        obj["ciphertext"] = ct
        blob = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertThrowsError(try AutomationCrypto.decrypt(blob, password: "pw"))
    }
    func testRejectsBadContainer() {
        XCTAssertThrowsError(try AutomationCrypto.decrypt(Data("{}".utf8), password: "x"))
    }
}
