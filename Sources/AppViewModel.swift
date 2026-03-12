import SwiftUI
import Combine

extension Notification.Name {
    static let sshKeyCacheSynced = Notification.Name("sshKeyCacheSynced")
    static let cliToggleChanged = Notification.Name("cliToggleChanged")
    static let quickFillToggleChanged = Notification.Name("quickFillToggleChanged")
    static let quickFillHotkeyChanged = Notification.Name("quickFillHotkeyChanged")
}

@MainActor
class AppViewModel: ObservableObject {
    @Published var isDeviceConnected = false
    @Published var deviceName: String?
    @Published var fingerprintCount = 0
    @Published var isDevicePaired = false  // Device-side pairing status (ECDH)
    @Published var isPasswordConfigured = false  // Keychain has password
    var gateController = FingerprintGateController()
    @Published var isPairing = false  // ECDH pairing in progress

    // Firmware version
    @Published var firmwareVersion: String?

    // Battery level (0-100%, nil = unknown)
    @Published var batteryLevel: Int?

    // Bluetooth permission state
    @Published var bluetoothStatus: BluetoothAuthStatus = .notDetermined

    private let bleManager = BLEManager.shared

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
    private var pendingGatedOperation = false

    init() {
        setupBLECallbacks()
        updateStatus()
        updateBluetoothStatus()

        gateCancellable = gateController.objectWillChange.sink { [weak self] _ in
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
                completion?()
            }
        }
    }

    // MARK: - BLE Callbacks

    private func setupBLECallbacks() {
        bleManager.onDeviceConnected = { [weak self] name in
            Task { @MainActor in
                NSLog("Device connected: %@", name)
                LogManager.shared.log("设备已连接: \(name)")
                self?.isDeviceConnected = true
                self?.deviceName = name

                // Invalidate FingerprintView cache on reconnect
                FingerprintViewModel.invalidateCache()

                // Serialize BLE commands to avoid responseCallback race:
                // GET_STATUS first, then SSH key sync
                self?.refreshDeviceStatus {
                    SSHKeyCache.shared.sync {
                        NSLog("SSH key cache synced")
                        // Populate KeyNameCache for SSH from already-synced data (avoid duplicate BLE reads)
                        KeyNameCache.shared.replaceCategory(.ssh, with: SSHKeyCache.shared.entries.map {
                            KeyNameCache.Entry(index: $0.index, name: $0.name, service: "", category: .ssh)
                        })
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
                LogManager.shared.log("设备已断开")
                self?.isDeviceConnected = false
                self?.deviceName = nil
                self?.firmwareVersion = nil
                self?.batteryLevel = nil
                self?.fingerprintCount = 0
                self?.isDevicePaired = false
                self?.pendingGatedOperation = false
                self?.gateController.reset()
                KeyNameCache.shared.clear()

                FingerprintViewModel.cachedBitmap = 0
                FingerprintViewModel.isCacheValid = false
            }
        }

        bleManager.onFirmwareVersionRead = { [weak self] version in
            Task { @MainActor in
                self?.firmwareVersion = version
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

        let response = alert.runModal()
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
            showAlert(title: "password.saved".localized, message: "password.saved.message".localized)
        }
    }

    // MARK: - ECDH Pairing

    func startPairing() {
        guard isDeviceConnected else {
            showAlert(title: "alert.error".localized, message: "test.connect.first".localized)
            return
        }

        // 重新配对确认（密码会被清除）
        if ImmurokSecurity.shared.isPaired || ImmurokSecurity.shared.hasPassword() {
            let confirm = NSAlert()
            confirm.messageText = "pairing.reconfirm.title".localized
            confirm.informativeText = "pairing.reconfirm.message".localized
            confirm.alertStyle = .warning
            confirm.addButton(withTitle: "alert.continue".localized)
            confirm.addButton(withTitle: "alert.cancel".localized)
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
        }

        isPairing = true
        bleManager.startPairing { [weak self] success in
            Task { @MainActor in
                self?.isPairing = false
                if success {
                    // 清除旧密码
                    ImmurokSecurity.shared.clearPassword()
                    self?.isDevicePaired = true
                    self?.isPasswordConfigured = false
                    // 引导设置密码
                    self?.showAlert(title: "pairing.success".localized, message: "pairing.success.set.password".localized)
                    self?.configurePassword()
                } else {
                    self?.showAlert(title: "alert.error".localized, message: "pairing.failed".localized)
                }
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: - Factory Reset

    func factoryReset() {
        let alert = NSAlert()
        alert.messageText = "reset.title".localized
        alert.informativeText = "reset.message".localized
        alert.alertStyle = .warning
        alert.addButton(withTitle: "alert.cancel".localized)
        alert.addButton(withTitle: "reset.confirm".localized)

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            doFactoryReset()
        }
    }

    private func doFactoryReset() {
        guard isDeviceConnected else {
            showAlert(title: "alert.error".localized, message: "test.connect.first".localized)
            return
        }

        pendingGatedOperation = true
        gateController.title = "reset.title".localized
        bleManager.factoryReset { [weak self] success in
            Task { @MainActor in
                guard let self = self else { return }
                self.pendingGatedOperation = false
                if self.gateController.isPresented {
                    success ? self.gateController.reportSuccess() : self.gateController.reportFailed()
                }
                if success {
                    self.fingerprintCount = 0
                    self.isDevicePaired = false
                    self.isPasswordConfigured = false
                    ImmurokSecurity.shared.clearPairingData()
                    ImmurokSecurity.shared.clearPassword()
                    FingerprintViewModel.cachedBitmap = 0
                    FingerprintViewModel.isCacheValid = true
                    NotificationCenter.default.post(name: .fingerprintCacheUpdated, object: nil)
                    self.showAlert(title: "reset.done".localized, message: "reset.done.message".localized)
                } else if !self.gateController.isPresented {
                    self.showAlert(title: "alert.error".localized, message: "reset.failed".localized)
                }
            }
        }
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

    deinit {
        if let observer = fingerprintObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = gateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
