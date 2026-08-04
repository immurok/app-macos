/*
 * BLEManager.swift - BLE communication with immurok device
 *
 * Connects to CH592F via custom GATT service for authentication
 */

import AppKit
import CoreBluetooth
import Foundation

// MARK: - BLE UUIDs

// 128-bit random v4 UUIDs — original 12340010-...-00805f9b34fb pattern
// piggybacked on the SIG Bluetooth Base UUID, which is reserved for
// SIG-assigned values; non-conformant for a vendor service. Replaced as
// part of the pre-mass-production cleanup before SIG QDID issuance.
let IMMUROK_SERVICE_UUID = CBUUID(string: "45529919-7668-48f9-b9fe-e4eabe6595d9")
let IMMUROK_CMD_CHAR_UUID = CBUUID(string: "8a537e1f-3992-4b2c-8b77-8d4e778186e1")
let IMMUROK_RSP_CHAR_UUID = CBUUID(string: "76a1660d-8cf6-44d1-b3fc-70486028e289")

// Device Information Service (standard BLE 0x180A)
let DEVICE_INFO_SERVICE_UUID = CBUUID(string: "180A")
let FIRMWARE_REV_CHAR_UUID = CBUUID(string: "2A26")

// Battery Service (standard BLE 0x180F) — subscribed for push-driven
// battery level updates. Firmware already runs Batt_MeasLevel every 5 min
// regardless of subscribers (macOS HID UI subscribes by default), so this
// adds zero device-side power cost; we just receive the same notify the
// system menu bar receives.
let BATTERY_SERVICE_UUID = CBUUID(string: "180F")
let BATTERY_LEVEL_CHAR_UUID = CBUUID(string: "2A19")

// OTA Service — moved off 0xFEE0/FEE1 (SIG Member Service UUID range
// already allocated to other companies — Anhui Huami / Xiaomi cluster)
// to 128-bit random v4 UUIDs to avoid both the cross-vendor scan
// collision and the technical allocation issue.
let OTA_SERVICE_UUID = CBUUID(string: "d29005de-1391-4a54-8168-bf4e3c080430")
let OTA_CHAR_UUID = CBUUID(string: "c75f4c30-9a2d-4445-92e0-0e034c53d092")

// MARK: - Commands

enum ImmurokCommand: UInt8 {
    case getStatus = 0x01
    case getBattRaw = 0x02
    case enrollStart = 0x10
    case enrollCancel = 0x11
    case deleteFP = 0x12
    case fpList = 0x13
    case fpMatchAck = 0x22
    case pairInit = 0x30
    case pairConfirm = 0x31
    case pairStatus = 0x32
    case authRequest = 0x33
    // Notification cmd from device:
    //   [0x34, 0x00=timeout, 0x01=按键已按下, 0x02=长按取消, 0x03=指纹已通过]
    case pairButton = 0x34
    case gateCancel = 0x37
    case challenge = 0x38
    // 双主机槽位（spec 2026-08-03-dual-host-design.md）
    case slotStatus = 0x39
    case slotClear = 0x3C
    case keyCount = 0x60
    case keyRead = 0x61
    case keyWrite = 0x62
    case keyDelete = 0x63
    case keyCommit = 0x64
    case keySign = 0x65
    case keyGetPub = 0x66
    case keyGenerate = 0x67
    case keyResult = 0x68
    case keyOTPGet = 0x69
}

// Key categories matching firmware KEYSTORE_CAT_*
enum KeystoreCategory: UInt8 {
    case ssh = 0
    case otp = 1
    case api = 2

    var entrySize: Int {
        switch self {
        case .ssh: return 112
        case .otp: return 92
        case .api: return 160
        }
    }

    var maxEntries: Int {
        switch self {
        case .ssh: return 32
        case .otp: return 128
        case .api: return 50
        }
    }
}

// MARK: - Status

enum ImmurokStatus: UInt8 {
    case ok = 0x00
    case errTimeout = 0x06
    case errFpNotMatch = 0x07
    case waitFingerprint = 0x11
    case errWaitButton = 0xF0     // PAIR_INIT: waiting for physical button confirm
    case errNeedsReset = 0xF1     // PAIR_INIT: device still has fingerprints
    case errBusy = 0xFD
    case errInvalidParam = 0xFE
    case errUnknown = 0xFF
}

enum PairFailureReason: Error {
    case generic
    case needsReset       // Device still has fingerprints; user must factory reset first
    case buttonTimeout    // 30s elapsed without button press
    case buttonCancelled  // User long-pressed to cancel
    case linkParams       // Device refused ECDH: BLE connection params inadequate (0xE1)
    // 双主机槽 2 登记专有
}

// Enrollment status notifications (from device)
// Must match firmware fingerprint.h fp_enroll_event_t
// Single-slot enrollment: 6 captures (mode-1 broad coverage) → merge → store
enum EnrollEvent: UInt8 {
    case waiting = 0x00
    case captured = 0x01
    case processing = 0x02
    case liftFinger = 0x03
    case complete = 0x04
    case overlap = 0x06   // (mode 1) too much overlap — shift finger, re-press
    case failed = 0xFF
}

// MARK: - Bluetooth Authorization Status

enum BluetoothAuthStatus: Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unsupported
    case poweredOff
}

// MARK: - Device State

enum BLEDeviceState: Equatable {
    case disconnected
    case connecting
    case connected(name: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

// MARK: - BLE Manager

class BLEManager: NSObject {

    static let shared = BLEManager()

    // MARK: - State

    private(set) var deviceState: BLEDeviceState = .disconnected
    private(set) var bluetoothAuthStatus: BluetoothAuthStatus = .notDetermined
    private(set) var firmwareVersion: String?
    private(set) var isDeviceVerified: Bool = false

    // MARK: - Callbacks

    var onDeviceConnected: ((String) -> Void)?
    var onDeviceDisconnected: (() -> Void)?
    var onUnlockResult: ((Bool) -> Void)?
    var onFingerprintMatch: ((UInt16) -> Void)?
    /// Long-press lock-screen request from device (held >= 2s on touch sensor).
    /// Fires regardless of FP match outcome — AppDelegate gates on screen state.
    var onLockRequest: (() -> Void)?
    /// PAIR_INIT accepted: user must press the device button within 30s to confirm.
    var onPairWaitButton: (() -> Void)?
    /// 登记第二台主机时，设备确认指纹已通过、开始等按键。引导框据此点亮
    /// 第一步的勾 —— 没有这条通知就只能猜，猜出来的勾是假的。
    var onPairFingerprintConfirmed: (() -> Void)?
    /// User pressed the button — ECDH key exchange is now running on the device.
    var onPairButtonConfirmed: (() -> Void)?
    var onPairingCompleted: ((Bool) -> Void)?
    var onEnrollStatus: ((EnrollEvent, Int, Int) -> Void)?
    var onBluetoothStatusChanged: ((BluetoothAuthStatus) -> Void)?
    var onFirmwareVersionRead: ((String) -> Void)?
    /// Fired on every push-notify from the Battery Service (0x180F → 0x2A19).
    /// The firmware sends this only when its computed battLevel actually
    /// changes (every ~5 min on the periodic ADC sample), so this is a low-
    /// frequency, zero-poll source of fresh battery percentage.
    var onBatteryLevelNotified: ((Int) -> Void)?
    /// Called when fingerprint doesn't match during FP gate or AUTH — parameter is remaining attempts
    var onFingerprintAttemptFailed: ((Int) -> Void)?
    var onFingerprintGateApproved: (() -> Void)?
    var onFingerprintGateRequired: (() -> Void)?
    /// Posted when a command enters FP gate (WAIT_FP). UI should prompt "请验证指纹".
    static let fingerprintGateRequiredNotification = Notification.Name("BLEManagerFingerprintGateRequired")

    // MARK: - Private Properties

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cmdCharacteristic: CBCharacteristic?
    private var rspCharacteristic: CBCharacteristic?
    private var otaCharacteristic: CBCharacteristic?

    private var responseCallback: ((Data?) -> Void)?
    private var commandGeneration: UInt = 0  // Increments per sendCommand, used to scope timeouts
    private var pendingGateCompletion: ((Bool) -> Void)?  // Waiting for FP gate result
    private var pendingGateDataCompletion: ((Data?) -> Void)?  // Waiting for FP gate result with data (OTP)
    private var gateGeneration: UInt = 0  // Increments per startGateTimeout, scopes gate timeouts

    // Pair-button state machine. Set after PAIR_INIT returns WAIT_BUTTON
    // and the device is waiting for the user to physically press its button.
    // Two later inputs end this state:
    //   1) device sends 0x34 (timeout/cancel) → invoke completion(.failed)
    //   2) device sends 0x30 + 33B pubkey      → continue ECDH (PAIR_CONFIRM)
    private var pendingPairButton: ((Result<Data, PairFailureReason>) -> Void)?
    private var pendingPairButtonGeneration: UInt = 0
    private var fpFailureCount = 0  // FP_NOT_MATCH counter, max 2 then deny
    private var otaReadCallback: ((Data?) -> Void)?
    private var otaWriteReadyCallback: (() -> Void)?
    private var reconnectTimer: DispatchSourceTimer?
    private var sleepActivity: NSObjectProtocol?
    private var displaySleeping = false
    private var connectingStartTime: Date?  // Tracks when .connecting state began
    private static let connectingTimeout: TimeInterval = 10  // Max time in .connecting before reset

    private let queue = DispatchQueue(label: "com.immurok.ble", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()

    // Command queue — serializes BLE command/response pairs
    private var commandInFlight = false
    // Opcode of the in-flight command. Used by the 0x11 enrollment-status
    // handler to decide whether to hijack `responseCallback` — only the
    // very first status frame after ENROLL_START is meant to complete the
    // command's pending callback (device doesn't send a separate OK ack
    // for ENROLL_START). For ANY other in-flight command, the device's
    // enrollment keep-alive [0x11, WAITING, ...] frames must NOT touch
    // the callback; the wrong command would otherwise be "completed" with
    // bogus data and report success.
    private var currentCommand: ImmurokCommand?
    private var commandQueue: [(command: ImmurokCommand, payload: [UInt8], timeout: TimeInterval, completion: (Data?) -> Void)] = []

    private var isOnBLEQueue: Bool {
        DispatchQueue.getSpecific(key: queueKey) == true
    }

    // MARK: - Initialization

    override init() {
        super.init()
        queue.setSpecific(key: queueKey, value: true)
        centralManager = CBCentralManager(delegate: self, queue: queue)
        setupDisplayNotifications()
    }

    private func setupDisplayNotifications() {
        DispatchQueue.main.async {
            let nc = NSWorkspace.shared.notificationCenter

            // Screen sleep/wake controls reconnect behavior
            nc.addObserver(self, selector: #selector(self.onScreenDidSleep),
                           name: NSWorkspace.screensDidSleepNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.onScreenDidWake),
                           name: NSWorkspace.screensDidWakeNotification, object: nil)

        }
    }

    @objc private func onScreenDidSleep() {
        NSLog("BLEManager: Screen did sleep")
        Task { @MainActor in LogManager.shared.log("Screen sleep") }
        displaySleeping = true
        stopReconnectTimer()
        // Prevent system from entering deep power saving that kills BLE connection.
        // Without this, macOS drops BLE after ~1 min of sleep, device re-advertises,
        // macOS reconnects HID keyboard → screen wakes → sleep → disconnect → repeat.
        if sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled,
                reason: "Keep BLE connection alive during screen sleep")
        }
    }

