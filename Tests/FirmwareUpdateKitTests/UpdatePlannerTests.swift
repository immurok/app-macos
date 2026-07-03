// Tests/FirmwareUpdateKitTests/UpdatePlannerTests.swift
import XCTest
@testable import FirmwareUpdateKit

final class UpdatePlannerTests: XCTestCase {
    func testOldDeviceTwoHops() {
        let plan = UpdatePlanner.plan(device: "1.3.11", latest: "1.6.1", minDirect: "1.6.0")
        XCTAssertEqual(plan, .twoHops)
    }

    func testBridgeDeviceOneHop() {
        XCTAssertEqual(UpdatePlanner.plan(device: "1.6.0", latest: "1.6.1", minDirect: "1.6.0"), .direct)
    }

    func testUpToDate() {
        XCTAssertEqual(UpdatePlanner.plan(device: "1.6.1", latest: "1.6.1", minDirect: "1.6.0"), .upToDate)
        // 设备比 latest 还新（本地开发版）也视为无需升级
        XCTAssertEqual(UpdatePlanner.plan(device: "1.7.0", latest: "1.6.1", minDirect: "1.6.0"), .upToDate)
    }

    func testTargetIsBridge() {
        // 初期 latest == 1.6.0（桥即最新）：老设备只推桥包一跳
        XCTAssertEqual(UpdatePlanner.plan(device: "1.3.11", latest: "1.6.0", minDirect: "1.6.0"), .bridgeOnly)
    }

    func testMinDirectFallback() {
        // manifest 缺 min_direct → 回退 "1.6.0"（spec §2）
        XCTAssertEqual(UpdatePlanner.plan(device: "1.5.5", latest: "1.6.1", minDirect: nil), .twoHops)
        XCTAssertEqual(UpdatePlanner.plan(device: "1.6.0", latest: "1.6.1", minDirect: nil), .direct)
    }

    func testUnparsableVersions() {
        XCTAssertEqual(UpdatePlanner.plan(device: "garbage", latest: "1.6.1", minDirect: nil), .unknown)
        XCTAssertEqual(UpdatePlanner.plan(device: "1.6.0", latest: "", minDirect: nil), .unknown)
    }
}
