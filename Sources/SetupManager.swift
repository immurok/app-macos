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
    @Published var isLegacySudoConfigured = true

    // MARK: - Paths

    private let pamModuleDestination = "/usr/local/lib/pam/pam_immurok.so"
    private let authorizationPath = "/etc/pam.d/authorization"
    private let legacySudoPath = "/etc/pam.d/sudo"

    /// macOS 13 Ventura 及更早:/etc/pam.d/sudo 没有 `include sudo_local`,
    /// pam 行必须直接写进 /etc/pam.d/sudo,且每次系统更新都会被重置——需要监控。
    static let isLegacyOS = ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 14

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
        let wasTrusted = hasAccessibilityPermission
        hasAccessibilityPermission = AXIsProcessTrusted()
        // 权限从无→有：通知重注册全局热键（首次安装时热键在无权限下注册会静默失效）
        if !wasTrusted && hasAccessibilityPermission {
            NotificationCenter.default.post(name: .accessibilityGranted, object: nil)
        }
        isAuthorizationConfigured = Self.authorizationLineConfigured(at: authorizationPath)
        // 14+ 走 sudo_local(系统更新不重置),无需监控,恒视为已配置
        isLegacySudoConfigured = Self.isLegacyOS
            ? Self.authorizationLineConfigured(at: legacySudoPath)
            : true
        refreshPamKeyStatus()
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

    /// 需要修复:macOS 13.x 上用户想要 sudo 功能,但 /etc/pam.d/sudo 里行丢了
    /// (系统更新必然重置该文件)。14+ 恒为 false。
    var needsLegacySudoRepair: Bool {
        return Self.isLegacyOS && isSudoAuthEnabled && !isLegacySudoConfigured
    }

    /// 任一 pam.d 行丢失,菜单/通知统一入口。repair.pkg 一次性补齐全部。
    var needsPAMRepair: Bool {
        return needsAuthorizationRepair || needsLegacySudoRepair
    }

    /// Check if setup wizard should be shown
    var needsSetup: Bool {
        return !isPAMModuleInstalled || !hasAccessibilityPermission
    }

    // MARK: - PAM 信道强认证密钥（spec 2026-09-03-pam-channel-mac-design.md）

    enum PamKeyStatus { case notInstalled, installed, mismatch }
    @Published private(set) var pamKeyStatus: PamKeyStatus = .notInstalled

    /// 读 /etc/immurok/pam/<uid>.keyid 与钥匙串里 pam_key 的 key_id 比较。不需要 root。
    func refreshPamKeyStatus() {
        let path = "/etc/immurok/pam/\(getuid()).keyid"
        guard let installed = try? String(contentsOfFile: path, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !installed.isEmpty else {
            pamKeyStatus = .notInstalled
            return
        }
        guard let mine = ImmurokSecurity.shared.pamKeyId() else {
            // root 有、钥匙串没有：条目丢了，PAM 会拒绝我们的裸 OK
            pamKeyStatus = .mismatch
            return
        }
        pamKeyStatus = (mine == installed) ? .installed : .mismatch
    }

    /// 通过 osascript 管理员授权跑 `imk pam-key install --user <uid>`。
    /// 注意：osascript 拿到的 root 写 /etc/pam.d 曾被 TCC 拒绝；/etc/immurok 是否放行
    /// 以实测为准，失败时 completion 带上让用户在终端手动执行的提示。
    func installPamKey(completion: @escaping (Bool, String?) -> Void) {
        let uid = getuid()
        let script = "do shell script \"/usr/local/bin/imk pam-key install --user \(uid)\" with administrator privileges"
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = Pipe()
            do { try p.run() } catch {
                DispatchQueue.main.async { completion(false, error.localizedDescription) }
                return
            }
            p.waitUntilExit()
            let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let trimmedErr = errText.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                self.refreshPamKeyStatus()
                let ok = p.terminationStatus == 0 && self.pamKeyStatus == .installed
                if ok {
                    completion(true, nil)
                    return
                }
                // 用户在管理员授权弹窗里点了取消：osascript 以非 0 退出，
                // stderr 是 "User canceled." (对应 AppleScript 错误 -128)。
                // 这不是失败，是用户主动放弃——不要弹「启用失败」，静默刷新状态就行。
                if p.terminationStatus != 0 && trimmedErr.contains("User canceled") {
                    completion(false, nil)
                    return
                }
                completion(false, trimmedErr)
            }
        }
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

        // 轮询 pam.d 行是否补回(用户在 Installer 中完成安装 + 授权)。
        // 13.x 上 repair.pkg 同时补 authorization 和 /etc/pam.d/sudo,两者都要到位。
        let startTime = Date()
        let timeout: TimeInterval = 300

        func check() {
            refreshStatus()
            if !needsPAMRepair {
                completion(true, nil)
                return
            }
            if Date().timeIntervalSince(startTime) >= timeout {
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
            completion(false, "alert.uninstall.pkg.missing".localized)
            return
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: pkgPath))

        // Poll for PAM module removal to detect completion
        let startTime = Date()
        let timeout: TimeInterval = 300

        func check() {
            if !FileManager.default.fileExists(atPath: pamModuleDestination) {
                // 卸载 pkg 已完成。root postinstall 无法访问用户 Keychain，
                // 锁屏密码等条目必须趁 App 进程还活着时由 App 自己清；
                // 同时复位引导完成标记，重装后能重新走首次引导。
                ImmurokSecurity.shared.clearAllKeychainData()
                UserDefaults.standard.removeObject(forKey: SetupWizardView.completedKey)
                refreshStatus()
                completion(true, nil)
                return
            }

            if Date().timeIntervalSince(startTime) >= timeout {
                refreshStatus()
                completion(false, "alert.operation.timeout".localized)
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
