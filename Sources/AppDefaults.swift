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
            "immurok.telemetry.enabled": true,
        ])
    }
}
