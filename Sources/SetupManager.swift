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

    // MARK: - Paths

    private let pamModuleDestination = "/usr/local/lib/pam/pam_immurok.so"

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
