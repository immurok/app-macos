#if TEST_HOOKS
import XCTest
@testable import immurokApp

final class TestHooksParseTests: XCTestCase {
    func testPing() {
        let r = TestRequest.parse("TEST:PING")
        XCTAssertEqual(r?.name, "PING")
        XCTAssertEqual(r?.args, [])
    }
    func testArgsSplit() {
        let r = TestRequest.parse("TEST:KEY_WRITE:otp:3:0a0b")
        XCTAssertEqual(r?.name, "KEY_WRITE")
        XCTAssertEqual(r?.args, ["otp", "3", "0a0b"])
    }
    func testRestKeepsColons() {
        let r = TestRequest.parse("TEST:OTA:/tmp/a:b.imfw")
        XCTAssertEqual(r?.name, "OTA")
        XCTAssertEqual(r?.rest, "/tmp/a:b.imfw")
    }
    func testNotTest() {
        XCTAssertNil(TestRequest.parse("PING"))
        XCTAssertNil(TestRequest.parse("TEST:"))
    }
}
#endif
