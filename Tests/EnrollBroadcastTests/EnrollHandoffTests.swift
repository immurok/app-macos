import XCTest
@testable import immurokApp

/// 「验证旧指纹 → 换手指 → 采集新指纹」过渡的帧裁决。
///
/// 背景：固件 1.8.9 起，同一根手指录进第二个槽位会被中止。过门那一刻旧手指
/// 还按在传感器上，界面如果立刻摆出采集引导，用户会抬起再按回同一根手指，
/// 整次录入白做。所以门过之后要先停在「验证通过，换成新手指」上。
final class EnrollHandoffTests: XCTestCase {

    private func frame(_ event: EnrollEvent, _ current: Int = 0) -> EnrollStatusPayload {
        EnrollStatusPayload(event: event, current: current, total: 6)
    }

    /// 首次录入、或门在冷却期内被跳过：没有 WAIT_FP，就没有过渡，帧照常处理。
    func testWithoutGateThereIsNoHandoff() {
        var h = EnrollHandoff()
        XCTAssertFalse(h.begin())
        XCTAssertFalse(h.isActive)
        XCTAssertEqual(h.frame(frame(.waiting)), .apply)
        XCTAssertEqual(h.frame(frame(.captured, 1)), .apply)
    }

    /// 过门后的第一帧 LiftFinger 是「请抬起」，过渡画面已经在说这句话，吞掉；
    /// 之后的帧在停留时间内只留最新一帧，时间到了再交出来。
    func testFramesAreHeldUntilDwellElapses() {
        var h = EnrollHandoff()
        h.arm()
        XCTAssertTrue(h.begin())
        XCTAssertTrue(h.isActive)

        XCTAssertEqual(h.frame(frame(.liftFinger)), .swallow)   // 请抬起
        XCTAssertEqual(h.frame(frame(.liftFinger)), .hold)      // 已抬起
        XCTAssertEqual(h.frame(frame(.waiting)), .hold)         // 等新手指
        XCTAssertTrue(h.isActive)

        XCTAssertEqual(h.dwellDidElapse(), frame(.waiting), "只交出最新一帧")
        XCTAssertFalse(h.isActive)
        XCTAssertEqual(h.frame(frame(.captured, 1)), .apply)
    }

    /// 停留时间到了但用户还没抬手：继续停在过渡画面，直到设备推来下一帧。
    func testStaysUntilNextFrameWhenFingerNotLiftedYet() {
        var h = EnrollHandoff()
        h.arm()
        XCTAssertTrue(h.begin())
        XCTAssertEqual(h.frame(frame(.liftFinger)), .swallow)

        XCTAssertNil(h.dwellDidElapse())
        XCTAssertTrue(h.isActive)

        XCTAssertEqual(h.frame(frame(.liftFinger)), .apply)
        XCTAssertFalse(h.isActive)
    }

    /// 「请抬起」帧可能比门的完成回调先到主线程（此时还没进入过渡）。
    /// 它不能丢：否则后面的「已抬起」会被当成「请抬起」吞掉，过渡画面要多挂
    /// 到下一次保活帧（约 3 秒）。
    func testLiftPromptArrivingBeforeBeginStillCounts() {
        var h = EnrollHandoff()
        h.arm()
        XCTAssertEqual(h.frame(frame(.liftFinger)), .swallow)
        XCTAssertTrue(h.begin())
        XCTAssertEqual(h.frame(frame(.liftFinger)), .hold, "这一帧已经是「已抬起」")
    }

    /// 终态帧（完成 / 失败）不等停留时间，立即收场。
    func testTerminalFrameEndsHandoffImmediately() {
        var h = EnrollHandoff()
        h.arm()
        XCTAssertTrue(h.begin())
        XCTAssertEqual(h.frame(frame(.liftFinger)), .swallow)
        XCTAssertEqual(h.frame(frame(.waiting)), .hold)

        XCTAssertEqual(h.frame(frame(.failed, EnrollFailReason.duplicate)), .apply)
        XCTAssertFalse(h.isActive)
        XCTAssertNil(h.dwellDidElapse(), "收场后不再补交之前压着的帧")
    }

    /// 第一帧不是 LiftFinger（设备没判到手指在位）：不吞，按普通帧压到停留结束。
    func testFirstFrameOtherThanLiftIsHeldNotSwallowed() {
        var h = EnrollHandoff()
        h.arm()
        XCTAssertTrue(h.begin())
        XCTAssertEqual(h.frame(frame(.waiting)), .hold)
        XCTAssertEqual(h.dwellDidElapse(), frame(.waiting))
    }

    /// 门失败 / 取消后复位，下一次无门录入不能带着上次的状态进过渡。
    func testResetClearsArmedState() {
        var h = EnrollHandoff()
        h.arm()
        h.reset()
        XCTAssertFalse(h.begin())
        XCTAssertFalse(h.isActive)
    }

    // MARK: - 失败原因

    /// 只有 0xFF 帧的 current 字节是原因码；其余失败状态一律按通用失败。
    func testFailReasonOnlyReadFromFFFrame() {
        XCTAssertEqual(EnrollFailReason.fromFrame(status: 0xFF, byte2: 1), EnrollFailReason.duplicate)
        XCTAssertEqual(EnrollFailReason.fromFrame(status: 0xFF, byte2: 0), EnrollFailReason.generic)
        XCTAssertEqual(EnrollFailReason.fromFrame(status: 0xFE, byte2: 1), EnrollFailReason.generic)
        XCTAssertEqual(EnrollFailReason.fromFrame(status: 0xFD, byte2: 1), EnrollFailReason.generic)
    }
}
