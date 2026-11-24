import Foundation

/// UserDefaults 默认值统一注册。
///
/// 背景：`@AppStorage("key") var x = true` 的默认值只对 SwiftUI 一侧生效，
/// 不会写入 UserDefaults；运行时用裸 `bool(forKey:)` 读同一 key 在首次启动
/// （key 尚不存在）时会得到 false，造成 UI 显示"开"但功能实际"关"
/// （1.4.x Passwords 自动填充首启失效的根因）。
///
/// `register(defaults:)` 不落盘，但让 `bool(forKey:)` 与 `@AppStorage`
/// 读到同一默认值，两侧永远一致。所有默认为 true 的开关必须在这里注册；
/// 默认 false 的 key 与 `bool(forKey:)` 的缺省语义一致，无需登记。
enum AppDefaults {
    static func register() {
        UserDefaults.standard.register(defaults: [
            "immurok.screenUnlockEnabled": true,
            "immurok.passwordsFillEnabled": true,
            "immurok.sshAgentEnabled": true,
            "immurok.cliEnabled": true,
            "immurok.quickFillEnabled": true,
        ])
    }

    /// 清掉 AppKit 为状态栏项持久化的「用户已移除」标记，保证图标每次启动都出现。
    ///
    /// SwiftUI MenuBarExtra 底层的 NSStatusItem 自带 autosaveName "Item-0"，
    /// behavior = removalAllowed | terminationOnRemoval：用户按住 Cmd 把图标拖出
    /// 菜单栏时 App 立即退出，同时 AppKit 写入 "NSStatusItem Visible Item-0" = false
    /// （macOS 26+ 为 "NSStatusItem VisibleCC Item-0"）。之后每次启动图标都按隐藏
    /// 恢复，而 immurok 是 LSUIElement App，没有 Dock 图标，用户再也找不到入口，
    /// 重启电脑也无效（2026-10-30 客户 macOS 15.7.4 案例）。
    ///
    /// 拖出即退出已经满足了「移除」的意图，再次启动理应可见。必须在 SwiftUI
    /// 场景（MenuBarExtra）创建之前调用，否则 NSStatusItem 已按旧值恢复。
    /// 只碰可见性键，不动 "NSStatusItem Preferred Position …" 等位置记忆。
    static func resetStatusItemVisibility(in defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("NSStatusItem Visible") {
            defaults.removeObject(forKey: key)
        }
    }
}
