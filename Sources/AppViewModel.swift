import SwiftUI
import Combine

extension Notification.Name {
    static let sshKeyCacheSynced = Notification.Name("sshKeyCacheSynced")
    static let cliToggleChanged = Notification.Name("cliToggleChanged")
    static let quickFillToggleChanged = Notification.Name("quickFillToggleChanged")
    static let quickFillHotkeyChanged = Notification.Name("quickFillHotkeyChanged")
    /// 辅助功能权限从无→有翻转时发出（用于在授权后重注册全局热键）
    static let accessibilityGranted = Notification.Name("accessibilityGranted")
    /// 检测到固件新版本（object = 版本号 String），用于弹系统通知
    static let firmwareUpdateAvailable = Notification.Name("firmwareUpdateAvailable")
    /// 固件升级完成（object = 版本号 String），用于弹完成提示
    static let firmwareUpdateFinished = Notification.Name("firmwareUpdateFinished")
}

@MainActor
class AppViewModel: ObservableObject {
    @Published var isDeviceConnected = false
    @Published var deviceName: String?
    @Published var fingerprintCount = 0
    @Published var isDevicePaired = false  // Device-side pairing status (ECDH)
    @Published var isDeviceVerified = false  // Challenge-response verification passed
    @Published var isPasswordConfigured = false  // Keychain has password
    @Published var hasLocalPairing = false  // Local Keychain has shared key or password
    var gateController = FingerprintGateController()
    @Published var isPairing = false  // ECDH pairing in progress
    @Published var pairingPrompt: String? = nil  // UI prompt during pair (e.g. "press device button")

    // Firmware version
    @Published var firmwareVersion: String?

    // Battery level (0-100%, nil = unknown)
    @Published var batteryLevel: Int?

    // Raw battery voltage in mV for calibration display (firmware ≥ 1.3.4)
    @Published var batteryVoltageMv: Int?

    // Bluetooth permission state
    @Published var bluetoothStatus: BluetoothAuthStatus = .notDetermined

    private let bleManager = BLEManager.shared

    /// 固件升级服务（懒建避免 init 顺序问题；连接就绪后 checkIfDue）
    private(set) lazy var firmwareUpdate = FirmwareUpdateService(bleManager: bleManager, viewModel: self)

    var deviceStatusText: String {
        // Check bluetooth status first
        switch bluetoothStatus {
        case .denied:
            return "bluetooth.denied".localized
        case .poweredOff:
            return "bluetooth.off".localized
        case .unsupported:
            return "bluetooth.unsupported".localized
        default:
            break
        }

        if let name = deviceName {
            return "device.connected.name".localized(name)
        }
        return isDeviceConnected ? "device.connected".localized : "device.disconnected".localized
    }

    /// Connection status with firmware version inline, e.g. "Connected: immurok IK-1 (FW: 1.2.14)"
    var deviceStatusTextWithFirmware: String {
        let base = deviceStatusText
        guard isDeviceConnected, let fw = firmwareVersion else { return base }
        return "\(base) (FW: \(fw))"
    }

    /// Whether bluetooth needs user attention (permission or power)
    var needsBluetoothAttention: Bool {
        switch bluetoothStatus {
        case .denied, .poweredOff:
            return true
        default:
            return false
        }
    }

    private var fingerprintObserver: Any?
    private var gateObserver: Any?
    private var gateCancellable: AnyCancellable?
    private var fwUpdateCancellable: AnyCancellable?
    private var pendingGatedOperation = false

    // 2026-05-16 battery sampling strategy:
    //   - NO BAS notify subscription (BLEManager explicitly writes CCCD=0).
    //     Verified: app-level Notify subscription correlates with disconnects
    //     after screen lock (XPC delivery competes with App Nap suspension).
    //   - macOS itself still Reads BAS independently → system Settings battery
    //     UI still works.
    //   - immurok app: active GET_BATT_RAW once per hour, BUT ONLY while
    //     screen is unlocked. Pauses during screen lock to avoid any BLE
    //     activity during the macOS power-managed state.
    //   - User-initiated refresh (UI click) always works via refreshDeviceStatus.
    private var batteryReadTimer: Timer?
    private let batteryReadInterval: TimeInterval = 60 * 60   // 1 hour
    private var isScreenLocked = false
    private var screenLockObserver: Any?
    private var screenUnlockObserver: Any?

