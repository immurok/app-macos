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
    /// 请求打开固件升级独立窗口（强制升级时自动弹出）
    static let openFirmwareUpdateWindow = Notification.Name("openFirmwareUpdateWindow")
    /// 检测到 App 新版本（object = 版本号 String），用于弹系统通知
    static let appUpdateAvailable = Notification.Name("appUpdateAvailable")
    /// 请求打开首次运行引导窗口
    static let openSetupWizard = Notification.Name("openSetupWizard")
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

    /* 配对引导框的状态。两步操作（按指纹 → 按设备按钮）光靠一行小字提示，
     * 用户读不出来那是两个动作。每一步的推进都由设备的通知驱动，不猜。 */
    enum PairingGuideStep: Int {
        case waitingFingerprint = 1   // 登记第二台主机才有这一步
        case waitingButton      = 2
        case computing          = 3   // ECDH，约 4 秒
    }
    @Published var pairingStep: PairingGuideStep = .waitingButton
    /// 本次配对是否需要指纹那一步（登记第二台主机 = true，首次配对 = false）
    @Published var pairingNeedsFingerprint = false

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

    /// App 自升级服务（不依赖设备，init 内自带启动延迟检查 + 定时复查）
    let appUpdate = AppUpdateService()

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
    private var appUpdateCancellable: AnyCancellable?
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
        appUpdateCancellable = appUpdate.objectWillChange.sink { [weak self] _ in
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
                // 通知指纹列表刷新（重连后重新拉取,否则停在断开前的旧列表）
                NotificationCenter.default.post(name: .deviceConnectionChanged, object: nil)

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
                self?.firmwareUpdate.enforceMinimumIfNeeded()  // firmwareVersion=nil → 清 mandatoryUpdate
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
                // 通知指纹列表刷新（断开后清空,不再停在旧列表）
                NotificationCenter.default.post(name: .deviceConnectionChanged, object: nil)
            }
        }

        bleManager.onFirmwareVersionRead = { [weak self] version in
            Task { @MainActor in
                self?.firmwareVersion = version
                self?.firmwareUpdate.resumePendingHopIfAny()
                self?.firmwareUpdate.enforceMinimumIfNeeded()  // <1.6.0 立刻强制升级
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

    /// 单字段密码输入弹窗（无二次确认）。取消或留空返回 nil。
    private func promptSinglePassword(title: String, message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "password.save".localized)
        alert.addButton(withTitle: "alert.cancel".localized)

        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        input.placeholderString = "password.placeholder".localized
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        guard alert.runModalOverSettings() == .alertFirstButtonReturn else { return nil }
        let pw = input.stringValue
        return pw.isEmpty ? nil : pw
    }

    /// 主动配置登录密码（单字段，无二次确认）。供配对后 / 状态页调用。
    func configurePassword() {
        // 未配对时不允许设置密码
        guard isDevicePaired else {
            showAlert(title: "alert.error".localized, message: "password.need.pair.first".localized)
            return
        }
        guard let password = promptSinglePassword(title: "password.title".localized,
                                                  message: "password.message".localized) else { return }
        // Save password to Keychain (local only, not sent via BLE)
        ImmurokSecurity.shared.savePassword(password)
        isPasswordConfigured = true
        hasLocalPairing = true
    }

    /// 开启解锁 / Passwords 自动填充前，按需索取系统登录密码。
    /// 已有密码则直接返回 true；弹窗取消返回 false（调用方不应开启该功能）。
    @discardableResult
    func setupLoginPasswordIfNeeded() -> Bool {
        if ImmurokSecurity.shared.hasPassword() { return true }
        guard isDevicePaired else {
            showAlert(title: "alert.error".localized, message: "password.need.pair.first".localized)
            return false
        }
        guard let password = promptSinglePassword(title: "password.title".localized,
                                                  message: "password.message".localized) else { return false }
        ImmurokSecurity.shared.savePassword(password)
        isPasswordConfigured = true
        hasLocalPairing = true
        return true
    }

    /// 开启 App Store 自动填充前，按需索取 Apple ID 密码。取消返回 false。
    @discardableResult
    func setupAppleIDPasswordIfNeeded() -> Bool {
        if ImmurokSecurity.shared.hasAppleIDPassword() { return true }
        guard let password = promptSinglePassword(title: "permission.appstore.configure".localized,
                                                  message: "permission.appstore.configure.hint".localized) else { return false }
        ImmurokSecurity.shared.saveAppleIDPassword(password)
        return true
    }

    /// 开启 1Password 解锁前，按需索取 1Password 的解锁密码（可与系统密码不同）。取消返回 false。
    @discardableResult
    func setupOnePasswordPasswordIfNeeded() -> Bool {
        if ImmurokSecurity.shared.hasOnePasswordPassword() { return true }
        guard let password = promptSinglePassword(title: "permission.onepassword.configure".localized,
                                                  message: "permission.onepassword.configure.hint".localized) else { return false }
        ImmurokSecurity.shared.saveOnePasswordPassword(password)
        return true
    }

    /// 解锁与 Passwords 均已关闭后调用：清除本地登录密码。
    func clearLoginPassword() {
        ImmurokSecurity.shared.clearPassword()
        isPasswordConfigured = false
    }

    /// 关闭 App Store 自动填充后调用：清除本地 Apple ID 密码。
    func clearAppleIDPassword() {
        ImmurokSecurity.shared.clearAppleIDPassword()
    }

    /// 关闭 1Password 解锁后调用：清除本地 1Password 解锁密码。
    func clearOnePasswordPassword() {
        ImmurokSecurity.shared.clearOnePasswordPassword()
    }

    /// 开启 Bitwarden 解锁前，按需索取 Bitwarden 的解锁密码（独立密码）。取消返回 false。
    @discardableResult
    func setupBitwardenPasswordIfNeeded() -> Bool {
        if ImmurokSecurity.shared.hasBitwardenPassword() { return true }
        guard let password = promptSinglePassword(title: "permission.bitwarden.configure".localized,
                                                  message: "permission.bitwarden.configure.hint".localized) else { return false }
        ImmurokSecurity.shared.saveBitwardenPassword(password)
        return true
    }

    /// 关闭 Bitwarden 解锁后调用：清除本地 Bitwarden 解锁密码。
    func clearBitwardenPassword() {
        ImmurokSecurity.shared.clearBitwardenPassword()
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

        /* 先问槽位：本槽是空的、别的槽有货 == 本机是第二台主机。
         *
         * 下面那道指纹位图预检是固件规则的本地镜像，为的是不用等一次往返
         * 就能给出提示。但固件那条规则有登记第二台主机的例外（指纹 + 按键
         * 两道门代替 factory reset），镜像必须跟着放行 —— 否则 app 自己就把
         * 流程堵死了，PAIR_INIT 根本发不出去，用户只看到「请先恢复出厂」。
         * 2026-08-03 实机踩到：设备日志里连一条 PAIR_INIT 都没有。
         *
         * 顺序不能反：槽位应答回来之前不能发 PAIR_INIT，否则后面的按键提示
         * 也会用错分支。 */
        bleManager.getSlotStatus { [weak self] slotBitmap, activeSlot in
            let mine = UInt8(1) << max(Int(activeSlot) - 1, 0)
            let asSecondHost = slotBitmap != 0 && (slotBitmap & mine) == 0

            // Pre-check device fingerprint bitmap. Firmware refuses PAIR_INIT
            // when bitmap != 0; we mirror the check here for an immediate UI
            // message rather than waiting for the device round-trip.
            self?.bleManager.getDeviceStatus { [weak self] bitmap, _, _, _ in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if bitmap != 0 && !asSecondHost {
                        self.showAlert(title: "alert.error".localized,
                                       message: "pairing.needs.reset".localized)
                        return
                    }
                    self.runPairing(asSecondHost: asSecondHost)
                }
            }
        }
    }

    /* asSecondHost：设备已被另一台电脑占了槽，本机走「登记第二台主机」
     * 分支 —— 设备会先要指纹、再要按键。两种情况的 WAIT_BUTTON 应答完全
     * 一样，提示文案只能靠调用方查过的槽位来选；选错了用户会一直按按钮，
     * 直到 30s 超时。 */
    private func runPairing(asSecondHost: Bool) {
        isPairing = true
        pairingPrompt = "pairing.in.progress".localized
        pairingNeedsFingerprint = asSecondHost
        pairingStep = asSecondHost ? .waitingFingerprint : .waitingButton

        // Wire up button-press status callbacks for UI feedback.
        bleManager.onPairWaitButton = { [weak self] in
            Task { @MainActor in
                self?.pairingPrompt = asSecondHost
                    ? "pairing.press.fp.button".localized
                    : "pairing.press.button".localized
            }
        }
        bleManager.onPairFingerprintConfirmed = { [weak self] in
            Task { @MainActor in
                self?.pairingStep = .waitingButton
                self?.pairingPrompt = "pairing.press.button".localized
            }
        }
        bleManager.onPairButtonConfirmed = { [weak self] in
            Task { @MainActor in
                self?.pairingStep = .computing
                self?.pairingPrompt = "pairing.in.progress".localized
            }
        }

        bleManager.startPairing { [weak self] failure in
            Task { @MainActor in
                guard let self = self else { return }
                self.isPairing = false
                self.pairingPrompt = nil
                self.bleManager.onPairWaitButton = nil
                self.bleManager.onPairFingerprintConfirmed = nil
                self.bleManager.onPairButtonConfirmed = nil

                if failure == nil {
                    ImmurokSecurity.shared.clearPassword()
                    self.isDevicePaired = true
                    self.isDeviceVerified = self.bleManager.isDeviceVerified
                    self.isPasswordConfigured = false
                    self.hasLocalPairing = true
                    // 配对成功后刷新设备状态(槽 bitmap/paired)+ 指纹列表 ——
                    // 否则页面还停在配对前的空指纹列表 / 旧槽状态。
                    self.refreshDeviceStatus()
                    self.refreshFingerprintCount()
                    self.showAlert(title: "pairing.success".localized, message: "pairing.success.set.password".localized)
                    self.configurePassword()
                    return
                }

                let message: String
                switch failure! {
                case .needsReset:       message = "pairing.needs.reset".localized
                case .buttonTimeout:    message = "pairing.timeout".localized
                case .buttonCancelled:  message = "pairing.cancelled".localized
                case .linkParams:       message = "pairing.link.params".localized
                case .generic:          message = "pairing.failed".localized
                }
                self.showAlert(title: "alert.error".localized, message: message)
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
        /* 清掉最后一个被占用的槽是个单向门：设备上没有任何主机、指纹却还在，
         * 此时 PAIR_INIT 的守卫（有指纹 && 没有别的槽有货 → NEEDS_RESET）会
         * 要求 factory reset，连同全部 SSH 私钥一起毁掉。必须在确认框里说清楚
         * （spec §8.3）。设备没连上时按最坏情况提示。 */
        bleManager.getSlotStatus { [weak self] bitmap, active in
            let mine = UInt8(1) << max(Int(active) - 1, 0)
            let isLastOccupiedSlot = (bitmap & ~mine) == 0
            Task { @MainActor in
                self?.confirmUnpair(isLastSlot: isLastOccupiedSlot)
            }
        }
    }

    private func confirmUnpair(isLastSlot: Bool) {
        let alert = NSAlert()
        alert.messageText = "unpair.title".localized
        alert.informativeText = isLastSlot && fingerprintCount > 0
            ? "unpair.message".localized + "\n\n" + "unpair.message.lastslot".localized
            : "unpair.message".localized
        alert.alertStyle = .warning
        alert.addButton(withTitle: "alert.cancel".localized)
        alert.addButton(withTitle: "unpair.confirm".localized)

        let response = alert.runModalOverSettings()
        if response == .alertSecondButtonReturn {
            doUnpair()
        }
    }

    private func doUnpair() {
        /* 必须先让设备清掉这个槽，再清本地。
         *
         * 曾经这里只有 clearLocalPairing() —— 设备那边槽位照旧占着，于是
         * 重新配对走的是「重新配对一个已占用的槽」，被守卫要求先 factory
         * reset，用户被卡死在「解绑了却配不上」。SLOT_CLEAR 命令和
         * clearOwnSlot() 当时都已经写好，只是没人调用。2026-08-03 实机踩到。
         *
         * 设备侧成功后会重启，所以本地清理不等它的连接恢复。设备没连上时
         * 仍允许只清本地 —— 否则设备丢了就永远解绑不了。 */
        guard bleManager.deviceState.isConnected else {
            clearLocalPairing()
            showAlert(title: "unpair.done".localized,
                      message: "unpair.done.local.only".localized)
            return
        }
        bleManager.clearOwnSlot { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }
                switch result {
                case .rejected:
                    /* 设备连着却明确回 NOT_PAIRED —— active 槽不是本机这一个
                     * （停在另一台主机或空槽），SLOT_CLEAR 被未配对白名单按
                     * active_slot_paired() 挡回。**不能**清本地假装成功：本机
                     * 配对还在、设备那边也没动。提示用户先切回本机。见
                     * keng_unpair_empty_slot_false_success。 */
                    self.showAlert(title: "unpair.failed".localized,
                                   message: "unpair.failed.wrong_slot".localized)
                case .cleared:
                    /* 设备清掉本槽并重启换地址（断开/无响应也算成功，设备就是
                     * 要重启）。清本地 + 引导忽略旧设备。 */
                    self.clearLocalPairing()
                    self.showAlert(title: "unpair.done".localized,
                                   message: "unpair.done.message".localized + "\n\n"
                                            + "unpair.done.forget.hint".localized)
                }
            }
        }
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
        // 指纹名字存在 UserDefaults、不随配对数据走，必须显式清除，
        // 否则重新绑定后旧名字还在。
        FingerprintViewModel.clearAllNames()
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