    @objc private func onScreenDidWake() {
        NSLog("BLEManager: Screen did wake (deviceState.isConnected=%d, verified=%d)",
              deviceState.isConnected ? 1 : 0, isDeviceVerified ? 1 : 0)
        Task { @MainActor in LogManager.shared.log("Screen wake") }
        displaySleeping = false
        if let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
        queue.async { [weak self] in
            guard let self = self else { return }
            if !self.deviceState.isConnected {
                self.deviceState = .disconnected
                self.startReconnectTimer()
            } else if !self.isDeviceVerified {
                // Connected but not verified — reconnected during sleep without
                // completing challenge. Re-run verification now.
                let name = self.peripheral?.name ?? "immurok"
                self.performChallengeVerification(name: name)
            }
        }
    }

    // MARK: - Public Methods

    func connect() {
        queue.async { [weak self] in
            self?.doConnect()
        }
    }

    private func doConnect() {
        guard centralManager.state == .poweredOn else {
            NSLog("BLEManager: Bluetooth not ready (state: %d)", centralManager.state.rawValue)
            return
        }

        // Already connected, no need to reconnect
        if deviceState.isConnected {
            stopReconnectTimer()
            return
        }

        // Reset stale .connecting state — prevents deadlock when scan/connect silently fails
        if deviceState == .connecting {
            if let start = connectingStartTime,
               Date().timeIntervalSince(start) < Self.connectingTimeout {
                return  // Still within timeout, let current attempt finish
            }
            NSLog("BLEManager: Connecting timed out, resetting")
            centralManager.stopScan()
            deviceState = .disconnected
        }

        deviceState = .connecting
        connectingStartTime = Date()
        NSLog("BLEManager: Looking for immurok device...")
        Task { @MainActor in LogManager.shared.log("BLE: searching for connected devices...") }

        // Strategy 1: Check if our known peripheral is already connected (system auto-reconnect)
        if let p = peripheral, p.state == .connected {
            NSLog("BLEManager: Known peripheral already connected, re-discovering services")
            p.delegate = self
            p.discoverServices([IMMUROK_SERVICE_UUID, OTA_SERVICE_UUID, DEVICE_INFO_SERVICE_UUID, BATTERY_SERVICE_UUID])
            return
        }

        // Strategy 2: Find connected devices by immurok service UUID
        let connectedPeripherals = centralManager.retrieveConnectedPeripherals(
            withServices: [IMMUROK_SERVICE_UUID]
        )
        for peripheral in connectedPeripherals {
            if peripheral.name?.lowercased().contains("immurok") == true {
                NSLog("BLEManager: Found connected device: %@", peripheral.name ?? "unknown")
                self.peripheral = peripheral
                peripheral.delegate = self
                centralManager.connect(peripheral, options: nil)
                return
            }
        }

        // No connected device found — wait for system auto-reconnect (HID keyboard)
        // App should never initiate scan/connect; the device is paired as HID keyboard
        // and macOS will auto-connect it. Reconnect timer will retry doConnect() periodically.
        NSLog("BLEManager: No connected device found, waiting for system auto-reconnect...")
        deviceState = .disconnected
        connectingStartTime = nil
    }

    func disconnect() {
        if let peripheral = peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    /// Request unlock via AUTH_REQUEST - device waits for fingerprint
    /// Cancel a pending fingerprint-gated command on the device.
    /// 仅发命令, 不释放队列 hold — 仅用于队列没被 hold 的场景.
    /// 大部分 sheet cancel 路径应该用 cancelGateAndRelease().
    func cancelGate() {
        guard deviceState.isConnected else { return }
        NSLog("BLEManager: Sending GATE_CANCEL")
        sendCommand(.gateCancel) { _ in }
    }

    /// Cancel + release hold + clear pending gate completion. 用于 sheet
    /// 主动取消路径 (controller.cancel / sheet.onDisappear).
    /// 根因: AUTH_REQUEST / ENROLL_START / DELETE_FP / KEY_SIGN 等返回
    /// WAIT_FP 后 commandInFlight 被故意保持 true (handleData line 2271)
    /// 锁住后续命令队列, 让 gate notification 不被错路由. cancelGate()
    /// 调用 sendCommand 进队但不会 dequeue, 固件永远收不到 GATE_CANCEL.
    /// 必须释放 hold 才能让 gateCancel 命令真正发出.
    func cancelGateAndRelease() {
        guard deviceState.isConnected else { return }
        NSLog("BLEManager: cancelGateAndRelease — GATE_CANCEL + release hold")
        sendCommand(.gateCancel) { _ in }
        queue.async { [weak self] in
            guard let self = self else { return }
            // 清 pending gate completion 防止 25s 后超时回调误触发 showAlert
            // (用户已主动 cancel, 不应再弹任何错误对话框).
            let gateCb = self.pendingGateCompletion
            let gateDataCb = self.pendingGateDataCompletion
            self.pendingGateCompletion = nil
            self.pendingGateDataCompletion = nil
            self.releaseAuthHold()  // commandInFlight=false, drain queue
            gateCb?(false)
            gateDataCb?(nil)
        }
    }

    /// User-initiated cancel of an in-flight `requestUnlock`. Tells the device
    /// to stop blinking + clear its pending gate, then immediately resolves
    /// the local completion with false so callers (PAM, etc.) can return DENY
    /// without waiting for the 30s timeout.
    func cancelUnlock() {
        NSLog("BLEManager: Cancelling unlock request (user reject)")
        cancelGate()
        queue.async { [weak self] in
            guard let self = self else { return }
            self.fingerprintTimeoutWorkItem?.cancel()
            self.fingerprintTimeoutWorkItem = nil
            // fingerprintResultCompletion is the wrapper that signals the
            // PAM socket semaphore. Calling with false drives the response
            // path to "DENY".
            let cb = self.fingerprintResultCompletion
            self.fingerprintResultCompletion = nil
            cb?(false)
            // Release the AUTH_REQUEST queue hold so the gateCancel command
            // queued by cancelGate() above actually drains and reaches the
            // device — otherwise the device keeps blinking / waiting for
            // fingerprint and the user sees no effect from clicking cancel.
            self.releaseAuthHold()
        }
    }

    func requestUnlock(timeout: TimeInterval = 30.0, completion: @escaping (Bool) -> Void) {
        guard deviceState.isConnected else {
            NSLog("BLEManager: Not connected")
            completion(false)
            return
        }

        NSLog("BLEManager: Requesting unlock (AUTH_REQUEST)...")
        // QuickFill / agent-overlay diagnostic: capture wall time on the call
        // path so we can pin where the user-visible "wait for green LED"
        // delay sits — queue (commandInFlight=true from a prior op?), BLE
        // slave-latency wakeup (~1.26s worst case with latency=20, interval
        // 30-60ms), or device-side processing.
        let authReqStart = Date()
        Task { @MainActor in LogManager.shared.log("AUTH_REQUEST start (t0)") }

        sendCommand(.authRequest) { [weak self] response in
            guard let self = self else {
                completion(false)
                return
            }
            let dt = Date().timeIntervalSince(authReqStart) * 1000
            guard let response = response, response.count >= 1 else {
                NSLog("BLEManager: No AUTH_REQUEST response (%.0f ms)", dt)
                Task { @MainActor in LogManager.shared.log("AUTH_REQUEST no response (\(Int(dt)) ms)") }
                completion(false)
                return
            }

            let status = response[0]
            NSLog("BLEManager: AUTH_REQUEST resp 0x%02x in %.0f ms", status, dt)
            Task { @MainActor in LogManager.shared.log("AUTH_REQUEST resp 0x\(String(format: "%02x", status)) (\(Int(dt)) ms — green LED visible to user)") }
            if status == ImmurokStatus.waitFingerprint.rawValue {
                self.waitForFingerprintResult(timeout: timeout, completion: completion)
            } else {
                completion(false)
            }
        }
    }

    private var fingerprintResultCompletion: ((Bool) -> Void)?
    private var fingerprintTimeoutWorkItem: DispatchWorkItem?

    private func waitForFingerprintResult(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        fpFailureCount = 0
        fingerprintTimeoutWorkItem?.cancel()
        fingerprintResultCompletion = nil

        fingerprintResultCompletion = { [weak self] result in
            self?.fingerprintTimeoutWorkItem?.cancel()
            self?.fingerprintTimeoutWorkItem = nil
            self?.fingerprintResultCompletion = nil
            completion(result)
        }

        let previousCallback = onUnlockResult
        onUnlockResult = { [weak self] result in
            NSLog("BLEManager: Fingerprint auth result received: %@", result ? "success" : "failed")
            self?.fingerprintResultCompletion?(result)
            self?.onUnlockResult = previousCallback
        }

        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            NSLog("BLEManager: Fingerprint timeout")
            // Wrapped completion (line 418-422) clears fingerprintResultCompletion
            // itself when fired; just release the BLE-queue hold here.
            let hadHold = self.fingerprintResultCompletion != nil
            self.fingerprintResultCompletion?(false)
            self.onUnlockResult = previousCallback
            if hadHold { self.releaseAuthHold() }
        }
        fingerprintTimeoutWorkItem = timeoutItem
        queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
    }

    /// Request OTP computation on device (sends timestamp, device does HMAC-SHA1 + TOTP after FP)
    func requestOTP(idx: UInt8, completion: @escaping (String?) -> Void) {
        guard deviceState.isConnected else {
            completion(nil)
            return
        }

        let ts = UInt32(Date().timeIntervalSince1970)
        let payload: [UInt8] = [
            idx,
            UInt8(ts & 0xFF),
            UInt8((ts >> 8) & 0xFF),
            UInt8((ts >> 16) & 0xFF),
            UInt8((ts >> 24) & 0xFF)
        ]

        sendCommand(.keyOTPGet, payload: payload) { [weak self] response in
            guard let self = self, let response = response, response.count >= 1 else {
                completion(nil)
                return
            }

            let status = response[0]
            if status == ImmurokStatus.ok.rawValue && response.count >= 7 {
                // Direct result (no fingerprints enrolled)
                completion(String(data: response[1..<7], encoding: .ascii))
            } else if status == ImmurokStatus.waitFingerprint.rawValue {
                // Wait for FP gate data result
                self.pendingGateDataCompletion = { data in
                    guard let data = data, data.count >= 7,
                          data[0] == ImmurokStatus.ok.rawValue else {
                        completion(nil)
                        return
                    }
                    completion(String(data: data[1..<7], encoding: .ascii))
                }
                self.startGateTimeout()
            } else {
                completion(nil)
            }
        }
    }

    /// Get device status (simple OK check)
    func getStatus(completion: @escaping (Bool) -> Void) {
        guard deviceState.isConnected else {
            completion(false)
            return
        }

        sendCommand(.getStatus) { response in
            guard let response = response, response.count >= 1 else {
                NSLog("BLEManager: Invalid status response")
                completion(false)
                return
            }

            if response[0] == ImmurokStatus.ok.rawValue {
                NSLog("BLEManager: Status OK")
                completion(true)
            } else {
                completion(false)
            }
        }
    }

    /// Start fingerprint enrollment
    func startEnrollment(slotId: UInt8, completion: @escaping (Bool) -> Void) {
        guard deviceState.isConnected else {
            NSLog("BLEManager: Not connected")
            completion(false)
            return
        }

        NSLog("BLEManager: Starting enrollment for slot %d", slotId)
        sendCommand(.enrollStart, payload: [slotId]) { [weak self] response in
            guard let response = response, response.count >= 1 else {
                NSLog("BLEManager: No enrollment response")
                completion(false)
                return
            }

            let status = response[0]
            if status == ImmurokStatus.ok.rawValue {
                NSLog("BLEManager: Enrollment started")
                completion(true)
            } else if status == ImmurokStatus.waitFingerprint.rawValue {
                NSLog("BLEManager: Enrollment waiting for FP gate")
                self?.pendingGateCompletion = completion
                self?.startGateTimeout()
                DispatchQueue.main.async { NotificationCenter.default.post(name: BLEManager.fingerprintGateRequiredNotification, object: nil) }
            } else {
                NSLog("BLEManager: Enrollment failed: 0x%02x", status)
                completion(false)
            }
        }
    }