    init() {
        setupBLECallbacks()
        updateStatus()
        updateBluetoothStatus()
        setupScreenLockObservers()
        startBatteryReadTimer()   // assume unlocked at start; lock notif will pause if needed

        gateCancellable = gateController.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        fwUpdateCancellable = firmwareUpdate.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        fingerprintObserver = NotificationCenter.default.addObserver(
            forName: .fingerprintCacheUpdated, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncFingerprintCountFromCache()
            }
        }

        // Only show gate when AppViewModel itself initiated a gated operation (factory reset)
        gateObserver = NotificationCenter.default.addObserver(
            forName: BLEManager.fingerprintGateRequiredNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.pendingGatedOperation else { return }
                self.gateController.onGateRequired()
            }
        }
    }

    private func updateBluetoothStatus() {
        bluetoothStatus = bleManager.bluetoothAuthStatus
    }

    func checkPasswordStatus() {
        // Password status now comes from device via GET_STATUS
        // Updated by refreshDeviceStatus()
    }

    /// Refresh device status (bitmap + paired)
    func refreshDeviceStatus(completion: (() -> Void)? = nil) {
        guard isDeviceConnected else {
            completion?()
            return
        }
        bleManager.getDeviceStatus { [weak self] bitmap, isPaired, battery, fwVersion in
            Task { @MainActor in
                let count = (0..<5).filter { bitmap & (1 << $0) != 0 }.count
                self?.fingerprintCount = count
                self?.isDevicePaired = isPaired
                self?.isPasswordConfigured = ImmurokSecurity.shared.hasPassword()
                self?.batteryLevel = battery
                if let fwVersion = fwVersion {
                    self?.firmwareVersion = fwVersion
                }
                FingerprintViewModel.cachedBitmap = bitmap
                FingerprintViewModel.isCacheValid = true

                // GET_BATT_RAW forces a fresh ADC measurement on the device
                // (~500ms) and returns mV + freshly-measured percentage.
                // We override the cached % from GET_STATUS so the user sees
                // real-time charging progress instead of 60s-stale ticks.
                // Older firmware (< 1.3.4) doesn't implement the opcode and
                // the request times out, leaving the GET_STATUS value in
                // place — graceful degradation.
                self?.bleManager.getBatteryRaw { raw in
                    Task { @MainActor in
                        if let raw = raw {
                            self?.batteryVoltageMv = raw.mv
                            self?.batteryLevel = raw.pct
                        } else {
                            self?.batteryVoltageMv = nil
                        }
                        completion?()
                    }
                }
            }
        }
    }

    // MARK: - BLE Callbacks

    private func setupBLECallbacks() {
        bleManager.onDeviceConnected = { [weak self] name in
            Task { @MainActor in
                NSLog("Device connected: %@", name)
                LogManager.shared.log("Device connected: \(name)")
                self?.isDeviceConnected = true
                self?.isDeviceVerified = self?.bleManager.isDeviceVerified ?? false
                self?.deviceName = name

                // Invalidate FingerprintView cache on reconnect
                FingerprintViewModel.invalidateCache()

                // Serialize BLE commands to avoid responseCallback race:
                // GET_STATUS first, then SSH key sync
                self?.refreshDeviceStatus {
                    SSHKeyCache.shared.sync {
                        NSLog("SSH key cache synced")
                        // Mirror SSH names from SSHKeyCache → KeyNameCache so
                        // QuickFill / list views can display them, and forward
                        // SSHKeyCache's digest so KeyNameCache's SSH cache
                        // stays valid (avoids unnecessary refetch on next
                        // syncCategory(.ssh)).
                        KeyNameCache.shared.replaceCategory(
                            .ssh,
                            with: SSHKeyCache.shared.entries.map {
                                KeyNameCache.Entry(index: $0.index, name: $0.name,
                                                   service: "", category: .ssh)
                            },
                            checksum: SSHKeyCache.shared.checksum
                        )
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .sshKeyCacheSynced, object: nil)
                        }
                        // Sync non-SSH categories only (SSH already populated above)
                        KeyNameCache.shared.syncNonSSH {
                            NSLog("Key name cache synced")
                        }
                    }
                }
            }
        }

        bleManager.onDeviceDisconnected = { [weak self] in
            Task { @MainActor in
                NSLog("Device disconnected")
                LogManager.shared.log("Device disconnected")
                self?.isDeviceConnected = false
                self?.isDeviceVerified = false
                self?.deviceName = nil
                self?.firmwareVersion = nil
                self?.batteryLevel = nil
                self?.batteryVoltageMv = nil
                self?.fingerprintCount = 0
                self?.isDevicePaired = false
                self?.pendingGatedOperation = false
                self?.gateController.reset()
                // Don't clear KeyNameCache on disconnect — the digest cache
                // is designed to survive across disconnects. Reconnect's
                // sync will hit the cache via checksum match (1 KEY_COUNT
                // round-trip per category) instead of a full refetch.

                FingerprintViewModel.cachedBitmap = 0
                FingerprintViewModel.isCacheValid = false
            }
        }

        bleManager.onFirmwareVersionRead = { [weak self] version in
            Task { @MainActor in
                self?.firmwareVersion = version
                self?.firmwareUpdate.resumePendingHopIfAny()
                self?.firmwareUpdate.checkIfDue()
            }
        }

        // BAS (Battery Service 0x180F) callback fires on the one-shot
        // readValue we do at connect (BLEManager). We've explicitly written
        // CCCD=0 so device won't push, but this callback also runs for the
        // initial Read response → update menubar % only. ik-batt.log entries
        // come exclusively from the hourly active-read path so we don't
        // double-log on connect bursts.
        bleManager.onBatteryLevelNotified = { [weak self] pct in
            Task { @MainActor in
                self?.batteryLevel = pct
            }
        }

        bleManager.onBluetoothStatusChanged = { [weak self] status in
            Task { @MainActor in
                self?.bluetoothStatus = status
            }
        }
    }

    func updateStatus() {
        isDeviceConnected = bleManager.deviceState.isConnected
        isPasswordConfigured = ImmurokSecurity.shared.hasPassword()
        hasLocalPairing = ImmurokSecurity.shared.isPaired || isPasswordConfigured

        if case .connected(let name) = bleManager.deviceState {
            deviceName = name
        } else {
            deviceName = nil
            fingerprintCount = 0
            isDevicePaired = false
        }
    }

    func refreshFingerprintCount() {
        guard isDeviceConnected else {
            fingerprintCount = 0
            return
        }

        bleManager.getFingerprintBitmap { [weak self] bitmap in
            Task { @MainActor in
                let count = (0..<5).filter { bitmap & (1 << $0) != 0 }.count
                self?.fingerprintCount = count
                // Sync to FingerprintViewModel's static cache
                FingerprintViewModel.cachedBitmap = bitmap
                FingerprintViewModel.isCacheValid = true
            }
        }
    }

    private func syncFingerprintCountFromCache() {
        let bitmap = FingerprintViewModel.cachedBitmap
        fingerprintCount = (0..<5).filter { bitmap & (1 << $0) != 0 }.count
    }

    func testAuth() {
        guard isDeviceConnected, !gateController.isPresented else {
            if !isDeviceConnected {
                showAlert(title: "test.device.not.connected".localized, message: "test.connect.first".localized)
            }
            return
        }

        gateController.present(title: "fingerprint.test".localized)

        bleManager.requestUnlock(timeout: 30.0) { [weak self] success in
            Task { @MainActor in
                if success {
                    self?.gateController.reportSuccess()
                } else {
                    self?.gateController.reportFailed()
                }
            }
        }
    }

    func configurePassword() {
        // 未配对时不允许设置密码
        guard isDevicePaired else {
            showAlert(title: "alert.error".localized, message: "password.need.pair.first".localized)
            return
        }

        let alert = NSAlert()
        alert.messageText = "password.title".localized
        alert.informativeText = "password.message".localized
        alert.alertStyle = .informational
        alert.addButton(withTitle: "password.save".localized)
        alert.addButton(withTitle: "alert.cancel".localized)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 54))

        let input1 = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: 250, height: 24))
        input1.placeholderString = "password.placeholder".localized

        let input2 = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        input2.placeholderString = "password.confirm.placeholder".localized

        container.addSubview(input1)
        container.addSubview(input2)
        alert.accessoryView = container

        let response = alert.runModalOverSettings()
        if response == .alertFirstButtonReturn {
            let password = input1.stringValue
            let confirm = input2.stringValue

            guard !password.isEmpty else {
                showAlert(title: "alert.error".localized, message: "password.error.empty".localized)
                return
            }

            guard password == confirm else {
                showAlert(title: "alert.error".localized, message: "password.error.mismatch".localized)
                return
            }

            // Save password to Keychain (local only, not sent via BLE)
            ImmurokSecurity.shared.savePassword(password)
            isPasswordConfigured = true
            hasLocalPairing = true
            showAlert(title: "password.saved".localized, message: "password.saved.message".localized)
        }
    }

    // MARK: - ECDH Pairing

    func startPairing() {
        guard isDeviceConnected else {
            showAlert(title: "alert.error".localized, message: "test.connect.first".localized)
            return
        }

        let hasLocalStaleData = ImmurokSecurity.shared.isPaired || ImmurokSecurity.shared.hasPassword()
        if hasLocalStaleData {
            if isDevicePaired {
                showAlert(title: "alert.error".localized, message: "pairing.already.paired".localized)
                return
            }
            // Divergence: device-side reports unpaired (e.g. swapped or factory-reset
            // device), but local Keychain still holds the previous device's shared
            // key / password. Confirm clearing before re-pairing.
            let alert = NSAlert()
            alert.messageText = "pairing.stale.local.title".localized
            alert.informativeText = "pairing.stale.local.message".localized
            alert.alertStyle = .warning
            alert.addButton(withTitle: "alert.cancel".localized)
            alert.addButton(withTitle: "pairing.stale.local.continue".localized)
            if alert.runModalOverSettings() != .alertSecondButtonReturn {
                return
            }
            clearLocalPairing()
        }

        // Pre-check device fingerprint bitmap. Firmware refuses PAIR_INIT
        // when bitmap != 0; we mirror the check here for an immediate UI
        // message rather than waiting for the device round-trip.
        bleManager.getDeviceStatus { [weak self] bitmap, _, _, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if bitmap != 0 {
                    self.showAlert(title: "alert.error".localized, message: "pairing.needs.reset".localized)
                    return
                }
                self.runPairing()
            }
        }
    }

    private func runPairing() {
        isPairing = true
        pairingPrompt = "pairing.in.progress".localized

        // Wire up button-press status callbacks for UI feedback.
        bleManager.onPairWaitButton = { [weak self] in
            Task { @MainActor in
                self?.pairingPrompt = "pairing.press.button".localized
            }
        }
        bleManager.onPairButtonConfirmed = { [weak self] in
            Task { @MainActor in
                self?.pairingPrompt = "pairing.in.progress".localized
            }
        }

        bleManager.startPairing { [weak self] failure in
            Task { @MainActor in
                guard let self = self else { return }
                self.isPairing = false
                self.pairingPrompt = nil
                self.bleManager.onPairWaitButton = nil
                self.bleManager.onPairButtonConfirmed = nil

                if failure == nil {
                    ImmurokSecurity.shared.clearPassword()
                    self.isDevicePaired = true
                    self.isDeviceVerified = self.bleManager.isDeviceVerified
                    self.isPasswordConfigured = false
                    self.hasLocalPairing = true
                    self.showAlert(title: "pairing.success".localized, message: "pairing.success.set.password".localized)
                    self.configurePassword()
                    return
                }

                let messageKey: String
                switch failure! {
                case .needsReset:       messageKey = "pairing.needs.reset"
                case .buttonTimeout:    messageKey = "pairing.timeout"
                case .buttonCancelled:  messageKey = "pairing.cancelled"
                case .generic:          messageKey = "pairing.failed"
                }
                self.showAlert(title: "alert.error".localized, message: messageKey.localized)
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModalOverSettings()
    }

    // MARK: - Unpair

    func unpair() {
        let alert = NSAlert()
        alert.messageText = "unpair.title".localized
        alert.informativeText = "unpair.message".localized
        alert.alertStyle = .warning
        alert.addButton(withTitle: "alert.cancel".localized)
        alert.addButton(withTitle: "unpair.confirm".localized)

        let response = alert.runModalOverSettings()
        if response == .alertSecondButtonReturn {
            doUnpair()
        }
    }

    private func doUnpair() {
        clearLocalPairing()
        showAlert(title: "unpair.done".localized, message: "unpair.done.message".localized)
    }

    /// Clear all locally-stored pairing data. UI-less; callers handle messaging.
    private func clearLocalPairing() {
        fingerprintCount = 0
        isDevicePaired = false
        isPasswordConfigured = false
        hasLocalPairing = false
        ImmurokSecurity.shared.clearPairingData()
        ImmurokSecurity.shared.clearPassword()
        FingerprintViewModel.cachedBitmap = 0
        FingerprintViewModel.isCacheValid = true
        NotificationCenter.default.post(name: .fingerprintCacheUpdated, object: nil)
    }

    // MARK: - Bluetooth Settings

    /// Open System Settings to Bluetooth Privacy page
    func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open System Settings to Bluetooth page (for poweredOff)
    func openBluetoothPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.Bluetooth") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Battery sampling (active read, screen-lock-aware)

    /// Subscribe to macOS screen lock/unlock distributed notifications.
    /// Posted by loginwindow when user locks (Cmd+Ctrl+Q or auto-lock) or
    /// unlocks (password / Touch ID / immurok fingerprint).
    private func setupScreenLockObservers() {
        let nc = DistributedNotificationCenter.default()
        screenLockObserver = nc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleScreenLock() }
        }
        screenUnlockObserver = nc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleScreenUnlock() }
        }
    }

    private func handleScreenLock() {
        isScreenLocked = true
        batteryReadTimer?.invalidate()
        batteryReadTimer = nil
        LogManager.shared.log("Screen locked → battery timer paused")
    }

    private func handleScreenUnlock() {
        isScreenLocked = false
        startBatteryReadTimer()
        LogManager.shared.log("Screen unlocked → battery timer resumed")
    }

    /// Start (or restart) the 1-hour periodic battery read. Each tick checks
    /// the lock state and connection state before issuing the BLE command.
    private func startBatteryReadTimer() {
        batteryReadTimer?.invalidate()
        batteryReadTimer = Timer.scheduledTimer(withTimeInterval: batteryReadInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickActiveBatteryRead() }
        }
    }

    private func tickActiveBatteryRead() {
        guard !isScreenLocked else { return }
        guard isDeviceConnected else {
            LogManager.shared.log("Battery hourly read skipped: not connected")
            return
        }
        // Cached-only (no fresh ADC trigger on device) — fast, doesn't disturb FP.
        bleManager.getBatteryRaw(forceFresh: false) { [weak self] raw in
            Task { @MainActor in
                guard let self = self, let raw = raw else {
                    LogManager.shared.log("Battery hourly read failed")
                    return
                }
                self.batteryLevel = raw.pct
                self.batteryVoltageMv = raw.mv
                BatteryLogger.record(pct: raw.pct, mv: raw.mv)
                LogManager.shared.log("Battery hourly read: \(raw.pct)% / \(raw.mv) mV")
            }
        }
    }

    deinit {
        if let observer = fingerprintObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = gateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = screenLockObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        if let observer = screenUnlockObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        batteryReadTimer?.invalidate()
    }
}
