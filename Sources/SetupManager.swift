import Foundation
import AppKit
import ApplicationServices

/// Manages installation status and setup operations for immurok
@MainActor
class SetupManager: ObservableObject {
    static let shared = SetupManager()

    // MARK: - Published State

    @Published var isPAMModuleInstalled = false
    @Published var isSudoAuthEnabled = false
    @Published var isAuthorizationEnabled = false
    @Published var hasAccessibilityPermission = false
    @Published var isAuthorizationConfigured = false

    // MARK: - Paths

    private let pamModuleDestination = "/usr/local/lib/pam/pam_immurok.so"
    private let authorizationPath = "/etc/pam.d/authorization"

    private var uninstallPkgPath: String? {
        Bundle.main.path(forResource: "immurok_uninstall", ofType: "pkg")
    }

    // MARK: - Initialization

    private init() {
        refreshStatus()
    }

    // MARK: - Status Checking

    func refreshStatus() {
        isPAMModuleInstalled = FileManager.default.fileExists(atPath: pamModuleDestination)
        isSudoAuthEnabled = UserDefaults.standard.bool(forKey: "immurok.sudoAuthEnabled")
        isAuthorizationEnabled = UserDefaults.standard.bool(forKey: "immurok.authorizationEnabled")
        hasAccessibilityPermission = AXIsProcessTrusted()
        isAuthorizationConfigured = Self.authorizationLineConfigured(at: authorizationPath)
    }

    /// 文件真相:/etc/pam.d/authorization 是否含生效的 pam_immurok 行。
    /// 与 repair-postinstall 的锚定匹配 `^[^#]*pam_immurok` 保持一致:注释行(以 # 开头)
    /// 不算生效,避免"已注释 → UI 误判已配置 → 不提示修复"的假阴性。
    /// 文件不可读按"未配置"保守处理。
    static func authorizationLineConfigured(at path: String) -> Bool {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }
        return content.split(separator: "\n").contains { line in
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            return !trimmed.hasPrefix("#") && trimmed.contains("pam_immurok")
        }
    }

    /// 需要修复:用户想要 authorization 功能,但文件里行丢了(多为系统升级所致)。
    var needsAuthorizationRepair: Bool {
        return isAuthorizationEnabled && !isAuthorizationConfigured
    }

    /// Check if setup wizard should be shown
    var needsSetup: Bool {
        return !isPAMModuleInstalled || !hasAccessibilityPermission
    }

    // MARK: - PAM Feature Toggles

    func setSudoAuthEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "immurok.sudoAuthEnabled")
        isSudoAuthEnabled = enabled
    }

    func setAuthorizationEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "immurok.authorizationEnabled")
        isAuthorizationEnabled = enabled
    }

    // MARK: - Accessibility Permission

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)

        // Poll for permission change
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshStatus()
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Authorization Repair

    private var repairPkgPath: String? {
        Bundle.main.path(forResource: "immurok_repair", ofType: "pkg")
    }

    /// 打开 bundle 内的 immurok_repair.pkg,经 system_installd 以特权 root 运行其
    /// postinstall,幂等补回 authorization 行。这是唯一能写 /etc/pam.d 的途径——
    /// osascript 管理员授权拿到的 root 会被 TCC 拒绝(已实证)。镜像 uninstall 流程:
    /// 打开 pkg 后轮询文件直到行补回或超时。
    /// completion(成功, 错误信息?)。用户在 Installer 中取消 → 超时 → 成功=false,错误=nil。
    func repairAuthorization(completion: @escaping (Bool, String?) -> Void) {
        guard let pkgPath = repairPkgPath else {
            completion(false, "alert.need.pam.reinstall".localized)
            return
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: pkgPath))

        // 轮询 authorization 行是否补回(用户在 Installer 中完成安装 + 授权)
        let startTime = Date()
        let timeout: TimeInterval = 300

        func check() {
            if Self.authorizationLineConfigured(at: authorizationPath) {
                refreshStatus()
                completion(true, nil)
                return
            }
            if Date().timeIntervalSince(startTime) >= timeout {
                refreshStatus()
                completion(false, nil)  // 超时/取消,按"未完成"处理,不弹错误
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { check() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { check() }
    }

    // MARK: - Uninstall

    /// Complete uninstall: open uninstall pkg which handles all cleanup
    func uninstall(completion: @escaping (Bool, String?) -> Void) {
        guard let pkgPath = uninstallPkgPath else {
            completion(false, "找不到卸载包 immurok_uninstall.pkg")
            return
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: pkgPath))

        // Poll for PAM module removal to detect completion
        let startTime = Date()
        let timeout: TimeInterval = 300

        func check() {
            if !FileManager.default.fileExists(atPath: pamModuleDestination) {
                refreshStatus()
                completion(true, nil)
                return
            }

            if Date().timeIntervalSince(startTime) >= timeout {
                refreshStatus()
                completion(false, "操作超时或已取消")
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                check()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            check()
        }
    }

}
