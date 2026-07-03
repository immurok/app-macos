// Tests/FirmwareUpdateKitTests/UpdateManifestTests.swift
import XCTest
@testable import FirmwareUpdateKit

final class UpdateManifestTests: XCTestCase {
    let fullJSON = """
    {
      "schema": 1,
      "latest": {
        "version": "1.6.1",
        "sec_version": 2,
        "format": "v2",
        "url": "https://immurok.com/fw/immurok-ik1-v1.6.1.imfw",
        "sha256": "aa11",
        "size": 221184,
        "min_direct": "1.6.0",
        "notes": "fixes"
      },
      "bridge": {
        "version": "1.6.0",
        "format": "v1",
        "url": "https://immurok.com/fw/immurok-ik1-v1.6.0-bridge.imfw",
        "sha256": "bb22"
      }
    }
    """.data(using: .utf8)!

    func testDecodeFull() throws {
        let m = try UpdateManifest.decode(from: fullJSON)
        XCTAssertEqual(m.latest.version, "1.6.1")
        XCTAssertEqual(m.latest.minDirect, "1.6.0")
        XCTAssertEqual(m.latest.notes, "fixes")
        XCTAssertEqual(m.bridge?.sha256, "bb22")
    }

    func testUnknownSchemaRejected() {
        let json = fullJSON
        let m = try! JSONSerialization.jsonObject(with: json) as! [String: Any]
        var mutated = m; mutated["schema"] = 99
        let data = try! JSONSerialization.data(withJSONObject: mutated)
        XCTAssertThrowsError(try UpdateManifest.decode(from: data)) {
            XCTAssertEqual($0 as? ManifestError, .unsupportedSchema(99))
        }
    }

    func testMissingLatestRejected() {
        let data = #"{"schema": 1}"#.data(using: .utf8)!
        XCTAssertThrowsError(try UpdateManifest.decode(from: data))
    }

    func testBridgeOptional() throws {
        let data = """
        {"schema":1,"latest":{"version":"1.6.0","format":"v1",
         "url":"https://immurok.com/fw/x.imfw","sha256":"cc","size":10,"min_direct":"1.6.0"}}
        """.data(using: .utf8)!
        let m = try UpdateManifest.decode(from: data)
        XCTAssertNil(m.bridge)
        XCTAssertNil(m.latest.notes)
    }
}
