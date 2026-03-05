import AppKit
import CoreBluetooth
import ApplicationServices
import CoreGraphics
import ServiceManagement
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    // Core services
    private var pamSocketServer: PAMSocketServer?
    private var sshAgentServer: SSHAgentServer?
    private var cliSocketServer: CLISocketServer?
    private var setupWindow: NSWindow?

    // Quick Fill
    private var globalHotKey: GlobalHotKey?
    private var quickFillPanel: QuickFillPanel?

    // (Password now stored in Keychain, not received via BLE)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("immurok App launched (v5.0 - Menu Bar)")
        Task { @MainActor in LogManager.shared.log("App 启动") }

        // Initialize BLE Manager and start connecting
        let bleManager = BLEManager.shared
        bleManager.connect()

        // Set up BLE callbacks
        setupBLECallbacks(bleManager)

        // Start PAM socket server
        startPAMServer(bleManager)

        // Start SSH Agent server (if enabled)
        if UserDefaults.standard.object(forKey: "immurok.sshAgentEnabled") == nil
            || UserDefaults.standard.bool(forKey: "immurok.sshAgentEnabled") {
            startSSHAgentServer()
        }

        // Start CLI socket server (if enabled)
        if UserDefaults.standard.object(forKey: "immurok.cliEnabled") == nil
            || UserDefaults.standard.bool(forKey: "immurok.cliEnabled") {
            startCLIServer(bleManager)
        }

        // Listen for CLI toggle changes
        NotificationCenter.default.addObserver(
            forName: .cliToggleChanged, object: nil, queue: .main
        ) { [weak self] notification in
            guard let enable = notification.object as? Bool else { return }
            if enable {
                self?.startCLIServer(BLEManager.shared)
            } else {
                self?.cliSocketServer?.stop()
                self?.cliSocketServer = nil
            }
        }

        // Quick Fill (Ctrl+\)
        if UserDefaults.standard.object(forKey: "immurok.quickFillEnabled") == nil
            || UserDefaults.standard.bool(forKey: "immurok.quickFillEnabled") {
            setupQuickFill()
        }

        // Listen for Quick Fill toggle changes
        NotificationCenter.default.addObserver(
            forName: .quickFillToggleChanged, object: nil, queue: .main
        ) { [weak self] notification in
            guard let enable = notification.object as? Bool else { return }
            if enable {
                self?.setupQuickFill()
            } else {
                self?.teardownQuickFill()
            }
        }

        // Listen for Quick Fill hotkey changes — re-register with new key
        NotificationCenter.default.addObserver(
            forName: .quickFillHotkeyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard self?.globalHotKey != nil else { return }
            self?.teardownQuickFill()
            self?.setupQuickFill()
        }

        // Register for Login Items (auto-start)
        registerLoginItem()

        // Check if setup wizard is needed
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.checkAndShowSetupWizard()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("immurok App terminating")

        // Stop services
        teardownQuickFill()
        cliSocketServer?.stop()
        pamSocketServer?.stop()
        SSHAgentServer.shared.stop()
        BLEManager.shared.stop()
    }

    // App should not terminate when window is closed (menu bar app)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - BLE Callbacks

    private func setupBLECallbacks(_ bleManager: BLEManager) {
        // Note: onDeviceConnected/onDeviceDisconnected are set by AppViewModel
        // (single-callback property — setting here would override AppViewModel's handler)

        bleManager.onFingerprintMatch = { [weak self] pageId in
            NSLog("Fingerprint matched! page_id=%d", pageId)
            Task { @MainActor in LogManager.shared.log("指纹匹配 id=\(pageId)") }
            self?.handleFingerprintMatch(pageId: pageId)
        }

        bleManager.onEnrollStatus = { [weak self] event, current, total in
            NSLog("Enrollment status: event=%d, progress=%d/%d", event.rawValue, current, total)
            self?.pamSocketServer?.updateEnrollStatus(event: event, current: current, total: total)

            if event == .complete || event == .failed {
                self?.pamSocketServer?.endEnrollment()
            }
        }

        bleManager.onUnlockResult = { success in
            NSLog("Unlock result: %@", success ? "approved" : "denied")
        }
    }

    // MARK: - PAM Server

    private func startPAMServer(_ bleManager: BLEManager) {
        pamSocketServer = PAMSocketServer(bleManager: bleManager)

        do {
            try pamSocketServer?.start()
            NSLog("PAM socket server started")
        } catch {
            NSLog("Failed to start PAM server: %@", error.localizedDescription)
        }
    }

    // MARK: - SSH Agent Server

    private func startSSHAgentServer() {
        do {
            try SSHAgentServer.shared.start()
            NSLog("SSH Agent server started at %@", SSHAgentServer.shared.socketPath)
        } catch {
            NSLog("Failed to start SSH Agent server: %@", error.localizedDescription)
        }
    }

    // MARK: - CLI Server

    private func startCLIServer(_ bleManager: BLEManager) {
        cliSocketServer = CLISocketServer(bleManager: bleManager)
        do {
            try cliSocketServer?.start()
            NSLog("CLI socket server started")
        } catch {
            NSLog("Failed to start CLI server: %@", error.localizedDescription)
        }
    }

    // MARK: - Fingerprint Match Handler

    private func handleFingerprintMatch(pageId: UInt16) {
        // Check if there's a pending PAM request
        if pamSocketServer?.hasPendingRequest() == true {
            NSLog("Approving pending PAM request")
            Task { @MainActor in LogManager.shared.log("PAM 认证通过") }
            pamSocketServer?.approvePendingRequest()
            return
        }

        // Check if screen is locked
        if isScreenLocked() {
            NSLog("Screen is locked, unlocking...")
            Task { @MainActor in LogManager.shared.log("解锁屏幕") }
            unlockScreen()
            return
        }

        // Screen not locked - check if authorization feature is enabled
        Task { @MainActor in
            let isAuthorizationEnabled = SetupManager.shared.isAuthorizationEnabled
            guard isAuthorizationEnabled else {
                NSLog("Authorization feature disabled, ignoring fingerprint")
                return
            }

            let hasPasswordField = self.isSecureInputFocused()

            if hasPasswordField {
                NSLog("Password field focused, sending Enter and pre-authorization (10s)...")
                LogManager.shared.log("密码框已聚焦 → 发送 Enter + 预授权")
                self.sendEnterKey()
                // Could be sudo or authorization — don't restrict service
                self.pamSocketServer?.setPreAuthorization(duration: 10.0)
            } else if let result = self.findUsePasswordButton() {
                let desc = result.sheetTexts.joined(separator: " | ")
                NSLog("TouchID dialog in [%@]: %@", result.appName, desc)
                LogManager.shared.log("认证窗口 [\(result.appName)] \(desc)")
                AXUIElementPerformAction(result.button, kAXPressAction as CFString)
                LogManager.shared.log("→ 点击「使用密码…」+ 提交空密码")
                // TouchID dialog → must be authorization
                self.pamSocketServer?.setPreAuthorization(duration: 10.0, service: "authorization")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.sendEnterKey()  // 提交空密码 → 触发 PAM
                }
            } else {
                NSLog("No auth dialog detected, setting pre-authorization only (10s)...")
                LogManager.shared.log("无认证窗口 → 仅预授权 10s")
                // No context — don't restrict service
                self.pamSocketServer?.setPreAuthorization(duration: 10.0)
            }
        }
    }

    // MARK: - Screen Lock Detection

    private func isScreenLocked() -> Bool {
        // Check if screen is locked using CGSession
        guard let sessionDict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }

        // Check kCGSessionOnConsoleKey - if false, screen is locked
        if let onConsole = sessionDict["CGSSessionScreenIsLocked"] as? Bool {
            return onConsole
        }

        // Alternative: check "ScreenIsLocked" key
        if let screenIsLocked = sessionDict["ScreenIsLocked"] as? Bool {
            return screenIsLocked
        }

        return false
    }

    // MARK: - Screen Unlock

    private func unlockScreen() {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard AXIsProcessTrusted() else {
            NSLog("No accessibility permission, cannot unlock")
            sendPermissionNotification()
            return
        }

        guard let password = ImmurokSecurity.shared.loadPassword() else {
            NSLog("No password in Keychain")
            return
        }

        Task { @MainActor in LogManager.shared.log("解锁开始 +0ms") }

        // Device's HID CTRL key already wakes the screen and dismisses screensaver.
        // Just wait for the lock screen to appear, then type password.
        // Do NOT send Enter keys before password - they submit empty passwords
        // on an already-awake lock screen, causing failed login attempts.
        waitForScreensaverWindow(timeout: 10.0) { [weak self] found in
            let ms1 = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            Task { @MainActor in LogManager.shared.log("锁屏窗口检测: \(found ? "找到" : "超时") +\(ms1)ms") }
            if found {
                // loginwindow's password field is ready as soon as the window is on screen.
                // AX API cannot detect it (not exposed as AXSecureTextField), so type immediately.
                self?.fakeKeyStrokes(password)
                let ms2 = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                Task { @MainActor in LogManager.shared.log("密码已输入 +\(ms2)ms") }

                // Verify unlock after 2s, retry once if still locked
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if self?.isScreenLocked() == true {
                        Task { @MainActor in LogManager.shared.log("仍锁定，重试") }
                        self?.fakeKeyStrokes(password)
                    } else {
                        let ms3 = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                        Task { @MainActor in LogManager.shared.log("解锁完成 +\(ms3)ms") }
                    }
                    // Password stays in Keychain (no BLE-based pendingPassword to clear)
                }
            } else {
                Task { @MainActor in LogManager.shared.log("锁屏窗口未检测到（超时）") }
            }
        }
    }

    /// Check if a password field (AXSecureTextField) is currently focused
    private func isSecureInputFocused() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else {
            return false
        }
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(focusedElement as! AXUIElement, kAXSubroleAttribute as CFString, &subrole)
        return (subrole as? String) == "AXSecureTextField"
    }

    /// Find the "Use Password..." button in a TouchID auth sheet (AXSheet → AXButton)
    /// Returns (button, appName, sheetDescription) for logging
    private func findUsePasswordButton() -> (button: AXUIElement, appName: String, sheetTexts: [String])? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appName = frontApp.localizedName ?? "pid=\(frontApp.processIdentifier)"
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }

        for window in windows {
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { continue }

            for child in children {
                var roleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
                guard (roleRef as? String) == "AXSheet" else { continue }

                // Found a sheet — collect text labels and look for password button
                var sheetChildrenRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &sheetChildrenRef) == .success,
                      let sheetChildren = sheetChildrenRef as? [AXUIElement] else { continue }

                var texts: [String] = []
                var buttons: [AXUIElement] = []

                for el in sheetChildren {
                    var elRoleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &elRoleRef)
                    let role = elRoleRef as? String ?? ""

                    if role == "AXStaticText" {
                        var valRef: CFTypeRef?
                        AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valRef)
                        if let text = valRef as? String, !text.isEmpty {
                            texts.append(text)
                        }
                    } else if role == "AXButton" {
                        buttons.append(el)
                    }
                }

                // Identify TouchID auth sheet by "Touch ID" / "触控" in text
                let isTouchIDSheet = texts.contains { $0.contains("Touch ID") || $0.contains("触控") }
                // Last button is "Use Password..." (non-cancel action button)
                if isTouchIDSheet, let lastBtn = buttons.last {
                    return (lastBtn, appName, texts)
                }
            }
        }
        return nil
    }

    /// Check if screensaver/loginwindow is showing
    private func isScreensaverWindowVisible() -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for window in windowList {
            guard let ownerName = window[kCGWindowOwnerName as String] as? String else {
                continue
            }

            // Check for loginwindow (lock screen) or ScreenSaverEngine
            if ownerName == "loginwindow" || ownerName == "ScreenSaverEngine" {
                // Also check if window is on screen and has reasonable size
                if let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                   let width = bounds["Width"], let height = bounds["Height"],
                   width > 100 && height > 100 {
                    return true
                }
            }
        }
        return false
    }

    /// Wait for password field (AXSecureTextField) to appear, polling every 10ms.
    private func waitForPasswordField(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let startTime = CFAbsoluteTimeGetCurrent()

        func check() {
            if isSecureInputFocused() {
                completion(true)
                return
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            if elapsed >= timeout {
                completion(false)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                check()
            }
        }

        check()
    }

    /// Wait for screensaver window to appear with timeout
    private func waitForScreensaverWindow(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let startTime = CFAbsoluteTimeGetCurrent()
        let checkInterval: TimeInterval = 0.1

        func checkWindow() {
            if isScreensaverWindowVisible() {
                completion(true)
                return
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            if elapsed >= timeout {
                completion(false)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + checkInterval) {
                checkWindow()
            }
        }

        checkWindow()
    }

    // MARK: - Keyboard Simulation

    private func fakeKeyStrokes(_ string: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        let PER = 20
        let uniCharCount = string.utf16.count
        var strIndex = string.utf16.startIndex

        for offset in stride(from: 0, to: uniCharCount, by: PER) {
            let pressEvent = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: true)
            let len = offset + PER < uniCharCount ? PER : uniCharCount - offset
            let buffer = UnsafeMutablePointer<UniChar>.allocate(capacity: len)
            defer { buffer.deallocate() }

            for i in 0..<len {
                buffer[i] = string.utf16[strIndex]
                strIndex = string.utf16.index(after: strIndex)
            }

            pressEvent?.keyboardSetUnicodeString(stringLength: len, unicodeString: buffer)
            pressEvent?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false)?.post(tap: .cghidEventTap)
        }

        // Return key
        CGEvent(keyboardEventSource: src, virtualKey: 0x34, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 0x34, keyDown: false)?.post(tap: .cghidEventTap)
    }

    private func sendEnterKey() {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: 0x34, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 0x34, keyDown: false)?.post(tap: .cghidEventTap)
    }

    // MARK: - Setup Wizard

    @MainActor
    private func checkAndShowSetupWizard() {
        let setupManager = SetupManager.shared

        if setupManager.needsSetup {
            NSLog("Setup incomplete, showing wizard")
            showSetupWizard()
        } else {
            NSLog("Setup complete: PAM=%@, Accessibility=%@",
                  setupManager.isPAMModuleInstalled ? "yes" : "no",
                  setupManager.hasAccessibilityPermission ? "yes" : "no")
        }
    }

    @MainActor
    private func showSetupWizard() {
        // Create a new window for the setup wizard
        let wizardView = SetupWizardView()
        let hostingController = NSHostingController(rootView: wizardView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "wizard.title".localized
        window.styleMask = [.titled, .closable]
        window.center()
        window.makeKeyAndOrderFront(nil)

        // Keep a reference to prevent deallocation
        self.setupWindow = window

        // Bring app to foreground
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Accessibility Permission

    private func sendPermissionNotification() {
        // Send notification about missing permission
        let script = """
        display notification "请在系统设置中授予辅助功能权限" with title "immurok" subtitle "无法解锁屏幕"
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
    }

    // MARK: - Login Item Registration

    private func registerLoginItem() {
        let service = SMAppService.mainApp

        switch service.status {
        case .notRegistered:
            NSLog("Registering as login item...")
            do {
                try service.register()
                NSLog("Registered as login item")
            } catch {
                NSLog("Failed to register as login item: %@", error.localizedDescription)
            }
        case .enabled:
            NSLog("Already registered as login item")
        case .requiresApproval:
            NSLog("Login item requires approval in System Settings")
        case .notFound:
            NSLog("Login item service not found")
        @unknown default:
            NSLog("Unknown login item status")
        }
    }

    // MARK: - Quick Fill

    private func setupQuickFill() {
        guard globalHotKey == nil else { return }
        globalHotKey = GlobalHotKey()
        globalHotKey?.onTrigger = { [weak self] in
            self?.toggleQuickFill()
        }
        globalHotKey?.register()
        NSLog("Quick Fill hotkey registered")
    }

    private func teardownQuickFill() {
        quickFillPanel?.close()
        quickFillPanel = nil
        globalHotKey?.unregister()
        globalHotKey = nil
    }

    private func toggleQuickFill() {
        if quickFillPanel?.isVisible == true {
            quickFillPanel?.close()
        } else {
            quickFillPanel = QuickFillPanel()
            quickFillPanel?.show()
        }
    }

    // MARK: - Static Helpers

    static func hasAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