    /// Cancel active enrollment on device
    func cancelEnrollment(completion: ((Bool) -> Void)? = nil) {
        guard deviceState.isConnected else {
            completion?(false)
            return
        }

        NSLog("BLEManager: Cancelling enrollment")
        sendCommand(.enrollCancel) { response in
            let ok = response != nil && response!.count >= 1 && response![0] == ImmurokStatus.ok.rawValue
            NSLog("BLEManager: Cancel enrollment result: %@", ok ? "OK" : "failed")
            completion?(ok)
        }
    }

    /// Delete fingerprint
    func deleteFingerprint(slotId: UInt8, completion: @escaping (Bool) -> Void) {
        guard deviceState.isConnected else {
            NSLog("BLEManager: Not connected")
            completion(false)
            return
        }

        NSLog("BLEManager: Deleting fingerprint slot %d", slotId)
        sendCommand(.deleteFP, payload: [slotId]) { [weak self] response in
            guard let response = response, response.count >= 1 else {
                NSLog("BLEManager: No delete response")
                completion(false)
                return
            }

            let status = response[0]
            if status == ImmurokStatus.ok.rawValue {
                NSLog("BLEManager: Delete succeeded")
                completion(true)
            } else if status == ImmurokStatus.waitFingerprint.rawValue {
                NSLog("BLEManager: Delete waiting for FP gate")
                self?.pendingGateCompletion = completion
                self?.startGateTimeout()
                DispatchQueue.main.async { NotificationCenter.default.post(name: BLEManager.fingerprintGateRequiredNotification, object: nil) }
            } else {
                NSLog("BLEManager: Delete failed: 0x%02x", status)
                completion(false)
            }
        }
    }

    /// Start ECDH pairing with device. The device requires the user to
    /// physically press its button to confirm; UI should listen to
    /// onPairWaitButton / onPairButtonConfirmed for status updates.
    /// 槽 2 登记用的 PIN。非 nil 时，PAIR_CONFIRM 之后追加 SLOT_PAIR + proof，
    /// 且只有设备那边 proof + 指纹都过了才算配对成功 —— 本机的 shared_key
    /// 也要等到那时才写进 Keychain，否则会出现「主机 2 以为配好了、设备
    /// 其实没写槽 2」的状态分裂。
    func startPairing(completion: @escaping (PairFailureReason?) -> Void) {
        startPairingAttempt(retries: 3, completion: completion)
    }

    private func startPairingAttempt(retries: Int, completion: @escaping (PairFailureReason?) -> Void) {
        guard deviceState.isConnected else {
            completion(.generic)
            return
        }

        NSLog("BLEManager: Starting ECDH pairing (retries left: %d)...", retries)

        // PAIR_INIT now returns WAIT_BUTTON immediately; the actual 33B
        // device pubkey arrives later as a notification after the user
        // presses the device button. Use a short timeout for the WAIT_BUTTON
        // ack (5s) — the long wait is handled by pendingPairButton.
        sendCommand(.pairInit, timeout: 5.0) { [weak self] response in
            guard let self = self, let response = response, response.count >= 1 else {
                NSLog("BLEManager: PAIR_INIT no response")
                completion(.generic)
                return
            }

            // 0xE1 = BLE connection params inadequate for ECC — auto-retry
            if response[0] == 0xE1 {
                self.retryAfterLinkParams(retries: retries, completion: completion)
                return
            }

            guard response.count >= 2, response[0] == ImmurokCommand.pairInit.rawValue else {
                NSLog("BLEManager: PAIR_INIT unexpected response: 0x%02x", response[0])
                completion(.generic)
                return
            }

            // Two-byte error / status response
            if response.count == 2 {
                let code = response[1]
                if code == ImmurokStatus.errNeedsReset.rawValue {
                    NSLog("BLEManager: PAIR_INIT rejected: device still has fingerprints")
                    completion(.needsReset)
                    return
                }
                if code == ImmurokStatus.errWaitButton.rawValue {
                    NSLog("BLEManager: PAIR_INIT accepted, waiting for device button...")
                    DispatchQueue.main.async { [weak self] in
                        self?.onPairWaitButton?()
                    }
                    self.startPairButtonWait(retries: retries, completion: completion)
                    return
                }
                NSLog("BLEManager: PAIR_INIT error: 0x%02x", code)
                completion(.generic)
                return
            }

            // Legacy/no-button-required path: [0x30][33B pubkey]
            if response.count >= 34 {
                self.continuePairing(devicePubKey: response[1..<34], completion: completion)
            } else {
                completion(.generic)
            }
        }
    }

