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
    @Published var isSudoLocalConfigured = false
    @Published var isLegacySudoConfigured = true

    // MARK: - Paths

    private let pamModuleDestination = "/usr/local/lib/pam/pam_immurok.so"
    /// 卸载完成的判据。卸载 pkg 故意不删 PAM 模块（pam.d 引用悬空会让 sudo 和授权框
    /// 全坏，留一个文件则无害），所以不能再用"模块消失"判断，改看 imk：它在撤完
    /// pam.d 行之后才被删，消失即说明卸载脚本已越过会中止的那几步。
    private let uninstallSentinelPath = "/usr/local/bin/imk"
    private let authorizationPath = "/etc/pam.d/authorization"
    private let sudoLocalPath = "/etc/pam.d/sudo_local"
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
        // sudo_local 全版本由安装包写入（macOS 27 起写入可能被 TCC 拒绝），需要监控
        isSudoLocalConfigured = Self.authorizationLineConfigured(at: sudoLocalPath)
        // 13.x 的 sudo 行直写 /etc/pam.d/sudo（系统更新会重置）；14+ 不用该文件
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

    /// 需要修复：PAM 模块已装但 /etc/pam.d/authorization 缺行。
    /// 这些行是安装包必写的，缺了就是安装不完整（macOS 27 上安装时 TCC 被拒，
    /// 或系统升级重置），与用户是否打开授权开关无关。
    var needsAuthorizationRepair: Bool {
        return isPAMModuleInstalled && !isAuthorizationConfigured
    }

    /// 需要修复：PAM 模块已装但 sudo 的 pam.d 行缺失——14+ 看 sudo_local，
    /// 13.x 看 /etc/pam.d/sudo（系统更新必然重置该文件）。
    var needsSudoRepair: Bool {
        guard isPAMModuleInstalled else { return false }
        return Self.isLegacyOS ? !isLegacySudoConfigured : !isSudoLocalConfigured
    }

    /// 任一 pam.d 行丢失,菜单/通知统一入口。repair.pkg 一次性补齐全部。
    var needsPAMRepair: Bool {
        return needsAuthorizationRepair || needsSudoRepair
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
    /// postinstall,幂等补回 authorization / sudo_local(13.x 另补 /etc/pam.d/sudo)行。
    /// 这是唯一能写 /etc/pam.d 的途径——osascript 管理员授权拿到的 root 会被 TCC
    /// 拒绝(已实证)。macOS 27 起写入还会弹 TCC 窗,用户点 Don't Allow 时 pkg 失败。
    /// completion(成功, 错误信息?)。用户取消 / 拒绝 / Installer 退出 / 超时 → 成功=false,错误=nil。
    func repairAuthorization(completion: @escaping (Bool, String?) -> Void) {
        guard let pkgPath = repairPkgPath else {
            DispatchQueue.main.async {
                completion(false, "alert.need.pam.reinstall".localized)
            }
            return
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: pkgPath))
        waitForInstaller(done: { [weak self] in
            guard let self = self else { return false }
            self.refreshStatus()
            return !self.needsPAMRepair
        }) { success, _ in
            completion(success, nil)
        }
    }

    // MARK: - Uninstall

    /// Complete uninstall: open uninstall pkg which handles all cleanup.
    /// completion 始终异步回调：调用方在 SwiftUI `.alert` 的按钮 action 里调用本方法，
    /// 若在 action 内同步弹 NSAlert（runModal），会与正在收起的 SwiftUI alert sheet
    /// 叠加成嵌套 modal，设置窗口直接卡死（已实证）。
    /// completion(成功, 错误信息?)：取消 / 拒绝 / Installer 退出 → (false, nil) 静默；超时 → 带错误文案。
    func uninstall(completion: @escaping (Bool, String?) -> Void) {
        guard let pkgPath = uninstallPkgPath else {
            DispatchQueue.main.async {
                completion(false, "alert.uninstall.pkg.missing".localized)
            }
            return
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: pkgPath))
        waitForInstaller(done: { [weak self] in
            guard let self = self else { return false }
            return !FileManager.default.fileExists(atPath: self.uninstallSentinelPath)
        }) { [weak self] success, timedOut in
            guard let self = self else { return }
            if success {
                // 卸载 pkg 已跑完清理。root postinstall 无法访问用户 Keychain，
                // 锁屏密码等条目必须趁 App 进程还活着时由 App 自己清；
                // 同时复位引导完成标记，重装后能重新走首次引导。
                // postinstall 不再一上来 killall：它删完文件后等 App 自行退出
                // （调用方在 completion 里 terminate），超时才兜底 kill。
                ImmurokSecurity.shared.clearAllKeychainData()
                UserDefaults.standard.removeObject(forKey: SetupWizardView.completedKey)
                self.refreshStatus()
                completion(true, nil)
            } else {
                self.refreshStatus()
                completion(false, timedOut ? "alert.operation.timeout".localized : nil)
            }
        }
    }

    // MARK: - Installer 等待

    /// 打开 pkg 后等待 Installer 完成：每秒轮询 `done()`，为真即成功；
    /// Installer.app 退出（用户取消、TCC 拒绝后关窗、安装结束）时做最后一次判定；
    /// 超时按失败。completion 只回调一次，在主线程。
    private func waitForInstaller(timeout: TimeInterval = 300,
                                  done: @escaping () -> Bool,
                                  completion: @escaping (_ success: Bool, _ timedOut: Bool) -> Void) {
        let startTime = Date()
        var finished = false
        var observer: NSObjectProtocol?

        func finish(_ success: Bool, timedOut: Bool) {
            guard !finished else { return }
            finished = true
            if let observer = observer {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
            completion(success, timedOut)
        }

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.installer" else { return }
            finish(done(), timedOut: false)
        }

        func check() {
            guard !finished else { return }
            if done() {
                finish(true, timedOut: false)
                return
            }
            if Date().timeIntervalSince(startTime) >= timeout {
                finish(false, timedOut: true)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { check() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { check() }
    }

}
