// Tests/FirmwareUpdateKitTests/FirmwareVersionTests.swift
import XCTest
@testable import FirmwareUpdateKit

final class FirmwareVersionTests: XCTestCase {
    func testParseValid() {
        let v = FirmwareVersion("1.3.11")
        XCTAssertEqual(v?.major, 1)
        XCTAssertEqual(v?.minor, 3)
        XCTAssertEqual(v?.patch, 11)
    }

    func testParseInvalid() {
        XCTAssertNil(FirmwareVersion(""))
        XCTAssertNil(FirmwareVersion("1.2"))
        XCTAssertNil(FirmwareVersion("a.b.c"))
        XCTAssertNil(FirmwareVersion("1.2.3.4"))
    }

    func testCompare() {
        XCTAssertLessThan(FirmwareVersion("1.3.11")!, FirmwareVersion("1.6.0")!)
        XCTAssertLessThan(FirmwareVersion("1.6.0")!, FirmwareVersion("1.6.1")!)
        XCTAssertLessThan(FirmwareVersion("1.9.9")!, FirmwareVersion("1.10.0")!)  // 数值比较非字典序
        XCTAssertEqual(FirmwareVersion("1.6.0")!, FirmwareVersion("1.6.0")!)
        XCTAssertGreaterThan(FirmwareVersion("2.0.0")!, FirmwareVersion("1.99.99")!)
    }

    func testDescription() {
        XCTAssertEqual(FirmwareVersion("1.6.0")!.description, "1.6.0")
    }
}
