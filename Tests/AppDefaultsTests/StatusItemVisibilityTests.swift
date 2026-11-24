import XCTest
@testable import immurokApp

/// 状态栏图标必须每次启动都出现。
///
/// 回归背景（2026-10-30，客户 macOS 15.7.4）：SwiftUI MenuBarExtra 底层的
/// NSStatusItem 自带 autosaveName "Item-0" 且允许 Cmd 拖出菜单栏。拖出后
/// AppKit 把 "NSStatusItem Visible Item-0" = false 持久化到 UserDefaults，
/// 之后每次启动（含重启电脑后登录项拉起）图标都按隐藏恢复；immurok 是
/// LSUIElement App，没有 Dock 图标，用户从此找不到任何入口。
final class StatusItemVisibilityTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "com.immurok.tests.StatusItemVisibility"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testRemovesHiddenFlagForMenuBarExtraItem() {
        defaults.set(false, forKey: "NSStatusItem Visible Item-0")
        AppDefaults.resetStatusItemVisibility(in: defaults)
        XCTAssertNil(defaults.object(forKey: "NSStatusItem Visible Item-0"))
    }

    /// macOS 26+ AppKit 改写成 "NSStatusItem VisibleCC Item-0"，同样清掉。
    func testRemovesControlCenterVariant() {
        defaults.set(false, forKey: "NSStatusItem VisibleCC Item-0")
        AppDefaults.resetStatusItemVisibility(in: defaults)
        XCTAssertNil(defaults.object(forKey: "NSStatusItem VisibleCC Item-0"))
    }

    /// 只碰可见性，不碰用户拖放排好的位置和其他设置。
    func testLeavesUnrelatedKeysAlone() {
        defaults.set(123, forKey: "NSStatusItem Preferred Position Item-0")
        defaults.set(true, forKey: "immurok.screenUnlockEnabled")
        AppDefaults.resetStatusItemVisibility(in: defaults)
        XCTAssertEqual(defaults.integer(forKey: "NSStatusItem Preferred Position Item-0"), 123)
        XCTAssertTrue(defaults.bool(forKey: "immurok.screenUnlockEnabled"))
    }

    func testNoOpWhenFlagAbsent() {
        AppDefaults.resetStatusItemVisibility(in: defaults)
        XCTAssertNil(defaults.object(forKey: "NSStatusItem Visible Item-0"))
    }
}
