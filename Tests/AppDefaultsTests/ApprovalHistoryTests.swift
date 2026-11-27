import XCTest
@testable import immurokApp

final class ApprovalHistoryTests: XCTestCase {
    @MainActor func testHistoryIsBoundedCategoricalAndClearable() {
        let history = ApprovalHistory()
        history.record(service: "sudo", status: .waiting)
        XCTAssertTrue(history.events.isEmpty)
        for _ in 0..<75 { history.record(service: "sensitive-requester-text", status: .approved) }
        XCTAssertEqual(history.events.count, 50)
        XCTAssertTrue(history.events.allSatisfy { $0.categoryKey == "experience.history.command" })
        XCTAssertTrue(history.events.allSatisfy { $0.outcomeKey == "experience.history.approved" })
        history.clear()
        XCTAssertTrue(history.events.isEmpty)
    }
}
