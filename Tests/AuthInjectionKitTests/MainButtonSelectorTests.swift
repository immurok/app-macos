import XCTest
@testable import AuthInjectionKit

final class MainButtonSelectorTests: XCTestCase {
    func testPicksRightmostNonCancelButton() {
        // Cancel 在左，Sign In 在右 → 选 Sign In(index 1)
        let buttons = [
            ButtonInfo(subrole: "AXCancelButton", frame: CGRect(x: 100, y: 200, width: 80, height: 30)),
            ButtonInfo(subrole: nil, frame: CGRect(x: 200, y: 200, width: 80, height: 30)),
        ]
        XCTAssertEqual(MainButtonSelector.pick(from: buttons), 1)
    }

    func testExcludesCancelEvenIfRightmost() {
        // Cancel 反而在最右也不能选它
        let buttons = [
            ButtonInfo(subrole: nil, frame: CGRect(x: 100, y: 200, width: 80, height: 30)),
            ButtonInfo(subrole: "AXCancelButton", frame: CGRect(x: 300, y: 200, width: 80, height: 30)),
        ]
        XCTAssertEqual(MainButtonSelector.pick(from: buttons), 0)
    }

    func testReturnsNilWhenEmpty() {
        XCTAssertNil(MainButtonSelector.pick(from: []))
    }

    func testReturnsNilWhenOnlyCancel() {
        let buttons = [ButtonInfo(subrole: "AXCancelButton", frame: .zero)]
        XCTAssertNil(MainButtonSelector.pick(from: buttons))
    }

    func testPicksRightmostAmongMultipleNonCancel() {
        // 两个非 cancel 候选 + 一个 cancel；最右非 cancel（index 2）必须胜出。
        // 这一例真正驱动 maxX 比较——.first / .last 的错误实现会在此挂掉。
        let buttons = [
            ButtonInfo(subrole: "AXCancelButton", frame: CGRect(x: 50, y: 200, width: 80, height: 30)),
            ButtonInfo(subrole: nil, frame: CGRect(x: 150, y: 200, width: 80, height: 30)),   // maxX 230
            ButtonInfo(subrole: nil, frame: CGRect(x: 300, y: 200, width: 80, height: 30)),   // maxX 380  ← 最右
        ]
        XCTAssertEqual(MainButtonSelector.pick(from: buttons), 2)
    }

    func testPicksRightmostWhenNotLastElement() {
        // 最右非 cancel 不是数组最后一个元素——排除 .last 实现。
        let buttons = [
            ButtonInfo(subrole: nil, frame: CGRect(x: 300, y: 200, width: 80, height: 30)),   // maxX 380  ← 最右
            ButtonInfo(subrole: nil, frame: CGRect(x: 150, y: 200, width: 80, height: 30)),   // maxX 230
            ButtonInfo(subrole: "AXCancelButton", frame: CGRect(x: 50, y: 200, width: 80, height: 30)),
        ]
        XCTAssertEqual(MainButtonSelector.pick(from: buttons), 0)
    }

    func testReturnsNilWhenOnlyWindowControls() {
        // Passwords 解锁窗口只有红绿灯（关闭/最小化/缩放），没有真正的提交按钮。
        // 三者都不能被当作主按钮——否则会按下绿色缩放键把窗口变全屏。必须返回 nil，
        // 让 submit 退回 kAXConfirmAction（回车）。
        let buttons = [
            ButtonInfo(subrole: "AXCloseButton", frame: CGRect(x: 20, y: 10, width: 14, height: 14)),
            ButtonInfo(subrole: "AXMinimizeButton", frame: CGRect(x: 40, y: 10, width: 14, height: 14)),
            ButtonInfo(subrole: "AXZoomButton", frame: CGRect(x: 60, y: 10, width: 14, height: 14)),  // 最右——旧实现会误选
        ]
        XCTAssertNil(MainButtonSelector.pick(from: buttons))
    }

    func testAppStoreCatalystPicksSignInNotCancel() {
        // 实测 App Store 密码页（Catalyst，全部 subrole=nil，无 AXCancelButton/AXDefaultButton）：
        // Cancel 的 maxX 比 Sign In 还大，纯几何"取最右"会误按 Cancel 关掉 sheet。
        // 靠标题排除 Cancel + 优选 Sign In，必须选中 Sign In(index 1)。
        let buttons = [
            ButtonInfo(subrole: nil, title: "Cancel", frame: CGRect(x: 720, y: 416, width: 80, height: 30)),          // maxX 800 最右
            ButtonInfo(subrole: nil, title: "Sign In", frame: CGRect(x: 708, y: 630, width: 80, height: 30)),         // maxX 788
            ButtonInfo(subrole: nil, title: "Forgot Password", frame: CGRect(x: 550, y: 670, width: 120, height: 30)),// maxX 670
        ]
        XCTAssertEqual(MainButtonSelector.pick(from: buttons), 1)
    }

    func testExcludesCancelByTitleWhenNoSubrole() {
        // 只有 Cancel（subrole=nil，仅标题可判定），必须返回 nil 让上层走回车兜底。
        let buttons = [
            ButtonInfo(subrole: nil, title: "Cancel", frame: CGRect(x: 100, y: 200, width: 80, height: 30)),
        ]
        XCTAssertNil(MainButtonSelector.pick(from: buttons))
    }

    func testCancelTitleLocalizedAndCaseInsensitive() {
        // 中文"取消" + 大小写无关都要能识别为取消。
        let buttons = [
            ButtonInfo(subrole: nil, title: "取消", frame: CGRect(x: 300, y: 200, width: 80, height: 30)),  // 最右
            ButtonInfo(subrole: nil, title: "登录", frame: CGRect(x: 100, y: 200, width: 80, height: 30)),
        ]
        XCTAssertEqual(MainButtonSelector.pick(from: buttons), 1)
    }

    func testConfirmPreferenceOverMoreRightNonConfirm() {
        // 非取消非确认的按钮（Forgot）即便更靠右，也要让位给确认类（Sign In）。
        let buttons = [
            ButtonInfo(subrole: nil, title: "Sign In", frame: CGRect(x: 100, y: 200, width: 80, height: 30)),   // maxX 180
            ButtonInfo(subrole: nil, title: "Forgot Password", frame: CGRect(x: 300, y: 200, width: 120, height: 30)), // maxX 420 更右
        ]
        XCTAssertEqual(MainButtonSelector.pick(from: buttons), 0)
    }

    func testExcludesWindowControlsButKeepsRealButton() {
        // 窗口既有红绿灯又有真正的 Unlock 按钮——必须跳过红绿灯选中 Unlock（index 3），
        // 即便某个红绿灯 frame.maxX 更大也不行。
        let buttons = [
            ButtonInfo(subrole: "AXCloseButton", frame: CGRect(x: 20, y: 10, width: 14, height: 14)),
            ButtonInfo(subrole: "AXMinimizeButton", frame: CGRect(x: 40, y: 10, width: 14, height: 14)),
            ButtonInfo(subrole: "AXFullScreenButton", frame: CGRect(x: 900, y: 10, width: 14, height: 14)), // maxX 914 最右
            ButtonInfo(subrole: nil, frame: CGRect(x: 300, y: 500, width: 80, height: 30)),  // Unlock, maxX 380
        ]
        XCTAssertEqual(MainButtonSelector.pick(from: buttons), 3)
    }
}
