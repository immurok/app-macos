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

    // Suppress 0x23 long-press lock if it arrives in the tail of an actual
    // auth flow. Firmware schedules the LOCK_HOLD timer on TOUCH rising edge
    // and does NOT clear it on FP match (R599S DETECT misbehaves), so a
    // finger held ~1.6s after a successful auth would otherwise lock the
    // screen the user just unlocked into. Only set when we actually enter an
    // auth branch — a bare match with no auth context (e.g. long-press to
    // lock with no dialog visible) leaves this nil so the lock can fire.
    private var lastAuthFlowAt: Date?
    private static let lockSuppressWindow: TimeInterval = 3.0

    // (Password now stored in Keychain, not received via BLE)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ignore SIGPIPE process-wide. Without this, send() on a Unix socket
        // whose peer has just closed (e.g. ota-update.py interrupted with
        // Ctrl+C mid-session) delivers SIGPIPE and terminates the app — and
        // mid-OTA termination also strands the device in OTA mode (LED stuck
        // blinking fast blue). We check for errors at each send() site
        // instead.
        signal(SIGPIPE, SIG_IGN)

        NSLog("immurok App launched (v1.6 - Menu Bar)")
        Task { @MainActor in LogManager.shared.log("App started") }

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
            Task { @MainActor in LogManager.shared.log("FP matched id=\(pageId)") }
            self?.handleFingerprintMatch(pageId: pageId)
        }

        bleManager.onLockRequest = { [weak self] in
            self?.handleLockRequest()
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
        // Refresh lock-suppression window on any AUTH OK so that a held finger
        // during BLE-backed sudo (which never sees a 0x21 proactive match)
        // still suppresses the trailing 0x23 long-press lock.
        pamSocketServer?.onAuthSuccess = { [weak self] in
            self?.lastAuthFlowAt = Date()
        }

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
        // Reject if device not verified (challenge-response failed)
        guard BLEManager.shared.isDeviceVerified else {
            NSLog("Fingerprint match ignored: device not verified")
            Task { @MainActor in LogManager.shared.log("FP match ignored: device not verified") }
            return
        }

        // Check if there's a pending PAM request
        if pamSocketServer?.hasPendingRequest() == true {
            NSLog("Approving pending PAM request")
            Task { @MainActor in LogManager.shared.log("PAM auth passed") }
            lastAuthFlowAt = Date()
            pamSocketServer?.approvePendingRequest()
            return
        }

        // Check if screen is locked
        if isScreenLocked() {
            NSLog("Screen is locked, unlocking...")
            Task { @MainActor in LogManager.shared.log("Unlocking screen") }
            lastAuthFlowAt = Date()
            // Audible cue: typing the password + window animation can take ~2s
            // and the screen often goes black mid-flow. Configurable via
            // Features tab; empty string = silent.
            let soundName = UserDefaults.standard.string(forKey: "immurok.unlockSound") ?? "Glass"
            if !soundName.isEmpty {
                NSSound(named: soundName)?.play()
            }
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
                // Any focused password field at this point is GUI auth, not
                // terminal sudo: terminal sudo runs through pam_immurok which
                // arms BLE-backed AUTH on the device, so the user's touch is
                // consumed as AUTH_OK by the BLE layer and never reaches
                // handleFingerprintMatch. The remaining cases (System
                // Settings sheet, SecurityAgent standalone window for
                // Chrome/etc.) all map to the `authorization` PAM service.
                NSLog("Password field focused, sending Enter + pre-auth (3s, authorization)")
                LogManager.shared.log("Password field focused → send Enter + pre-auth authorization 3s")
                self.lastAuthFlowAt = Date()
                self.sendEnterKey()
                self.pamSocketServer?.setPreAuthorization(duration: 3.0, services: ["authorization"])
            } else if let result = self.findUsePasswordButton() {
                let desc = result.sheetTexts.joined(separator: " | ")
                NSLog("TouchID dialog in [%@]: %@", result.appName, desc)
                LogManager.shared.log("Auth window [\(result.appName)] \(desc)")
                self.lastAuthFlowAt = Date()
                AXUIElementPerformAction(result.button, kAXPressAction as CFString)
                LogManager.shared.log("→ Click 'Use Password...' + submit empty password")
                // TouchID dialog → authorization service
                self.pamSocketServer?.setPreAuthorization(duration: 3.0, services: ["authorization"])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.sendEnterKey()  // 提交空密码 → 触发 PAM
                }
            } else {
                // No identified auth context — do NOT pre-authorize.
                // Previously set a 10s any-service window here, which was the
                // most exploitable path: a finger touch with no UI intent
                // would silently authorize the next sudo from any same-UID
                // process. Refuse to grant authority without explicit context.
                NSLog("No auth dialog detected, ignoring fingerprint (no pre-auth)")
                LogManager.shared.log("No auth window → skip pre-auth (avoid consumption by unrelated processes)")
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

        Task { @MainActor in LogManager.shared.log("Unlock start +0ms") }

        // Device's HID CTRL key already wakes the screen and dismisses screensaver.
        // Just wait for the lock screen to appear, then type password.
        // Do NOT send Enter keys before password - they submit empty passwords
        // on an already-awake lock screen, causing failed login attempts.
        waitForScreensaverWindow(timeout: 10.0) { [weak self] found in
            let ms1 = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            Task { @MainActor in LogManager.shared.log("Lock screen window detect: \(found ? "found" : "timeout") +\(ms1)ms") }
            guard found, let self = self else {
                if !found {
                    Task { @MainActor in LogManager.shared.log("Lock screen window not detected (timeout)") }
                }
                return
            }
            // Re-confirm loginwindow owns the focus before posting key events.
            // CGEvent keystrokes go to whatever currently has key focus; if a
            // race or attacker process held focus past our window-visible
            // detection, the password would land in the wrong window.
            guard self.isLoginWindowFrontmost() else {
                Task { @MainActor in LogManager.shared.log("Aborting unlock: loginwindow not frontmost") }
                return
            }
            // loginwindow's password field is ready as soon as the window is on screen.
            // AX API cannot detect it (not exposed as AXSecureTextField), so type immediately.
            self.fakeKeyStrokes(password)
            let ms2 = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            Task { @MainActor in LogManager.shared.log("Password entered +\(ms2)ms") }

            // Verify unlock after 2s: check lock screen window (not session state,
            // which updates slower). If loginwindow is gone, unlock succeeded.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self else { return }
                if self.isScreensaverWindowVisible() {
                    // Same frontmost check on retry — if focus moved to some
                    // other process during the 2s window, abort.
                    guard self.isLoginWindowFrontmost() else {
                        Task { @MainActor in LogManager.shared.log("Aborting retry: loginwindow not frontmost") }
                        return
                    }
                    Task { @MainActor in LogManager.shared.log("Still locked, retrying") }
                    self.fakeKeyStrokes(password)
                } else {
                    let ms3 = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    Task { @MainActor in LogManager.shared.log("Unlock done +\(ms3)ms") }
                }
                // Password stays in Keychain (no BLE-based pendingPassword to clear)
            }
        }
    }

    /// Confirm the lock-screen process owns the keyboard focus right now.
    /// Used as a guard before fakeKeyStrokes types the password — keystrokes
    /// are routed by frontmost focus, not by which window we just detected.
    private func isLoginWindowFrontmost() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        switch frontApp.bundleIdentifier {
        case "com.apple.loginwindow", "com.apple.ScreenSaver.Engine":
            return true
        default:
            // Fall back to executable name. Both processes are Apple-signed
            // so spoofing the bundle id would require a separate exploit.
            return frontApp.localizedName == "loginwindow"
                || frontApp.localizedName == "ScreenSaverEngine"
        }
    }

    // MARK: - Lock Request (long-press on touch sensor)

    /// Routes a 0x23 long-press lock request from the device.
    /// Per protocol spec: if screen is already locked we ignore (the preceding
    /// 0x21 unlock notify is in flight). If unlocked we cancel any pre-auth
    /// the 0x21 may have armed and then lock the screen.
    /// Gated by `immurok.screenLockEnabled` (default off) — opt-in feature.
    private func handleLockRequest() {
        let enabled = UserDefaults.standard.bool(forKey: "immurok.screenLockEnabled")
        guard enabled else {
            NSLog("Lock request ignored: feature disabled (immurok.screenLockEnabled=false)")
            Task { @MainActor in LogManager.shared.log("Lock request ignored (feature disabled)") }
            return
        }
        if isScreenLocked() {
            NSLog("Lock request ignored: screen already locked")
            Task { @MainActor in LogManager.shared.log("Lock request ignored (already locked)") }
            return
        }
        // Suppress lock if an auth flow just started. Firmware fires the
        // LOCK_HOLD timer 1.6s after touch rising edge regardless of match
        // outcome, so a successful auth where the user's finger lingers on the
        // pad would otherwise lock the screen the user just unlocked into.
        // Only suppresses when a real auth branch ran — bare matches with no
        // auth context (long-press to lock with no dialog) leave this nil.
        if let lastFlow = lastAuthFlowAt,
           Date().timeIntervalSince(lastFlow) < Self.lockSuppressWindow {
            NSLog("Lock request ignored: recent auth flow (tail)")
            Task { @MainActor in LogManager.shared.log("Lock request ignored (recent auth flow)") }
            return
        }
        // immurok's own auth surfaces (agent-approval overlay from
        // `imk run --agent`, and the QuickFill panel from Ctrl+\) are custom
        // NSPanels, not OS AXSecureTextField/SecurityAgent — the AX probes
        // below would miss them. Firmware's pending_auth check also doesn't
        // help: AUTH_REQUEST's pending_auth clears at match (~600ms), so by
        // the time LOCK_HOLD fires at 1s the firmware sees an idle state
        // and emits the lock. Catch them here instead.
        //
        // BLEManager dispatches onLockRequest via DispatchQueue.main.async
        // so we're already on the main thread; assertion lets us reach the
        // @MainActor-isolated state without an awaited hop that would let
        // the lock decision race the overlay state.
        let immurokAuthVisible = MainActor.assumeIsolated {
            AuthRequestOverlay.shared.isShowing
                || (self.quickFillPanel?.isVerifying ?? false)
        }
        if immurokAuthVisible {
            NSLog("Lock request ignored: immurok auth surface active")
            Task { @MainActor in LogManager.shared.log("Lock request ignored (immurok auth surface active)") }
            return
        }
        // Live re-check: the host might be currently requesting authentication
        // (focused password field or visible TouchID/SecurityAgent sheet) but
        // the lastAuthFlowAt timestamp didn't get set in time. The 0x21 match
        // arrives ~600ms after touch and the AX queries that detect auth
        // context can take 100-500ms; the 0x23 long-press arrives at 1s.
        // When AX is still in flight at 1s, lastAuthFlowAt is nil and the
        // long-press would lock the screen the user is trying to unlock into.
        // Re-querying AX here (we're on main, callback dispatched via
        // BLEManager's DispatchQueue.main.async) catches that race.
        if isSecureInputFocused() {
            NSLog("Lock request ignored: password field focused")
            Task { @MainActor in LogManager.shared.log("Lock request ignored (password field active)") }
            return
        }
        if findUsePasswordButton() != nil {
            NSLog("Lock request ignored: TouchID/auth dialog active")
            Task { @MainActor in LogManager.shared.log("Lock request ignored (auth dialog visible)") }
            return
        }
        NSLog("Lock request: locking screen")
        Task { @MainActor in LogManager.shared.log("Locking screen (long press)") }
        // Drop any pre-authorization a preceding 0x21 may have set; locking
        // makes that auth context invalid anyway.
        pamSocketServer?.clearPreAuthorization()
        lockScreen()
    }

    /// Lock the macOS user session.
    /// Uses CGSession's `-suspend` action which is the same operation triggered
    /// by Ctrl-Cmd-Q, requires no admin privileges, and ignores user-customized
    /// keyboard shortcuts.
    private func lockScreen() {
        let cgSession = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cgSession)
        process.arguments = ["-suspend"]
        do {
            try process.run()
        } catch {
            NSLog("lockScreen: CGSession failed (%@), falling back to keystroke", error.localizedDescription)
            // Fallback: synthesize Ctrl-Cmd-Q. May fail if user has rebound
            // the shortcut or doesn't have accessibility permission.
            let src = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0x0C /* Q */, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0x0C, keyDown: false)
            down?.flags = [.maskCommand, .maskControl]
            up?.flags = [.maskCommand, .maskControl]
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
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

        // Clear any stuck modifier keys (e.g. CTRL from BLE HID wake key)
        // by posting flagsChanged with empty flags before typing
        if let flagsEvent = CGEvent(source: src) {
            flagsEvent.type = .flagsChanged
            flagsEvent.flags = []
            flagsEvent.post(tap: .cghidEventTap)
        }

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
            let p = QuickFillPanel()
            // Mirror the PAM `onAuthSuccess` hookup so QuickFill's
            // fingerprint-gated reads (OTP / API / SSH) refresh
            // lastAuthFlowAt — needed because the trailing 0x23
            // LOCK_REQUEST arrives milliseconds after the OTP response
            // on the same BLE callback queue, and isVerifying flips to
            // false before handleLockRequest can read it.
            p.onAuthSuccess = { [weak self] in
                self?.lastAuthFlowAt = Date()
            }
            p.show()
            quickFillPanel = p
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
