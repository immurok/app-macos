import XCTest
@testable import FirmwareUpdateKit

/// Mock transport：记录发出的包，按脚本回放响应
final class MockTransport: OTATransport {
    var writtenWithRead: [Data] = []
    var writtenNoResponse: [Data] = []
    /// 按 opcode 返回响应；默认全部成功
    var responder: (UInt8) -> Data? = { op in
        switch op {
        case 0x84: return Data([0x00, 0x00, 0x60, 0x03, 0x00, 0xF0, 0x00, 0x92, 0x05])  // INFO
        default:   return Data([0x00])
        }
    }
    var failWriteAt: Int? = nil  // 第 N 个 no-response 写失败

    func writeAndRead(_ data: Data, timeout: TimeInterval) async -> Data? {
        writtenWithRead.append(data)
        return responder(data[data.startIndex])
    }

    func writeNoResponse(_ data: Data) async -> Bool {
        writtenNoResponse.append(data)
        if let n = failWriteAt, writtenNoResponse.count == n { return false }
        return true
    }
}

final class OTAEngineTests: XCTestCase {
    /// 500B 密文（非 240 整数倍 → 3 块：240+240+20）+ 96B v1 header
    private func makePkg(payload: Int = 500) -> IMFWPackage {
        var d = Data(count: 96)
        d.replaceSubrange(0..<4, with: withUnsafeBytes(of: UInt32(0x494D4657).littleEndian) { Data($0) })
        d[4] = 1
        d.replaceSubrange(8..<12, with: withUnsafeBytes(of: UInt32(payload).littleEndian) { Data($0) })
        return try! IMFWPackage(data: d + Data(repeating: 0xAB, count: payload))
    }

    func testHappyPathCommandSequence() async throws {
        let t = MockTransport()
        var progress: [Double] = []
        try await OTAEngine(transport: t).push(makePkg()) { progress.append($0) }

        // write-and-read: INFO, ERASE, HEADER, END
        XCTAssertEqual(t.writtenWithRead.map { $0[$0.startIndex] }, [0x84, 0x81, 0x85, 0x83])
        // ERASE: addr=0, blocks=54
        XCTAssertEqual(t.writtenWithRead[1], Data([0x81, 0x04, 0x00, 0x00, 54, 0x00]))
        // HEADER: [0x85, 96, header...]
        XCTAssertEqual(t.writtenWithRead[2][t.writtenWithRead[2].startIndex + 1], 96)
        XCTAssertEqual(t.writtenWithRead[2].count, 2 + 96)
        // PROM 分块: 240+240+20
        XCTAssertEqual(t.writtenNoResponse.count, 3)
        XCTAssertEqual(t.writtenNoResponse[0][t.writtenNoResponse[0].startIndex + 1], 240)
        XCTAssertEqual(t.writtenNoResponse[2][t.writtenNoResponse[2].startIndex + 1], 20)
        // 第 2 块地址编码 = 240/16 = 15
        XCTAssertEqual(t.writtenNoResponse[1].readU16LE(at: 2), 15)
        // 进度单调递增到 1.0
        XCTAssertEqual(progress.last, 1.0)
        XCTAssertEqual(progress, progress.sorted())
    }

    func testHeaderRejected() async {
        let t = MockTransport()
        t.responder = { op in op == 0x85 ? Data([0x01]) : Data([0x00]) }
        do {
            try await OTAEngine(transport: t).push(makePkg()) { _ in }
            XCTFail("should throw")
        } catch let e as OTAEngineError {
            XCTAssertEqual(e, .headerRejected(code: 0x01))
        } catch { XCTFail("wrong error \(error)") }
    }

    func testEndVerifyFailureMapping() async {
        for (code, expected) in [(UInt8(0xF1), OTAEngineError.sha256Mismatch),
                                 (UInt8(0xF2), OTAEngineError.signatureMismatch)] {
            let t = MockTransport()
            t.responder = { op in op == 0x83 ? Data([code]) : Data([0x00]) }
            do {
                try await OTAEngine(transport: t).push(makePkg()) { _ in }
                XCTFail("should throw")
            } catch let e as OTAEngineError {
                XCTAssertEqual(e, expected)
            } catch { XCTFail("wrong error") }
        }
    }

    func testEndNoResponseIsSuccess() async throws {
        // END 后设备直接重启不回包 = 成功
        let t = MockTransport()
        t.responder = { op in op == 0x83 ? nil : (op == 0x84
            ? Data([0x00, 0x00, 0x60, 0x03, 0x00, 0xF0, 0x00, 0x92, 0x05]) : Data([0x00])) }
        try await OTAEngine(transport: t).push(makePkg()) { _ in }
    }

    func testChunkWriteFailureThrows() async {
        let t = MockTransport()
        t.failWriteAt = 2
        do {
            try await OTAEngine(transport: t).push(makePkg()) { _ in }
            XCTFail("should throw")
        } catch let e as OTAEngineError {
            XCTAssertEqual(e, .writeFailed(offset: 240))
        } catch { XCTFail("wrong error") }
    }

    func testEraseTimeoutThrows() async {
        let t = MockTransport()
        t.responder = { op in op == 0x81 ? nil : Data([0x00]) }
        do {
            try await OTAEngine(transport: t).push(makePkg()) { _ in }
            XCTFail("should throw")
        } catch let e as OTAEngineError {
            XCTAssertEqual(e, .noResponse(stage: "erase"))
        } catch { XCTFail("wrong error") }
    }
}
