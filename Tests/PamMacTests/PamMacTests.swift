import XCTest
@testable import immurokApp

/// PAM 信道 MAC 与 C 侧共用同一份向量（app-macos/pam/vectors/pam-mac-v1.json）。
final class PamMacTests: XCTestCase {
    struct Vector: Decodable {
        let key: String, nonce: String, user: String, service: String, key_id: String, mac: String
    }
    struct File: Decodable { let version: Int; let prefix: String; let vectors: [Vector] }

    private func loadVectors() throws -> File {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("pam/vectors/pam-mac-v1.json")
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    }

    private func hex(_ s: String) -> Data {
        var d = Data(); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return d
    }

    func testPrefixMatchesVectorFile() throws {
        XCTAssertEqual(try loadVectors().prefix, ImmurokSecurity.pamMacPrefix)
    }

    func testMacMatchesVectors() throws {
        for v in try loadVectors().vectors {
            XCTAssertEqual(ImmurokSecurity.pamMac(key: hex(v.key), nonce: hex(v.nonce),
                                                  user: v.user, service: v.service), v.mac, v.user)
        }
    }

    func testKeyIdMatchesVectors() throws {
        for v in try loadVectors().vectors {
            XCTAssertEqual(ImmurokSecurity.pamKeyId(key: hex(v.key)), v.key_id, v.user)
        }
    }

    func testMacIsBoundToUserAndService() throws {
        let v = try loadVectors().vectors[0]
        let base = ImmurokSecurity.pamMac(key: hex(v.key), nonce: hex(v.nonce), user: v.user, service: v.service)
        XCTAssertNotEqual(base, ImmurokSecurity.pamMac(key: hex(v.key), nonce: hex(v.nonce), user: "mallory", service: v.service))
        XCTAssertNotEqual(base, ImmurokSecurity.pamMac(key: hex(v.key), nonce: hex(v.nonce), user: v.user, service: "authorization"))
    }
}
