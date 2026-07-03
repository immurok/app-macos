// Tests/FirmwareUpdateKitTests/TelemetryTests.swift
import XCTest
@testable import FirmwareUpdateKit

final class TelemetryTests: XCTestCase {
    func testPayloadShape() throws {
        var sent: [Data] = []
        let client = TelemetryClient(
            clientID: "uuid-1234",
            appVersion: "1.20",
            isEnabled: { true },
            sender: { data in sent.append(data) })

        client.send(.fwUpdateStarted(from: "1.3.11", to: "1.6.1", hops: 2))

        XCTAssertEqual(sent.count, 1)
        let obj = try JSONSerialization.jsonObject(with: sent[0]) as! [String: Any]
        XCTAssertEqual(obj["client_id"] as? String, "uuid-1234")
        let events = obj["events"] as! [[String: Any]]
        XCTAssertEqual(events[0]["name"] as? String, "fw_update_started")
        let params = events[0]["params"] as! [String: Any]
        XCTAssertEqual(params["from_version"] as? String, "1.3.11")
        XCTAssertEqual(params["to_version"] as? String, "1.6.1")
        XCTAssertEqual(params["hops"] as? Int, 2)
        XCTAssertEqual(params["app_version"] as? String, "1.20")
    }

    func testDisabledSendsNothing() {
        var sent: [Data] = []
        let client = TelemetryClient(
            clientID: "x", appVersion: "1.20",
            isEnabled: { false },
            sender: { sent.append($0) })
        client.send(.fwCheck(deviceVersion: "1.6.0", latestVersion: "1.6.1", updateAvailable: true))
        XCTAssertTrue(sent.isEmpty)
    }

    func testEventNames() {
        // 事件名与 spec §5 表格一致
        XCTAssertEqual(TelemetryEvent.fwCheck(deviceVersion: "a", latestVersion: "b",
                                              updateAvailable: false).name, "fw_check")
        XCTAssertEqual(TelemetryEvent.fwPromptShown(from: "a", to: "b").name, "fw_prompt_shown")
        XCTAssertEqual(TelemetryEvent.fwHopDone(hop: "bridge", durationMs: 1).name, "fw_hop_done")
        XCTAssertEqual(TelemetryEvent.fwUpdateSuccess(from: "a", to: "b",
                                                      totalDurationMs: 1, retries: 0).name, "fw_update_success")
        XCTAssertEqual(TelemetryEvent.fwUpdateFailed(stage: "transfer", errorCode: "x",
                                                     hop: "final").name, "fw_update_failed")
        XCTAssertEqual(TelemetryEvent.fwUpdateResumed(pendingHop: "final").name, "fw_update_resumed")
    }
}
