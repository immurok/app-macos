// Tests/FirmwareUpdateKitTests/IMFWPackageTests.swift
import XCTest
@testable import FirmwareUpdateKit

final class IMFWPackageTests: XCTestCase {
    /// 构造合成 header：magic + version + flags + hw_id + fw_size (+ sec_version @0x0C)
    private func makeIMFW(version: UInt8, headerSize: Int, fwSize: UInt32,
                          secVersion: UInt16 = 0, payload: Data = Data(count: 480)) -> Data {
        var d = Data(count: headerSize)
        d.replaceSubrange(0..<4, with: withUnsafeBytes(of: UInt32(0x494D4657).littleEndian) { Data($0) })
        d[4] = version
        d[5] = 0  // flags
        // hw_id @6..8 留 0
        d.replaceSubrange(8..<12, with: withUnsafeBytes(of: fwSize.littleEndian) { Data($0) })
        if version >= 2 {
            d.replaceSubrange(0x0C..<0x0E, with: withUnsafeBytes(of: secVersion.littleEndian) { Data($0) })
        }
        return d + payload
    }

    func testParseV1() throws {
        let data = makeIMFW(version: 1, headerSize: 96, fwSize: 480)
        let pkg = try IMFWPackage(data: data)
        XCTAssertEqual(pkg.formatVersion, 1)
        XCTAssertEqual(pkg.header.count, 96)
        XCTAssertEqual(pkg.encryptedFirmware.count, 480)
        XCTAssertEqual(pkg.fwSize, 480)
        XCTAssertNil(pkg.secVersion)
    }

    func testParseV2() throws {
        let data = makeIMFW(version: 2, headerSize: 128, fwSize: 480, secVersion: 3)
        let pkg = try IMFWPackage(data: data)
        XCTAssertEqual(pkg.formatVersion, 2)
        XCTAssertEqual(pkg.header.count, 128)
        XCTAssertEqual(pkg.secVersion, 3)
    }

    func testBadMagic() {
        var data = makeIMFW(version: 1, headerSize: 96, fwSize: 480)
        data[0] = 0x00
        XCTAssertThrowsError(try IMFWPackage(data: data)) {
            XCTAssertEqual($0 as? IMFWError, .badMagic)
        }
    }

    func testTruncatedHeader() {
        XCTAssertThrowsError(try IMFWPackage(data: Data(count: 50))) {
            XCTAssertEqual($0 as? IMFWError, .truncated)
        }
        // v2 声称 128B header 但文件只有 100B
        let short = makeIMFW(version: 2, headerSize: 128, fwSize: 480).prefix(100)
        XCTAssertThrowsError(try IMFWPackage(data: Data(short))) {
            XCTAssertEqual($0 as? IMFWError, .truncated)
        }
    }

    func testPayloadSizeMismatch() {
        // header 声称 fw_size=9999 但 payload 只有 480B
        let data = makeIMFW(version: 1, headerSize: 96, fwSize: 9999)
        XCTAssertThrowsError(try IMFWPackage(data: data)) {
            XCTAssertEqual($0 as? IMFWError, .sizeMismatch)
        }
    }

    func testOversizeRejected() {
        // 超过 Image B 216KB 拒绝
        let big = makeIMFW(version: 1, headerSize: 96, fwSize: 300 * 1024,
                           payload: Data(count: 300 * 1024))
        XCTAssertThrowsError(try IMFWPackage(data: big)) {
            XCTAssertEqual($0 as? IMFWError, .tooLarge)
        }
    }

    func testUnsupportedVersion() {
        // version=3 不被接受
        var data = makeIMFW(version: 1, headerSize: 96, fwSize: 480)
        data[data.startIndex + 4] = 3
        XCTAssertThrowsError(try IMFWPackage(data: data)) {
            XCTAssertEqual($0 as? IMFWError, .unsupportedVersion(3))
        }
    }
}
