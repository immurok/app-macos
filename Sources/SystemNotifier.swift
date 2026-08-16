import AppKit
import UserNotifications

/// 通知点击后的动作。经 NotificationCenter 事件路由到持有 openWindow
/// 环境值的 MenuBarStatusLabel（AppDelegate 自己开不了 SwiftUI Window）。
enum NotificationAction: String {
    case openStatusTab
    case openPermissionsTab
    case openUpdateWindow
}

/// 系统通知的唯一出口。
///
/// 用 UNUserNotificationCenter 而不是历史上的 osascript `display
/// notification`：后者归属 Script Editor 的通知权限（被关/被 DND 吞都
/// 无从知晓）、不可点击、App 也从未申请过自己的通知授权。
///
/// 直接运行非 bundle 二进制（开发时跑 .build 产物）时
/// UNUserNotificationCenter 会因无 bundle 直接崩溃，此时回退 osascript。
final class SystemNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SystemNotifier()
    private override init() {}

    private var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }

    /// applicationDidFinishLaunching 时调用：接管 delegate 并申请授权
    /// （系统只在首次真正弹授权框，之后静默返回）。
    func activate() {
        guard hasBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            NSLog("SystemNotifier: notification authorization granted=%d", granted ? 1 : 0)
        }
    }

    /// 发一条通知。identifier 相同的通知会被替换而不是堆叠（同类去重）；
    /// action 决定点击后打开哪个窗口，nil = 点击只激活 App。
    static func post(subtitle: String, body: String,
                     identifier: String? = nil,
                     action: NotificationAction? = nil) {
        shared.post(subtitle: subtitle, body: body, identifier: identifier, action: action)
    }

    private func post(subtitle: String, body: String,
                      identifier: String?, action: NotificationAction?) {
        guard hasBundle else {
            postViaOsascript(subtitle: subtitle, body: body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "immurok"
        content.subtitle = subtitle
        content.body = body
        if let action = action {
            content.userInfo = ["action": action.rawValue]
        }
        let request = UNNotificationRequest(identifier: identifier ?? UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("SystemNotifier: add failed: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// 菜单栏常驻 App 在系统眼里可能是「前台」，默认会吞掉横幅——显式放行。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let raw = response.notification.request.content.userInfo["action"] as? String
        let action = raw.flatMap(NotificationAction.init(rawValue:))
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            switch action {
            case .openUpdateWindow:
                NotificationCenter.default.post(name: .openFirmwareUpdateWindow, object: nil)
            case .openStatusTab:
                NotificationCenter.default.post(name: .openSettingsWindow, object: SettingsTab.status)
            case .openPermissionsTab:
                NotificationCenter.default.post(name: .openSettingsWindow, object: SettingsTab.permissions)
            case nil:
                break
            }
        }
        completionHandler()
    }

    // MARK: - 非 bundle 环境回退

    private func postViaOsascript(subtitle: String, body: String) {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
             .replacingOccurrences(of: "\n", with: " ")
             .replacingOccurrences(of: "\r", with: " ")
        }
        let script = "display notification \"\(esc(body))\" with title \"immurok\" subtitle \"\(esc(subtitle))\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
    }
}