    /// Shared handling for the device rejecting ECDH with 0xE1 (BLE connection
    /// params inadequate). The rejection can arrive either as the direct
    /// PAIR_INIT response or — because the device only runs ECDH after the
    /// button press — as a bare 1-byte notification during the button wait.
    private func retryAfterLinkParams(retries: Int,
                                      completion: @escaping (PairFailureReason?) -> Void) {
        guard retries > 0 else {
            NSLog("BLEManager: PAIR_INIT failed after retries (BLE params not accepted)")
            Task { @MainActor in
                LogManager.shared.log("Pairing failed: BLE connection params inadequate for ECDH")
            }
            completion(.linkParams)
            return
        }
        NSLog("BLEManager: PAIR_INIT rejected (link params), retrying in 5s...")
        Task { @MainActor in
            LogManager.shared.log("Pairing rejected (BLE params), retrying…")
        }
        queue.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.startPairingAttempt(retries: retries - 1, completion: completion)
        }
    }

    /// Install the pair-button waiter. Resolves when device sends:
    ///   - [0x30][33B pubkey] — button pressed, ECDH done → continue PAIR_CONFIRM
    ///   - [0x34, 0x00] timeout, [0x34, 0x02] cancel → fail with reason
    ///   - [0xE1] — button was pressed but the device refused to run ECDH
    ///     because the BLE connection params were inadequate → retry
    /// Outer 45s safety timeout: 30s button window + ~5s ECC + headroom.
    private func startPairButtonWait(retries: Int,
                                     completion: @escaping (PairFailureReason?) -> Void) {
        pendingPairButtonGeneration &+= 1
        let myGen = pendingPairButtonGeneration
        pendingPairButton = { [weak self] result in
            guard let self = self else { return }
            self.pendingPairButton = nil
            switch result {
            case .success(let pubkey):
                self.continuePairing(devicePubKey: pubkey, completion: completion)
            case .failure(.linkParams):
                self.retryAfterLinkParams(retries: retries, completion: completion)
            case .failure(let reason):
                completion(reason)
            }
        }
        queue.asyncAfter(deadline: .now() + 45.0) { [weak self] in
            guard let self = self, self.pendingPairButtonGeneration == myGen else { return }
            if let cb = self.pendingPairButton {
                NSLog("BLEManager: Pair button wait outer timeout (45s)")
                self.pendingPairButton = nil
                cb(.failure(.buttonTimeout))
            }
        }
    }

    private func continuePairing(devicePubKey: Data, completion: @escaping (PairFailureReason?) -> Void) {
        NSLog("BLEManager: Got device pubkey, sending PAIR_CONFIRM")
        let security = ImmurokSecurity.shared
        let appPubKey = security.startPairing()
        let payload = [UInt8](appPubKey)
        sendCommand(.pairConfirm, payload: payload, timeout: 8.0) { [weak self] response in
            guard let self = self else { return }
            guard let response = response, response.count >= 2,
                  response[0] == ImmurokCommand.pairConfirm.rawValue,
                  response[1] == ImmurokStatus.ok.rawValue else {
                NSLog("BLEManager: PAIR_CONFIRM failed")
                completion(.generic)
                return
            }
            let success = security.completePairing(deviceCompressedPubKey: Data(devicePubKey))
            NSLog("BLEManager: Pairing %@", success ? "succeeded" : "failed (App-side)")
            if success {
                self.isDeviceVerified = true
            }
            completion(success ? nil : .generic)
            DispatchQueue.main.async { [weak self] in
                self?.onPairingCompleted?(success)
            }
        }
    }

    /// Get fingerprint bitmap (which slots have fingerprints)
    /// Returns bitmap where bit N = 1 means slot N has a fingerprint
    // MARK: - 双主机槽位

    /// 槽位占用与当前活跃槽。响应 `[0x39][OK][bitmap][active]`。
    /// bit0 = 槽 1、bit1 = 槽 2。未配对时也可读 —— 新主机据此得知自己是第二台。
    func getSlotStatus(completion: @escaping (_ bitmap: UInt8, _ active: UInt8) -> Void) {
        guard deviceState.isConnected else { completion(0, 0); return }
        sendCommand(.slotStatus) { response in
            guard let r = response, r.count >= 4, r[1] == 0x00 else {
                completion(0, 0)
                return
            }
            completion(r[2], r[3])
        }
    }

    /// own 解绑结果。设备清掉本槽后**立即重启换地址**,所以「断开 / 无响应 /
    /// 超时」恰恰是成功信号(设备重启了),不能当失败。**只有明确收到
    /// NOT_PAIRED(0xF2)**——设备连着却因 active 槽不是本机把 SLOT_CLEAR 挡回
    /// ——才是真正的拒绝。2026-08-04 修:原来把重启断开当成 ok=false,误报
    /// "unpair failed"。
    enum OwnSlotClearResult {
        case cleared    // 3c 00,或断开/无响应(设备成功重启)
        case rejected   // 3c f2:active 槽不是本机,需先切回本机
    }

    /// 清除本主机所在的槽。设备成功后会重启（本槽密钥已失效）。
    func clearOwnSlot(completion: @escaping (OwnSlotClearResult) -> Void) {
        guard deviceState.isConnected else { completion(.cleared); return }
        sendCommand(.slotClear, timeout: 10.0) { response in
            if let r = response, r.count >= 2, r[1] == 0xF2 {
                completion(.rejected)   // 明确拒绝
            } else {
                completion(.cleared)    // 3c 00 / 断开 / 超时 = 设备已重启,成功
            }
        }
    }

    /// 清除**另一个**槽（解绑不在身边的那台主机）。
    ///
    /// 设备先回 1 字节 `0x11`(WAIT_FP) 再等指纹，指纹过后才回最终状态 ——
    /// 与 ENROLL_START / DELETE_FP 同一套门协议。必须走 pendingGateCompletion，
    /// 否则那条 1 字节的 WAIT_FP 会被当成畸形应答，用户先看到一个错误弹窗、
    /// 之后才被要求按指纹（2026-08-04 实机反馈）。
    ///
    /// 成功后设备不重启 —— 本槽密钥完好。
    func clearSlot(_ slot: UInt8, completion: @escaping (Bool) -> Void) {
        guard deviceState.isConnected else { completion(false); return }
        sendCommand(.slotClear, payload: [slot]) { [weak self] response in
            guard let r = response, r.count >= 1 else { completion(false); return }
            if r[0] == ImmurokStatus.waitFingerprint.rawValue {
                NSLog("BLEManager: SLOT_CLEAR waiting for FP gate")
                self?.pendingGateCompletion = completion
                self?.startGateTimeout()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: BLEManager.fingerprintGateRequiredNotification, object: nil)
                }
                return
            }
            // 无门路径（清自己的槽）应答是 [0x3C][status]。
            completion(r.count >= 2 ? r[1] == 0x00 : r[0] == 0x00)
        }
    }

    func getFingerprintBitmap(completion: @escaping (UInt8) -> Void) {
        guard deviceState.isConnected else {
            completion(0)
            return
        }

        sendCommand(.fpList) { response in
            guard let response = response, response.count >= 2 else {
                NSLog("BLEManager: Invalid FP_LIST response")
                completion(0)
                return
            }

            // response[0] = status, response[1] = bitmap (bit 0-4 for slots 0-4)
            if response[0] == ImmurokStatus.ok.rawValue {
                let bitmap = response[1]
                let count = (0..<5).filter { bitmap & (1 << $0) != 0 }.count
                NSLog("BLEManager: Fingerprint bitmap: 0x%02X (%d templates)", bitmap, count)
                completion(bitmap)
            } else {
                completion(0)
            }
        }
    }

    /// Get fingerprint count (for backward compatibility)
    func getFingerprintCount(completion: @escaping (Int) -> Void) {
        getFingerprintBitmap { bitmap in
            let count = (0..<5).filter { bitmap & (1 << $0) != 0 }.count
            completion(count)
        }
    }

    /// Get device status including fingerprint bitmap and paired status
    func getDeviceStatus(completion: @escaping (UInt8, Bool, Int?, String?) -> Void) {
        guard deviceState.isConnected else {
            completion(0, false, nil, nil)
            return
        }

        sendCommand(.getStatus) { [weak self] response in
            guard let response = response, response.count >= 3,
                  response[0] == ImmurokStatus.ok.rawValue else {
                completion(0, false, nil, nil)
                return
            }

            let bitmap = response[1]
            let isPaired = response[2] != 0
            let batteryLevel = response.count >= 4 ? Int(response[3]) : nil
            let firmwareVersion: String?
            if response.count >= 9 {
                let build = (UInt16(response[7]) << 8) | UInt16(response[8])
                firmwareVersion = "\(response[4]).\(response[5]).\(response[6]).\(String(build, radix: 16, uppercase: false))"
            } else if response.count >= 7 {
                firmwareVersion = "\(response[4]).\(response[5]).\(response[6])"
            } else {
                firmwareVersion = nil
            }
            NSLog("BLEManager: Status: bitmap=0x%02x, paired=%d, battery=%@, fw=%@", bitmap, isPaired ? 1 : 0, batteryLevel.map { "\($0)%" } ?? "n/a", firmwareVersion ?? "n/a")
            if let version = firmwareVersion {
                self?.firmwareVersion = version
                DispatchQueue.main.async {
                    self?.onFirmwareVersionRead?(version)
                }
            }

            // Check for piggybacked pending FP match (byte 9 = separator, bytes 10+: 0x21 notification data)
            if response.count >= 21, response[10] == 0x21 {
                let matchData = Data(response[10..<21])  // [0x21][page_id:2B][hmac:8B]
                let (pageId, valid) = ImmurokSecurity.shared.verifyFingerprintMatch(data: matchData)
                if valid {
                    NSLog("BLEManager: Pending FP match in GET_STATUS — page_id=%d", pageId)
                    Task { @MainActor in LogManager.shared.log("Pending FP match id=\(pageId)") }
                    self?.sendAck()
                    DispatchQueue.main.async { [weak self] in
                        self?.onFingerprintMatch?(pageId)
                    }
                }
            }

            completion(bitmap, isPaired, batteryLevel, firmwareVersion)
        }
    }

    /// Read raw battery voltage for calibration display.
    /// Returns (mV, percentage, adcRaw) or nil on failure.
    ///
    /// `forceFresh` controls whether the device runs an ADC re-measurement
    /// (firmware ≥ 1.3.8 honours the flag; older firmware always
    /// re-measures because it ignores the unknown payload byte):
    ///   - `true` (default) — force a fresh Batt_MeasLevel. Use for
    ///     user-initiated refresh ("click to refresh" needs to feel
    ///     responsive). Blocks ~500 ms on vbat_settle so caller sees a
    ///     2–3 s round-trip; timeout is 5 s to cover BLE queue slack.
    ///   - `false` — return whatever the firmware's own 5-min
    ///     BATT_PERIODIC_EVT cycle last cached. Use for periodic
    ///     background logging — adds zero ADC work on top of the
    ///     device's natural cadence. Round-trip ~100–200 ms; 2 s
    ///     timeout is plenty.
    func getBatteryRaw(forceFresh: Bool = true, completion: @escaping ((mv: Int, pct: Int, adc: Int)?) -> Void) {
        guard deviceState.isConnected else {
            completion(nil)
            return
        }
        let payload: [UInt8] = forceFresh ? [] : [0x01]
        let timeout: TimeInterval = forceFresh ? 5.0 : 2.0
        sendCommand(.getBattRaw, payload: payload, timeout: timeout) { response in
            guard let response = response, response.count >= 6,
                  response[0] == ImmurokStatus.ok.rawValue else {
                completion(nil)
                return
            }
            let mv = Int(response[1]) | (Int(response[2]) << 8)
            let pct = Int(response[3])
            let adc = Int(response[4]) | (Int(response[5]) << 8)
            completion((mv: mv, pct: pct, adc: adc))
        }
    }

    // MARK: - Keystore Methods

    /// Get entry count for a key category
    func getKeyCount(cat: KeystoreCategory, completion: @escaping (Int) -> Void) {
        getKeyCountAndChecksum(cat: cat) { count, _ in completion(count) }
    }

    /// Get entry count AND content digest for a key category.
    /// Firmware response (since FW 1.2.7): [OK][count:1B][checksum:4B LE]
    /// Older firmware returns [OK][count:1B] — checksum reported as 0 here, so
    /// any cached digest comparison treats it as "must refetch" (safe fallback).
    func getKeyCountAndChecksum(cat: KeystoreCategory,
                                 completion: @escaping (Int, UInt32) -> Void) {
        guard deviceState.isConnected else {
            completion(0, 0)
            return
        }

        sendCommand(.keyCount, payload: [cat.rawValue]) { response in
            guard let response = response, response.count >= 2,
                  response[0] == ImmurokStatus.ok.rawValue else {
                completion(0, 0)
                return
            }
            let count = Int(response[1])
            var checksum: UInt32 = 0
            if response.count >= 6 {
                checksum = UInt32(response[2])
                       | (UInt32(response[3]) << 8)
                       | (UInt32(response[4]) << 16)
                       | (UInt32(response[5]) << 24)
            }
            completion(count, checksum)
        }
    }

    /// Fetch all entry names for a category (KEY_COUNT + KEY_READ chain, all on BLE queue)
    /// Keeps entire command chain on BLE callback thread — no MainActor hops between commands.
    func getKeyEntryNames(cat: KeystoreCategory,
                          progress: ((Int, Int) -> Void)? = nil,
                          completion: @escaping ([(index: Int, name: String)]) -> Void) {
        getKeyCount(cat: cat) { [weak self] count in
            guard let self = self, count > 0 else {
                completion([])
                return
            }
            progress?(0, count)
            self.chainReadNames(cat: cat, count: count, index: 0, result: [],
                                progress: progress, completion: completion)
        }
    }

    private func chainReadNames(cat: KeystoreCategory, count: Int, index: Int,
                                result: [(index: Int, name: String)],
                                progress: ((Int, Int) -> Void)?,
                                completion: @escaping ([(index: Int, name: String)]) -> Void) {
        guard index < count else {
            completion(result)
            return
        }
        readKeyEntryName(cat: cat, idx: UInt8(index)) { [weak self] name in
            var updated = result
            if let name = name {
                updated.append((index: index, name: name))
            }
            progress?(index + 1, count)
            self?.chainReadNames(cat: cat, count: count, index: index + 1,
                                 result: updated, progress: progress, completion: completion)
        }
    }

    /// Fetch entry names + service for OTP category (name at 0-15, service at 16-31)
    /// Single KEY_READ at offset 0 returns 59 bytes, covering both fields
    func getKeyEntryNamesAndService(cat: KeystoreCategory,
                                    progress: ((Int, Int) -> Void)? = nil,
                                    completion: @escaping ([(index: Int, name: String, service: String)]) -> Void) {
        getKeyCount(cat: cat) { [weak self] count in
            guard let self = self, count > 0 else {
                completion([])
                return
            }
            progress?(0, count)
            self.chainReadNamesAndService(cat: cat, count: count, index: 0, result: [],
                                          progress: progress, completion: completion)
        }
    }

    private func chainReadNamesAndService(cat: KeystoreCategory, count: Int, index: Int,
                                          result: [(index: Int, name: String, service: String)],
                                          progress: ((Int, Int) -> Void)?,
                                          completion: @escaping ([(index: Int, name: String, service: String)]) -> Void) {
        guard index < count else {
            completion(result)
            return
        }
        // KEY_READ at offset 0 returns up to 59 bytes — covers name(30) + service(30)
        sendCommand(.keyRead, payload: [cat.rawValue, UInt8(index), 0]) { [weak self] response in
            var updated = result
            if let response = response, response.count > 3,
               response[0] == ImmurokStatus.ok.rawValue {
                let chunk = response.subdata(in: 3..<response.count)
                let nameData = chunk.prefix(min(30, chunk.count))
                let name = String(data: nameData.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
                var service = ""
                if chunk.count > 30 {
                    let serviceData = chunk[30..<min(60, chunk.count)]
                    service = String(data: serviceData.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
                }
                updated.append((index: index, name: name, service: service))
            }
            progress?(index + 1, count)
            self?.chainReadNamesAndService(cat: cat, count: count, index: index + 1,
                                           result: updated, progress: progress, completion: completion)
        }
    }

    /// Read the name field of a key entry via single KEY_READ.
    /// Name field size is per-category: SSH=16, OTP=30, API=32 — using a
    /// fixed 32 spilled into OTP's adjacent service field, which (when
    /// device padding is non-NUL) caused `findKeyIndex` to see a name
    /// longer than what `imk list` showed via the 30-byte read path,
    /// breaking exact-match lookups like `imk get imk://otp/eve+109`.
    func readKeyEntryName(cat: KeystoreCategory, idx: UInt8, completion: @escaping (String?) -> Void) {
        guard deviceState.isConnected else {
            completion(nil)
            return
        }

        let nameFieldSize: Int = {
            switch cat {
            case .ssh: return 16
            case .otp: return 30
            case .api: return 32
            }
        }()

        sendCommand(.keyRead, payload: [cat.rawValue, idx, 0]) { response in
            // Response: [OK][total_lo:1B][off:1B][data...<=59B]
            // total_lo may be 0 for 256B entries (uint8 truncation) — we only need data bytes
            guard let response = response, response.count > 3,
                  response[0] == ImmurokStatus.ok.rawValue else {
                completion(nil)
                return
            }

            let chunkData = response.subdata(in: 3..<response.count)
            let nameLen = min(nameFieldSize, chunkData.count)
            let nameData = chunkData.prefix(nameLen)
            let trimmed = nameData.prefix(while: { $0 != 0 })
            completion(String(data: trimmed, encoding: .utf8) ?? "")
        }
    }

    /// Read a key entry via chunked reads (59B per chunk)
    /// Uses device-reported readable size (total_lo from first response) to respect
    /// firmware-enforced read limits (e.g. SSH private key area is masked).
    func readKeyEntry(cat: KeystoreCategory, idx: UInt8, completion: @escaping (Data?) -> Void) {
        guard deviceState.isConnected else {
            completion(nil)
            return
        }

        var accumulated = Data()
        var readableSize = 0

        func readChunk(offset: Int) {
            self.sendCommand(.keyRead, payload: [cat.rawValue, idx, UInt8(offset)]) { response in
                guard let response = response, response.count > 3,
                      response[0] == ImmurokStatus.ok.rawValue else {
                    completion(nil)
                    return
                }

                // Response: [OK][total_lo:1B][off:1B][data...]
                let deviceTotal = Int(response[1])
                let respOffset = Int(response[2])
                let chunkData = response.subdata(in: 3..<response.count)

                // Use device-reported readable size from first chunk
                if accumulated.isEmpty {
                    readableSize = deviceTotal > 0 ? deviceTotal : cat.entrySize
                    accumulated = Data(count: readableSize)
                }

                let copyLen = min(chunkData.count, readableSize - respOffset)
                guard copyLen > 0 else {
                    completion(nil)
                    return
                }
                accumulated.replaceSubrange(respOffset..<(respOffset + copyLen), with: chunkData.prefix(copyLen))

                let nextOffset = respOffset + copyLen
                if nextOffset >= readableSize {
                    completion(accumulated)
                } else {
                    readChunk(offset: nextOffset)
                }
            }
        }

        readChunk(offset: 0)
    }

    /// Write a complete key entry via chunked writes + commit (with FP gate)
    func writeKeyEntry(cat: KeystoreCategory, idx: UInt8, data: Data, completion: @escaping (Bool) -> Void) {
        guard deviceState.isConnected else {
            completion(false)
            return
        }

        let chunkSize = 59

        func writeChunk(offset: Int) {
            let remaining = data.count - offset
            let len = min(remaining, chunkSize)
            var payload: [UInt8] = [cat.rawValue, idx, UInt8(offset)]
            payload.append(contentsOf: data[offset..<(offset + len)])

            self.sendCommand(.keyWrite, payload: payload) { response in
                guard let response = response, response.count >= 1,
                      response[0] == ImmurokStatus.ok.rawValue else {
                    completion(false)
                    return
                }

                let nextOffset = offset + len
                if nextOffset >= data.count {
                    // All chunks written, send commit
                    self.commitKeyEntry(cat: cat, idx: idx, completion: completion)
                } else {
                    writeChunk(offset: nextOffset)
                }
            }
        }

        writeChunk(offset: 0)
    }

    /// Commit staged key entry (with FP gate handling)
    private func commitKeyEntry(cat: KeystoreCategory, idx: UInt8, completion: @escaping (Bool) -> Void) {
        sendCommand(.keyCommit, payload: [cat.rawValue, idx]) { [weak self] response in
            guard let response = response, response.count >= 1 else {
                completion(false)
                return
            }

            let status = response[0]
            if status == ImmurokStatus.ok.rawValue {
                completion(true)
            } else if status == ImmurokStatus.waitFingerprint.rawValue {
                self?.pendingGateCompletion = completion
                self?.startGateTimeout()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: BLEManager.fingerprintGateRequiredNotification, object: nil)
                }
            } else {
                completion(false)
            }
        }
    }

    /// Delete a key entry (with FP gate handling)
    func deleteKeyEntry(cat: KeystoreCategory, idx: UInt8, completion: @escaping (Bool) -> Void) {
        guard deviceState.isConnected else {
            completion(false)
            return
        }

        sendCommand(.keyDelete, payload: [cat.rawValue, idx]) { [weak self] response in
            guard let response = response, response.count >= 1 else {
                completion(false)
                return
            }

            let status = response[0]
            if status == ImmurokStatus.ok.rawValue {
                completion(true)
            } else if status == ImmurokStatus.waitFingerprint.rawValue {
                self?.pendingGateCompletion = completion
                self?.startGateTimeout()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: BLEManager.fingerprintGateRequiredNotification, object: nil)
                }
            } else {
                completion(false)
            }
        }
    }

    // MARK: - SSH Crypto Methods

    /// Reverse byte order of a 32-byte coordinate (LE↔BE)
    private func reverseCoordinate(_ data: Data) -> Data {
        Data(data.reversed())
    }

    /// Convert 64-byte signature/pubkey endianness (two 32B coordinates, each reversed)
    func convertEndianness64(_ data: Data) -> Data {
        guard data.count == 64 else { return data }
        return reverseCoordinate(data[data.startIndex..<(data.startIndex + 32)])
             + reverseCoordinate(data[(data.startIndex + 32)..<(data.startIndex + 64)])
    }

    /// Read result buffer from device (chunked, KEY_RESULT command)
    func readResultBuffer(completion: @escaping (Data?) -> Void) {
        guard deviceState.isConnected else {
            completion(nil)
            return
        }

        var accumulated = Data()

        func readChunk(offset: UInt8) {
            self.sendCommand(.keyResult, payload: [offset]) { response in
                // Response: [OK][total:1B][off:1B][data...]
                guard let response = response, response.count > 3,
                      response[0] == ImmurokStatus.ok.rawValue else {
                    completion(nil)
                    return
                }

                let total = Int(response[1])
                let off = Int(response[2])
                let chunkData = response.subdata(in: 3..<response.count)

                if accumulated.count < total {
                    accumulated = Data(count: total)
                }

                let copyLen = min(chunkData.count, total - off)
                guard copyLen > 0 else {
                    completion(nil)
                    return
                }
                accumulated.replaceSubrange(off..<(off + copyLen), with: chunkData.prefix(copyLen))

                let nextOffset = off + copyLen
                if nextOffset >= total {
                    completion(accumulated.prefix(total))
                } else {
                    readChunk(offset: UInt8(nextOffset))
                }
            }
        }

        readChunk(offset: 0)
    }

    /// ECDSA P-256 sign a 32-byte hash using SSH key at idx (FP gated)
    /// Returns 64-byte signature (r||s, big-endian) on success
    func sshSign(idx: UInt8, hash: Data, completion: @escaping (Data?) -> Void) {
        guard deviceState.isConnected, hash.count == 32 else {
            completion(nil)
            return
        }

        // Payload: [cat=0][idx][hash_off=0][hash_data_32B]
        var payload: [UInt8] = [0x00, idx, 0x00]
        payload.append(contentsOf: hash)

        sendCommand(.keySign, payload: payload, timeout: 15.0) { [weak self] response in
            guard let self = self, let response = response, response.count >= 1 else {
                completion(nil)
                return
            }

            let status = response[0]
            if status == ImmurokStatus.ok.rawValue && response.count >= 2 {
                // Sign completed immediately, read result buffer
                self.readResultBuffer { data in
                    guard let data = data, data.count == 64 else {
                        completion(nil)
                        return
                    }
                    // Convert LE to BE
                    completion(self.convertEndianness64(data))
                }
            } else if status == ImmurokStatus.waitFingerprint.rawValue || status == 0x10 {
                // 0x11 WAIT_FP = need fingerprint, 0x10 = cooldown (approved, signing in progress)
                let needsFP = status == ImmurokStatus.waitFingerprint.rawValue
                self.pendingGateCompletion = { success in
                    guard success else {
                        completion(nil)
                        return
                    }
                    self.readResultBuffer { data in
                        guard let data = data, data.count == 64 else {
                            completion(nil)
                            return
                        }
                        completion(self.convertEndianness64(data))
                    }
                }
                self.startGateTimeout()
                if needsFP {
                    self.onFingerprintGateRequired?()
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: BLEManager.fingerprintGateRequiredNotification, object: nil)
                    }
                } else {
                    self.onFingerprintGateApproved?()
                }
            } else {
                completion(nil)
            }
        }
    }

    /// Get public key for SSH key at idx (no FP gate)
    /// Returns 64-byte public key (x||y, big-endian)
    func sshGetPublicKey(idx: UInt8, completion: @escaping (Data?) -> Void) {
        guard deviceState.isConnected else {
            completion(nil)
            return
        }

        sendCommand(.keyGetPub, payload: [0x00, idx]) { [weak self] response in
            guard let self = self, let response = response, response.count >= 2,
                  response[0] == ImmurokStatus.ok.rawValue else {
                completion(nil)
                return
            }

            self.readResultBuffer { data in
                guard let data = data, data.count == 64 else {
                    completion(nil)
                    return
                }
                // Convert LE to BE
                completion(self.convertEndianness64(data))
            }
        }
    }

    /// Generate a new P-256 keypair on device (FP gated)
    /// Returns (index, publicKey_64B_BE) on success
    func sshGenerateKey(name: String, completion: @escaping ((idx: Int, publicKey: Data)?) -> Void) {
        guard deviceState.isConnected else {
            completion(nil)
            return
        }

        // Prepare 16-byte name (zero-padded)
        var nameBytes = [UInt8](repeating: 0, count: 16)
        let nameData = Array(name.utf8.prefix(16))
        for (i, b) in nameData.enumerated() { nameBytes[i] = b }

        var payload: [UInt8] = [0x00]  // cat=SSH
        payload.append(contentsOf: nameBytes)

        sendCommand(.keyGenerate, payload: payload, timeout: 15.0) { [weak self] response in
            guard let self = self, let response = response, response.count >= 1 else {
                completion(nil)
                return
            }

            let status = response[0]

            let handleSuccess: (Data) -> Void = { response in
                let newIdx: Int
                if response.count >= 3 {
                    newIdx = Int(response[2])
                } else {
                    newIdx = 0
                }

                self.readResultBuffer { data in
                    guard let data = data, data.count == 64 else {
                        completion(nil)
                        return
                    }
                    completion((idx: newIdx, publicKey: self.convertEndianness64(data)))
                }
            }

            if status == ImmurokStatus.ok.rawValue {
                handleSuccess(response)
            } else if status == ImmurokStatus.waitFingerprint.rawValue {
                self.pendingGateCompletion = { success in
                    // Note: the gate completion for KEY_GENERATE gets a response with new_idx
                    // but we might not have it. Try reading from result buffer anyway.
                    guard success else {
                        completion(nil)
                        return
                    }
                    // After FP gate, the device already executed generate.
                    // The response was sent as notification. We need to get new_idx.
                    // For simplicity, re-read the count to determine the new index.
                    self.getKeyCount(cat: .ssh) { count in
                        let newIdx = max(0, count - 1)
                        self.readResultBuffer { data in
                            guard let data = data, data.count == 64 else {
                                completion(nil)
                                return
                            }
                            completion((idx: newIdx, publicKey: self.convertEndianness64(data)))
                        }
                    }
                }
                self.startGateTimeout()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: BLEManager.fingerprintGateRequiredNotification, object: nil)
                }
            } else {
                completion(nil)
            }
        }
    }

    /// Timeout for fingerprint gate (30s)
    private func startGateTimeout() {
        fpFailureCount = 0
        gateGeneration &+= 1
        let myGeneration = gateGeneration
        queue.asyncAfter(deadline: .now() + 30.0) { [weak self] in
            guard let self = self, self.gateGeneration == myGeneration else { return }
            let hadHold = self.pendingGateDataCompletion != nil || self.pendingGateCompletion != nil
            let dataCb = self.pendingGateDataCompletion
            let gateCb = self.pendingGateCompletion
            self.pendingGateDataCompletion = nil
            self.pendingGateCompletion = nil
            if hadHold {
                self.releaseGateHold {
                    if let cb = dataCb {
                        NSLog("BLEManager: FP gate data timeout")
                        cb(nil)
                    }
                    if let cb = gateCb {
                        NSLog("BLEManager: FP gate timeout")
                        cb(false)
                    }
                }
            }
            // Notify device to stop LED blinking and cancel pending gate.
            // Queues behind any chained command from the callbacks above.
            self.cancelGate()
        }
    }

    // MARK: - Private Methods

    /// Send ACK for fingerprint match notification
    /// Must go through the command queue to avoid response mismatch with in-flight commands.
    private func sendAck() {
        guard deviceState.isConnected else {
            NSLog("BLEManager: Cannot send ACK - not connected")
            return
        }

        sendCommand(.fpMatchAck, timeout: 3.0) { _ in
            NSLog("BLEManager: ACK completed")
        }
    }

    private func sendCommand(_ command: ImmurokCommand, payload: [UInt8] = [], timeout: TimeInterval = 5.0, completion: @escaping (Data?) -> Void) {
        if isOnBLEQueue {
            // Called from within a BLE callback chain — execute synchronously
            enqueueOrExecute(command, payload: payload, timeout: timeout, completion: completion)
        } else {
            // Called from external thread — dispatch to BLE queue
            queue.async { [weak self] in
                self?.enqueueOrExecute(command, payload: payload, timeout: timeout, completion: completion)
            }
        }
    }

    /// Enqueue or execute a command (must be called on BLE queue)
    private func enqueueOrExecute(_ command: ImmurokCommand, payload: [UInt8], timeout: TimeInterval, completion: @escaping (Data?) -> Void) {
        if commandInFlight {
            let inFlight = currentCommand
            let depth = commandQueue.count + 1
            Task { @MainActor in
                LogManager.shared.log("queued cmd=0x\(String(format: "%02x", command.rawValue)) behind 0x\(String(format: "%02x", inFlight?.rawValue ?? 0)) (depth \(depth))")
            }
            commandQueue.append((command: command, payload: payload, timeout: timeout, completion: completion))
            return
        }
        executeSend(command, payload: payload, timeout: timeout, completion: completion)
    }

    /// Execute a command immediately (must be called on BLE queue, commandInFlight must be false)
    private func executeSend(_ command: ImmurokCommand, payload: [UInt8], timeout: TimeInterval = 5.0, completion: @escaping (Data?) -> Void) {
        guard let cmdChar = cmdCharacteristic, let peripheral = peripheral else {
            completion(nil)
            dequeueNext()
            return
        }

        commandInFlight = true
        currentCommand = command

        // Build packet: [command][length][payload...]
        var data = Data(repeating: 0, count: 2 + payload.count)
        data[0] = command.rawValue
        data[1] = UInt8(payload.count)
        for (i, byte) in payload.enumerated() {
            data[2 + i] = byte
        }

        let hexStr = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        Task { @MainActor in LogManager.shared.log("TX cmd=0x\(String(format: "%02x", command.rawValue)) [\(hexStr)]") }

        commandGeneration &+= 1
        let myGeneration = commandGeneration
        responseCallback = completion

        // Timeout — only fires if no newer command has been sent since
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self = self, self.commandGeneration == myGeneration else { return }
            if let cb = self.responseCallback {
                Task { @MainActor in LogManager.shared.log("TX timeout cmd=0x\(String(format: "%02x", command.rawValue))") }
                self.responseCallback = nil
                self.commandInFlight = false
                self.currentCommand = nil
                cb(nil)
                if !self.commandInFlight {
                    self.dequeueNext()
                }
            }
        }

        peripheral.writeValue(data, for: cmdChar, type: .withResponse)
    }

    /// Dequeue and execute the next queued command (must be called on BLE queue)
    private func dequeueNext() {
        guard !commandQueue.isEmpty else { return }
        let next = commandQueue.removeFirst()
        executeSend(next.command, payload: next.payload, timeout: next.timeout, completion: next.completion)
    }

    /// Release the commandInFlight hold taken when an FP gate was armed
    /// (KEY_SIGN/KEY_GENERATE/KEY_OTP_GET WAIT_FP) and drain queued
    /// commands. Mirrors the dispatcher's post-callback dance at the bottom
    /// of handleData: chained sendCommand calls inside `body` re-take the
    /// hold via executeSend, otherwise we drain. Must be called on BLE queue.
    private func releaseGateHold(_ body: () -> Void) {
        commandInFlight = false
        currentCommand = nil
        body()
        if !commandInFlight {
            dequeueNext()
        }
    }

    /// Release the commandInFlight hold taken when AUTH_REQUEST returned
    /// WAIT_FP. Called at AUTH_OK / 3-fail / timeout sites so any command
    /// that got queued during the FP-wait window (e.g. battery refresh
    /// GET_STATUS) can drain. Must be called on BLE queue. Caller must
    /// NOT clear fingerprintResultCompletion before calling — that
    /// completion is fired by onUnlockResult on the main thread and
    /// clearing it here would skip the actual user callback.
    private func releaseAuthHold() {
        if commandInFlight {
            commandInFlight = false
            currentCommand = nil
            dequeueNext()
        }
    }

    private func startReconnectTimer() {
        stopReconnectTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if !self.deviceState.isConnected {
                self.doConnect()
            }
        }
        reconnectTimer = timer
        timer.resume()
        doConnect()
    }

    private func stopReconnectTimer() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }


    // MARK: - OTA Methods

    /// Write data to OTA characteristic, then poll-read response
    /// Firmware may return empty data if async operation (e.g. ERASE) is still in progress.
    /// We retry reads every pollInterval until non-empty data arrives or timeout.
    func otaWriteAndRead(data: Data, timeout: TimeInterval = 5.0, pollInterval: TimeInterval = 0.2, completion: @escaping (Data?) -> Void) {
        guard let otaChar = otaCharacteristic, let peripheral = peripheral else {
            NSLog("BLEManager: OTA characteristic not available")
            completion(nil)
            return
        }

        var completed = false
        let timeoutItem = DispatchWorkItem { [weak self] in
            guard !completed else { return }
            completed = true
            NSLog("BLEManager: OTA read timeout after %.1fs", timeout)
            self?.otaReadCallback = nil
            completion(nil)
        }
        queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

        // Read callback that retries on empty data
        func setupReadCallback() {
            self.otaReadCallback = { [weak self] readData in
                guard !completed else { return }
                if let d = readData, d.count > 0 {
                    completed = true
                    timeoutItem.cancel()
                    completion(d)
                } else {
                    // Empty response — async operation still in progress, retry
                    self?.queue.asyncAfter(deadline: .now() + pollInterval) {
                        guard !completed else { return }
                        setupReadCallback()
                        peripheral.readValue(for: otaChar)
                    }
                }
            }
        }

        setupReadCallback()
        peripheral.writeValue(data, for: otaChar, type: .withResponse)
    }

    /// Write data to OTA characteristic using Write Without Response.
    /// Faster than Write With Response — no BLE round-trip per packet.
    /// Requires firmware to have requested latency 0 during OTA.
    /// Data integrity verified by SHA256+HMAC at OTA END.
    func otaWriteOnly(data: Data, completion: @escaping (Bool) -> Void) {
        guard let otaChar = otaCharacteristic, let peripheral = peripheral else {
            completion(false)
            return
        }

        peripheral.writeValue(data, for: otaChar, type: .withoutResponse)

        if peripheral.canSendWriteWithoutResponse {
            completion(true)
        } else {
            otaWriteReadyCallback = { completion(true) }
        }
    }

    /// Check if OTA service is available
    var isOTAAvailable: Bool {
        return otaCharacteristic != nil && deviceState.isConnected
    }

    func stop() {
        stopReconnectTimer()
        disconnect()
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        NSLog("BLEManager: Central state: %d", central.state.rawValue)

        let oldStatus = bluetoothAuthStatus

        switch central.state {
        case .poweredOn:
            bluetoothAuthStatus = .authorized
            if deviceState.isConnected {
                NSLog("BLEManager: Already connected, skip reconnect")
            } else if displaySleeping {
                NSLog("BLEManager: Screen locked, defer reconnect until unlock")
            } else {
                startReconnectTimer()
            }

        case .unauthorized:
            bluetoothAuthStatus = .denied
            NSLog("BLEManager: Bluetooth permission denied")

        case .poweredOff:
            bluetoothAuthStatus = .poweredOff
            NSLog("BLEManager: Bluetooth is powered off")
            // Bluetooth off implicitly disconnects all peripherals,
            // but didDisconnectPeripheral may not be called
            if deviceState.isConnected {
                deviceState = .disconnected
                cmdCharacteristic = nil
                rspCharacteristic = nil
                otaCharacteristic = nil
                responseCallback?(nil)
                responseCallback = nil
                commandInFlight = false
                currentCommand = nil
                let pending = commandQueue
                commandQueue.removeAll()
                for item in pending { item.completion(nil) }
                if let cb = pendingGateCompletion {
                    pendingGateCompletion = nil
                    cb(false)
                }
                onDeviceDisconnected?()
            }
            stopReconnectTimer()

        case .unsupported:
            bluetoothAuthStatus = .unsupported
            NSLog("BLEManager: Bluetooth is not supported")

        case .resetting:
            NSLog("BLEManager: Bluetooth is resetting")

        case .unknown:
            bluetoothAuthStatus = .notDetermined
            NSLog("BLEManager: Bluetooth state unknown")

        @unknown default:
            bluetoothAuthStatus = .notDetermined
        }

        // Notify if status changed
        if oldStatus != bluetoothAuthStatus {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onBluetoothStatusChanged?(self.bluetoothAuthStatus)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if peripheral.name?.lowercased().contains("immurok") == true {
            NSLog("BLEManager: Discovered device: %@", peripheral.name ?? "unknown")
            centralManager.stopScan()

            self.peripheral = peripheral
            peripheral.delegate = self
            centralManager.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        NSLog("BLEManager: Connected to %@", peripheral.name ?? "unknown")
        Task { @MainActor in LogManager.shared.log("BLE connected: \(peripheral.name ?? "unknown")") }
        peripheral.discoverServices([IMMUROK_SERVICE_UUID, OTA_SERVICE_UUID, DEVICE_INFO_SERVICE_UUID, BATTERY_SERVICE_UUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let reason = error?.localizedDescription ?? "clean"
        NSLog("BLEManager: Disconnected (displaySleeping=%d, reason=%@)", displaySleeping, reason)
        Task { @MainActor in LogManager.shared.log("BLE disconnected: \(reason)") }

        responseCallback?(nil)
        responseCallback = nil
        commandInFlight = false
        currentCommand = nil
        otaReadCallback?(nil)
        otaReadCallback = nil
        otaCharacteristic = nil
        firmwareVersion = nil
        isDeviceVerified = false

        // Flush command queue
        let pending = commandQueue
        commandQueue.removeAll()
        for item in pending { item.completion(nil) }

        // Cancel pending fingerprint gate
        if let cb = pendingGateCompletion {
            pendingGateCompletion = nil
            cb(false)
        }

        // Cancel pending pair-button wait
        if let cb = pendingPairButton {
            pendingPairButton = nil
            cb(.failure(.generic))
        }

        deviceState = .disconnected
        onDeviceDisconnected?()

        if !displaySleeping {
            startReconnectTimer()
        } else {
            // Don't reconnect during sleep — active BLE reconnection can wake macOS.
            // Reconnection is deferred to onScreenDidWake.
            NSLog("BLEManager: Screen locked, defer reconnect until wake")
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        NSLog("BLEManager: Failed to connect: %@", error?.localizedDescription ?? "unknown")
        deviceState = .disconnected
        if !displaySleeping {
            startReconnectTimer()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }

        for service in services {
            if service.uuid == IMMUROK_SERVICE_UUID {
                NSLog("BLEManager: Found immurok service")
                peripheral.discoverCharacteristics([IMMUROK_CMD_CHAR_UUID, IMMUROK_RSP_CHAR_UUID], for: service)
            } else if service.uuid == OTA_SERVICE_UUID {
                NSLog("BLEManager: Found OTA service")
                peripheral.discoverCharacteristics([OTA_CHAR_UUID], for: service)
            } else if service.uuid == DEVICE_INFO_SERVICE_UUID {
                NSLog("BLEManager: Found Device Information service")
                peripheral.discoverCharacteristics([FIRMWARE_REV_CHAR_UUID], for: service)
            } else if service.uuid == BATTERY_SERVICE_UUID {
                NSLog("BLEManager: Found Battery service")
                peripheral.discoverCharacteristics([BATTERY_LEVEL_CHAR_UUID], for: service)
            }
        }
    }

    /// Challenge-response verification after GATT ready.
    /// Sends 8-byte nonce, verifies HMAC response, then triggers onDeviceConnected.
    private func performChallengeVerification(name: String) {
        guard ImmurokSecurity.shared.isPaired else {
            // Not paired yet — skip challenge, mark unverified
            NSLog("BLEManager: No pairing key, skipping challenge")
            isDeviceVerified = false
            onDeviceConnected?(name)
            return
        }

        // Fast path: if this device UUID was previously verified, trust it.
        // BLE bond already authenticates the device; HMAC on every FP match
        // provides ongoing verification.
        if let uuid = self.peripheral?.identifier.uuidString,
           ImmurokSecurity.shared.isVerifiedDevice(uuid: uuid) {
            NSLog("BLEManager: Device %@ cached as verified, skipping challenge", uuid)
            isDeviceVerified = true
            Task { @MainActor in LogManager.shared.log("Device verified (cached)") }
            onDeviceConnected?(name)
            return
        }

        let nonce = ImmurokSecurity.shared.generateChallenge()
        sendCommand(.challenge, payload: Array(nonce)) { [weak self] response in
            guard let self = self else { return }

            if let data = response, data.count >= 9, data[0] == ImmurokCommand.challenge.rawValue {
                let hmac = data[1..<9]
                if ImmurokSecurity.shared.verifyChallengeResponse(nonce: nonce, response: Data(hmac)) {
                    NSLog("BLEManager: Challenge verification OK")
                    self.isDeviceVerified = true
                    // Cache device UUID for future fast-path verification
                    if let uuid = self.peripheral?.identifier.uuidString {
                        ImmurokSecurity.shared.saveVerifiedDevice(uuid: uuid)
                    }
                    Task { @MainActor in LogManager.shared.log("Device verified") }
                } else {
                    NSLog("BLEManager: Challenge verification FAILED — HMAC mismatch")
                    self.isDeviceVerified = false
                    ImmurokSecurity.shared.clearVerifiedDevice()
                    Task { @MainActor in LogManager.shared.log("Verify failed: HMAC mismatch") }
                }
            } else if let data = response, data.count >= 2, data[0] == ImmurokCommand.challenge.rawValue, data[1] == 0xFF {
                NSLog("BLEManager: Device reports not paired")
                self.isDeviceVerified = false
                ImmurokSecurity.shared.clearVerifiedDevice()
                Task { @MainActor in LogManager.shared.log("Verify failed: device not paired") }
            } else {
                NSLog("BLEManager: Challenge timeout or invalid response")
                self.isDeviceVerified = false
                Task { @MainActor in LogManager.shared.log("Verify failed: timeout") }
            }

            self.onDeviceConnected?(name)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }

        for char in characteristics {
            if char.uuid == IMMUROK_CMD_CHAR_UUID {
                cmdCharacteristic = char
                NSLog("BLEManager: Found CMD characteristic")
            } else if char.uuid == IMMUROK_RSP_CHAR_UUID {
                rspCharacteristic = char
                NSLog("BLEManager: Found RSP characteristic")
            } else if char.uuid == OTA_CHAR_UUID {
                otaCharacteristic = char
                NSLog("BLEManager: Found OTA characteristic")
            } else if char.uuid == FIRMWARE_REV_CHAR_UUID {
                NSLog("BLEManager: Found Firmware Revision characteristic, reading...")
                peripheral.readValue(for: char)
            } else if char.uuid == BATTERY_LEVEL_CHAR_UUID {
                // TEMP 2026-05-16: BAS push 验证测试
                // 显式 setNotifyValue(false) — 必须主动写 CCCD = 0x0000 才真正退订，
                // 因为旧版 app 订阅过的 CCCD 会被 GAPBondMgr 持久化到设备 EEPROM,
                // 下次重连设备自动恢复 CCCD=1 继续发 notify (不写 false 就还在订阅).
                // 仍然做 one-shot read 取连接时初值.
                NSLog("BLEManager: Found Battery Level char — ONE-SHOT READ + EXPLICIT UNSUBSCRIBE (test)")
                peripheral.readValue(for: char)
                if char.properties.contains(.notify) {
                    peripheral.setNotifyValue(false, for: char)  // ← 主动退订
                }
            }
        }

        if cmdCharacteristic != nil && rspCharacteristic != nil && !deviceState.isConnected {
            stopReconnectTimer()

            // Subscribe to RSP notifications — must wait for confirmation
            // before marking connected (device drops responses if CCC not enabled)
            if let rspChar = rspCharacteristic, rspChar.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: rspChar)
                NSLog("BLEManager: Subscribing to RSP notifications...")
            } else {
                // No notify support — connect immediately (shouldn't happen)
                let name = peripheral.name ?? "immurok"
                deviceState = .connected(name: name)
                NSLog("BLEManager: Ready - %@", name)
                Task { @MainActor in LogManager.shared.log("GATT ready: \(name)") }
                performChallengeVerification(name: name)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == IMMUROK_RSP_CHAR_UUID else { return }

        if let error = error {
            NSLog("BLEManager: RSP notification subscribe FAILED: %@", error.localizedDescription)
            return
        }

        NSLog("BLEManager: RSP notifications confirmed (isNotifying=%d)", characteristic.isNotifying ? 1 : 0)

        // Now safe to mark connected — device CCC is enabled
        guard !deviceState.isConnected else { return }
        connectingStartTime = nil
        let name = peripheral.name ?? "immurok"
        deviceState = .connected(name: name)

        NSLog("BLEManager: Ready - %@", name)
        Task { @MainActor in LogManager.shared.log("GATT ready: \(name)") }
        performChallengeVerification(name: name)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        let cb = otaWriteReadyCallback
        otaWriteReadyCallback = nil
        cb?()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == OTA_CHAR_UUID {
            // otaWriteOnly: write-only mode (no read), signal completion immediately
            if let cb = otaWriteReadyCallback {
                otaWriteReadyCallback = nil
                if let error = error {
                    NSLog("BLEManager: OTA write error: %@", error.localizedDescription)
                }
                cb()
                return
            }

            // otaWriteAndRead: write-then-read mode (for INFO, ERASE, HEADER, END)
            if let error = error {
                NSLog("BLEManager: OTA write error: %@", error.localizedDescription)
                let cb = otaReadCallback
                otaReadCallback = nil
                cb?(nil)
            } else {
                queue.asyncAfter(deadline: .now() + 0.05) {
                    peripheral.readValue(for: characteristic)
                }
            }
            return
        }

        if let error = error {
            NSLog("BLEManager: Write error: %@", error.localizedDescription)
            if let cb = responseCallback {
                responseCallback = nil
                commandInFlight = false
                currentCommand = nil
                cb(nil)
                if !commandInFlight { dequeueNext() }
            }
        }
        // Don't call readValue - device sends response via notification
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Handle Firmware Revision read
        if characteristic.uuid == FIRMWARE_REV_CHAR_UUID {
            if let data = characteristic.value, let version = String(data: data, encoding: .utf8) {
                NSLog("BLEManager: Firmware version: %@", version)
                DispatchQueue.main.async { [weak self] in
                    self?.onFirmwareVersionRead?(version)
                }
            }
            return
        }

        // Handle Battery Level read + notify (standard BAS 0x2A19, 1 byte 0-100)
        if characteristic.uuid == BATTERY_LEVEL_CHAR_UUID {
            if let data = characteristic.value, let pct = data.first {
                NSLog("BLEManager: Battery Level push: %d%%", pct)
                DispatchQueue.main.async { [weak self] in
                    self?.onBatteryLevelNotified?(Int(pct))
                }
            }
            return
        }


        // Handle OTA characteristic reads separately
        if characteristic.uuid == OTA_CHAR_UUID {
            let cb = otaReadCallback
            otaReadCallback = nil
            if let error = error {
                NSLog("BLEManager: OTA read error: %@", error.localizedDescription)
                cb?(nil)
            } else {
                cb?(characteristic.value)
            }
            return
        }

        guard let data = characteristic.value, data.count >= 1 else {
            NSLog("BLEManager: didUpdateValueFor - empty data")
            if let cb = responseCallback {
                responseCallback = nil
                commandInFlight = false
                currentCommand = nil
                cb(nil)
                if !commandInFlight { dequeueNext() }
            }
            return
        }

        let rxHex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        NSLog("BLEManager: didUpdateValueFor - data[%d]: %@, hasCallback=%d",
              data.count, rxHex, responseCallback != nil ? 1 : 0)
        Task { @MainActor in LogManager.shared.log("RX [\(rxHex)] (\(data.count)B)") }

        // Connection parameter update notification from firmware: [0xF0, interval_hi, interval_lo, latency, timeout_hi, timeout_lo]
        if data[0] == 0xF0 && data.count == 6 {
            let interval = (UInt16(data[1]) << 8) | UInt16(data[2])
            let latency = data[3]
            let timeout = (UInt16(data[4]) << 8) | UInt16(data[5])
            let intervalMs = String(format: "%.1f", Double(interval) * 1.25)
            let timeoutMs = timeout * 10
            NSLog("BLEManager: Param update: interval=%@ms, latency=%d, timeout=%dms", intervalMs, latency, timeoutMs)
            Task { @MainActor in LogManager.shared.log("BLE params updated: interval=\(intervalMs)ms latency=\(latency) timeout=\(timeoutMs)ms") }
            return
        }

        // PAIR button event notification: [0x34, status]
        //   0x00 = 30s timeout, 0x01 = pressed (ECDH starting), 0x02 = cancelled,
        //   0x03 = 指纹已通过，改等按键（仅登记第二台主机时出现）
        if data[0] == ImmurokCommand.pairButton.rawValue && data.count == 2 {
            let status = data[1]
            NSLog("BLEManager: Pair button event: 0x%02x", status)
            switch status {
            case 0x03:
                DispatchQueue.main.async { [weak self] in
                    self?.onPairFingerprintConfirmed?()
                }
            case 0x01:
                DispatchQueue.main.async { [weak self] in
                    self?.onPairButtonConfirmed?()
                }
            case 0x00:
                if let cb = self.pendingPairButton {
                    self.pendingPairButton = nil
                    cb(.failure(.buttonTimeout))
                }
            case 0x02:
                if let cb = self.pendingPairButton {
                    self.pendingPairButton = nil
                    cb(.failure(.buttonCancelled))
                }
            default:
                break
            }
            return
        }

        // Delayed PAIR_INIT result while waiting for the device button:
        // device sends [0x30][33B pubkey] only after the user presses the button.
        if data[0] == ImmurokCommand.pairInit.rawValue && data.count >= 34,
           let cb = self.pendingPairButton {
            self.pendingPairButton = nil
            cb(.success(data.subdata(in: 1..<34)))
            return
        }

        // Device refused to run ECDH: BLE connection params inadequate.
        // The device only starts ECDH after the button press, so this arrives
        // during the button wait rather than as the PAIR_INIT response. Left
        // unhandled it would fall through to the 45s outer timeout and be
        // reported as .buttonTimeout — telling users to press a button they
        // already pressed. Route it to the real reason instead.
        if data[0] == 0xE1 && data.count == 1, let cb = self.pendingPairButton {
            NSLog("BLEManager: ECDH rejected by device (0xE1, link params)")
            self.pendingPairButton = nil
            cb(.failure(.linkParams))
            return
        }

        // Long-press lock-screen request from device (no payload, single byte).
        // Independent of any preceding 0x21 — AppDelegate decides whether to
        // ignore (screen already locked) or execute (screen unlocked).
        if data[0] == 0x23 && data.count == 1 {
            NSLog("BLEManager: Lock request (long-press) received")
            Task { @MainActor in LogManager.shared.log("Lock request received (long press)") }
            DispatchQueue.main.async { [weak self] in
                self?.onLockRequest?()
            }
            return
        }

        // Check for signed fingerprint match notification (0x21)
        // Format: [0x21][page_id:2B LE][hmac:8B] = 11 bytes
        if data[0] == 0x21 && data.count == 11 {
            let (pageId, valid) = ImmurokSecurity.shared.verifyFingerprintMatch(data: data)

            if valid {
                NSLog("BLEManager: FP match verified - page_id=%d", pageId)
                Task { @MainActor in LogManager.shared.log("FP match verified OK id=\(pageId)") }

                // Send ACK
                self.sendAck()

                DispatchQueue.main.async { [weak self] in
                    self?.onFingerprintMatch?(pageId)
                }
            } else {
                NSLog("BLEManager: FP match HMAC verification FAILED")
                Task { @MainActor in LogManager.shared.log("FP match verify failed!") }
            }
            return
        }

        // Check for fingerprint gate result with data (OTP_GET returns [OK][6B code])
        if let dataCompletion = pendingGateDataCompletion, responseCallback == nil {
            if data[0] == 0x11 && data.count == 4 {
                // Fall through to enrollment status handler below
            } else if data.count == 1 && data[0] == ImmurokStatus.errFpNotMatch.rawValue {
                // Wrong finger. The device keeps the data gate OPEN and only
                // ends it (SEC_ERR_TIMEOUT 0x06) on the final failure / its own
                // timeout. Report the attempt and keep waiting — do NOT resolve
                // the completion here. (The old code's else-branch treated this
                // first 0x07 as terminal, dismissing the UI on attempt 1 while
                // the device kept blinking for attempts 2 and 3.)
                fpFailureCount += 1
                let remaining = 3 - fpFailureCount
                NSLog("BLEManager: FP gate(data): wrong finger (%d/3, %d left)", fpFailureCount, remaining)
                onFingerprintAttemptFailed?(remaining)
                return
            } else {
                // 0x00 (+data) = success; 0x06 / anything else = terminal failure.
                let success = data[0] == ImmurokStatus.ok.rawValue
                NSLog("BLEManager: FP gate data result: 0x%02x (%@)", data[0], success ? "OK" : "failed")
                pendingGateDataCompletion = nil
                releaseGateHold { dataCompletion(success ? data : nil) }
                return
            }
        }

        // Check for fingerprint gate result (after WAIT_FP for delete/enroll/setPassword)
        // Device executes cached command after FP match and sends result notification
        if let gateCompletion = pendingGateCompletion, responseCallback == nil {
            // Enrollment status (0x11, 4 bytes) should fall through to enrollment handler
            if data[0] == 0x11 && data.count == 4 {
                // Fall through to enrollment status handler below
            } else if data[0] == 0x10 {
                // FP approved, operation in progress — reset gate timeout for ECDSA
                NSLog("BLEManager: FP gate: fingerprint approved, resetting timeout for operation")
                // Cancel old gate timeout and start a 15s operation timeout
                // (ECDSA ~2s + param update wait up to 10s + margin)
                gateGeneration &+= 1
                let myGen = gateGeneration
                queue.asyncAfter(deadline: .now() + 15.0) { [weak self] in
                    guard let self = self, self.gateGeneration == myGen else { return }
                    if let cb = self.pendingGateCompletion {
                        NSLog("BLEManager: FP gate operation timeout (post-approve)")
                        self.pendingGateCompletion = nil
                        self.releaseGateHold { cb(false) }
                    }
                }
                onFingerprintGateApproved?()
                return
            } else if data[0] == ImmurokStatus.errFpNotMatch.rawValue {
                fpFailureCount += 1
                let remaining = 3 - fpFailureCount
                NSLog("BLEManager: FP gate: wrong finger (%d/3, %d left)", fpFailureCount, remaining)
                onFingerprintAttemptFailed?(remaining)
                if fpFailureCount >= 3 {
                    NSLog("BLEManager: FP gate: max failures reached, denying")
                    pendingGateCompletion = nil
                    releaseGateHold { gateCompletion(false) }
                }
                return
            } else {
                let success = data[0] == ImmurokStatus.ok.rawValue
                NSLog("BLEManager: FP gate result: 0x%02x (%@)", data[0], success ? "OK" : "failed")
                if data[0] == 0xE1 {
                    // 设备长 ECC 门在 5s 内没谈到足够的 supervision timeout,拒绝签名
                    // (多见于刚重连时 macOS 压低 timeout 的 override 窗口)。SSH agent
                    // 协议只能回失败码,ssh 客户端固定显示 "agent refused operation",
                    // 无法追加文字;这里补记可诊断的原因与重试建议到 immurok.log。
                    Task { @MainActor in
                        LogManager.shared.log("签名被拒：BLE 链路参数不足(设备 0xE1)——多为刚重连时 macOS 压低了 supervision timeout。约 30 秒后重试即可 (agent refused operation, please try again ~30s later)")
                    }
                }
                pendingGateCompletion = nil
                releaseGateHold { gateCompletion(success) }
                return
            }
        }

        // Check for AUTH_OK notification (fingerprint matched for AUTH_REQUEST)
        // Format: [0x00] = 1 byte OK
        if data.count == 1 && data[0] == ImmurokStatus.ok.rawValue && responseCallback == nil {
            NSLog("BLEManager: Received AUTH_OK notification")
            Task { @MainActor in LogManager.shared.log("AUTH passed") }
            // Release queue hold (taken when AUTH_REQUEST returned WAIT_FP)
            // so a queued command (e.g. battery refresh) can run.
            // fingerprintResultCompletion is fired via onUnlockResult on the
            // main thread — must NOT clear it here or the user callback
            // never fires (regression: 1.11 broke active FP verification by
            // clearing it pre-emptively).
            if fingerprintResultCompletion != nil {
                releaseAuthHold()
            }
            DispatchQueue.main.async { [weak self] in
                self?.onUnlockResult?(true)
            }
            return
        }

        // Check for AUTH_FAILED notification (fingerprint not matched)
        // Format: [0x07] = 1 byte FP_NOT_MATCH — device keeps waiting, don't end operation
        if data.count == 1 && data[0] == ImmurokStatus.errFpNotMatch.rawValue && responseCallback == nil {
            fpFailureCount += 1
            let remaining = 3 - fpFailureCount
            NSLog("BLEManager: Wrong finger during AUTH (%d/3, %d left)", fpFailureCount, remaining)
            onFingerprintAttemptFailed?(remaining)
            if fpFailureCount >= 3 {
                NSLog("BLEManager: AUTH: max failures reached, denying")
                if fingerprintResultCompletion != nil {
                    releaseAuthHold()
                }
                DispatchQueue.main.async { [weak self] in
                    self?.onUnlockResult?(false)
                }
            }
            return
        }

        // Terminal AUTH failure. After the first two wrong fingers (0x07 above)
        // the device ends the gate on the third failure — or on its own 25s gate
        // timeout — by sending SEC_ERR_TIMEOUT (0x06) and powering the sensor
        // off. Resolve the local wait now instead of hanging until our 30s
        // timeout (the bug: the UI kept counting down while the device had
        // already stopped blinking).
        if data.count == 1 && data[0] == ImmurokStatus.errTimeout.rawValue
            && responseCallback == nil && fingerprintResultCompletion != nil {
            NSLog("BLEManager: AUTH terminal failure (device ended gate)")
            releaseAuthHold()
            DispatchQueue.main.async { [weak self] in
                self?.onUnlockResult?(false)
            }
            return
        }

        // Check for enrollment status notification (0x11)
        // Format: [0x11, status, current, total] = exactly 4 bytes
        // Note: UNLOCK response is [0x11, nonce...] = 9 bytes, so use exact length check
        if data[0] == 0x11 && data.count == 4 {
            let status = data[1]
            let current = Int(data[2])
            let total = Int(data[3])
            NSLog("BLEManager: Enrollment status: %d, progress: %d/%d", status, current, total)

            // If a pending responseCallback IS waiting for ENROLL_START's
            // ACK, complete it with success — device's first status frame
            // doubles as that ack. ONLY hijack the callback when the
            // in-flight command really is .enrollStart; firmware now also
            // emits [0x11, WAITING, capture, total] as an enrollment-window
            // keep-alive every ~3s, and the user can issue an unrelated
            // command (GET_STATUS, FP_LIST, battery refresh) during enroll —
            // those callbacks would otherwise be completed with bogus
            // OK-shaped data and report fake success.
            if let cb = responseCallback, currentCommand == .enrollStart {
                NSLog("BLEManager: Completing pending ENROLL_START callback (first enroll status)")
                responseCallback = nil
                commandInFlight = false
                currentCommand = nil
                cb(Data([0x00]))  // Return OK status
                if !commandInFlight { dequeueNext() }
            }

            let event: EnrollEvent
            switch status {
            case 0x00: event = .waiting
            case 0x01: event = .captured
            case 0x02: event = .processing
            case 0x03: event = .liftFinger
            case 0x04: event = .complete
            case 0x06: event = .overlap
            case 0xFD, 0xFE, 0xFF: event = .failed
            default:
                if current == total && total > 0 {
                    event = .complete
                } else {
                    event = .waiting
                }
            }

            DispatchQueue.main.async { [weak self] in
                self?.onEnrollStatus?(event, current, total)
            }
            return
        }

        // Normal response handling
        // Important: clear callback and in-flight flag BEFORE calling it,
        // so chained callbacks can sendCommand synchronously
        if let callback = responseCallback {
            NSLog("BLEManager: Calling responseCallback with data")
            responseCallback = nil
            commandInFlight = false
            currentCommand = nil
            callback(data)
            // If the callback armed an FP gate (KEY_SIGN/KEY_GENERATE/
            // KEY_OTP_GET/AUTH_REQUEST got WAIT_FP back), keep the queue
            // held until the gate completes — otherwise a queued command
            // (e.g. battery refresh GET_STATUS) executes during the gate
            // window, sets a new responseCallback, and the device's
            // gate/auth notifications (0x10 approve / 0x07 wrong-finger /
            // OK-result) get misrouted to that command's callback.
            // Released by releaseGateHold() at gate-completion sites and by
            // releaseAuthHoldIfNeeded() at AUTH_OK/FAIL/timeout sites.
            if pendingGateCompletion != nil
                || pendingGateDataCompletion != nil
                || fingerprintResultCompletion != nil {
                commandInFlight = true
            }
            // If callback chained a new command, commandInFlight is already true again.
            // Otherwise, dequeue next waiting command.
            if !commandInFlight {
                dequeueNext()
            }
        } else {
            NSLog("BLEManager: No responseCallback for data")
        }
    }
}
