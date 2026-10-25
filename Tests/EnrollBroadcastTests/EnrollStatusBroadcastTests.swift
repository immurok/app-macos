import XCTest
@testable import immurokApp

/// 录入状态必须广播给所有监听者。
///
/// 回归背景（2026-10-23）：`BLEManager.onEnrollStatus` 是单槽闭包，
/// SetupWizardView / DeviceTabView / FingerprintView 各持一个 FingerprintViewModel，
/// 谁后创建谁覆盖前者。设置窗口与向导同时打开时，向导的 ViewModel 永远收不到
/// 捕获帧，录入 sheet 停在「请将手指放在传感器上」，用户以为按指纹没反应。
final class EnrollStatusBroadcastTests: XCTestCase {

    func testPayloadRoundTrip() {
        let note = Notification(name: BLEManager.enrollStatusNotification,
                                object: nil,
                                userInfo: EnrollStatusPayload(event: .liftFinger, current: 3, total: 6).userInfo)
        let decoded = EnrollStatusPayload(note)
        XCTAssertEqual(decoded?.event, .liftFinger)
        XCTAssertEqual(decoded?.current, 3)
        XCTAssertEqual(decoded?.total, 6)
    }

    func testPayloadRejectsForeignNotification() {
        let note = Notification(name: BLEManager.enrollStatusNotification, object: nil, userInfo: ["x": 1])
        XCTAssertNil(EnrollStatusPayload(note))
    }

    /// 两个独立监听者（模拟向导 + 设置页两个 ViewModel）都要收到同一帧。
    func testEveryObserverReceivesEveryEvent() {
        let center = NotificationCenter.default
        var received: [[String: Int]] = [[:], [:]]
        let tokens = (0..<2).map { idx in
            center.addObserver(forName: BLEManager.enrollStatusNotification, object: nil, queue: nil) { note in
                guard let p = EnrollStatusPayload(note) else { return }
                received[idx] = ["event": Int(p.event.rawValue), "current": p.current, "total": p.total]
            }
        }
        defer { tokens.forEach(center.removeObserver) }

        BLEManager.broadcastEnrollStatus(.captured, current: 2, total: 6)

        let expected = ["event": Int(EnrollEvent.captured.rawValue), "current": 2, "total": 6]
        XCTAssertEqual(received[0], expected)
        XCTAssertEqual(received[1], expected)
    }
}
