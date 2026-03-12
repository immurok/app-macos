/*
 * BLEManager.swift - BLE communication with immurok device
 *
 * Connects to ESP32H2 via custom GATT service for authentication
 */

import AppKit
import CoreBluetooth
import Foundation

// MARK: - BLE UUIDs

let IMMUROK_SERVICE_UUID = CBUUID(string: "12340010-0000-1000-8000-00805f9b34fb")
let IMMUROK_CMD_CHAR_UUID = CBUUID(string: "12340011-0000-1000-8000-00805f9b34fb")
let IMMUROK_RSP_CHAR_UUID = CBUUID(string: "12340012-0000-1000-8000-00805f9b34fb")

// Device Information Service (standard BLE 0x180A)
let DEVICE_INFO_SERVICE_UUID = CBUUID(string: "180A")
let FIRMWARE_REV_CHAR_UUID = CBUUID(string: "2A26")

// OTA Service
let OTA_SERVICE_UUID = CBUUID(string: "FEE0")
let OTA_CHAR_UUID = CBUUID(string: "FEE1")

// MARK: - Commands

enum ImmurokCommand: UInt8 {
    case getStatus = 0x01
    case enrollStart = 0x10
    case deleteFP = 0x12
    case fpList = 0x13
    case fpMatchAck = 0x22
    case pairInit = 0x30
    case pairConfirm = 0x31
    case pairStatus = 0x32
    case authRequest = 0x33
    case factoryReset = 0x36
    case gateCancel = 0x37
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
    case errBusy = 0xFD
    case errInvalidParam = 0xFE
    case errUnknown = 0xFF
}

// Enrollment status notifications (from device)
// Must match firmware fingerprint.h: FP_ENROLL_WAITING=0, CAPTURED=1, PROCESSING=2, LIFT_FINGER=3
enum EnrollEvent: UInt8 {
    case waiting = 0x00
    case captured = 0x01
    case processing = 0x02
    case liftFinger = 0x03
    case complete = 0x04
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

    // MARK: - Callbacks

    var onDeviceConnected: ((String) -> Void)?
    var onDeviceDisconnected: (() -> Void)?
    var onUnlockResult: ((Bool) -> Void)?
    var onFingerprintMatch: ((UInt16) -> Void)?
    var onPairingCompleted: ((Bool) -> Void)?
    var onEnrollStatus: ((EnrollEvent, Int, Int) -> Void)?
    var onBluetoothStatusChanged: ((BluetoothAuthStatus) -> Void)?
    var onFirmwareVersionRead: ((String) -> Void)?
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
    private var fpFailureCount = 0  // FP_NOT_MATCH counter, max 2 then deny
    private var otaReadCallback: ((Data?) -> Void)?
    private var otaWriteReadyCallback: (() -> Void)?
    private var reconnectTimer: DispatchSourceTimer?
    private var resubscribeTimer: DispatchSourceTimer?
    private var napActivity: NSObjectProtocol?
    private var displaySleeping = false

    private let queue = DispatchQueue(label: "com.immurok.ble", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()

    // Command queue — serializes BLE command/response pairs
    private var commandInFlight = false
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

            // System wake (including DarkWake) - re-subscribe GATT notifications
            nc.addObserver(self, selector: #selector(self.onSystemWake),
                           name: NSWorkspace.didWakeNotification, object: nil)
        }
    }

    @objc private func onScreenDidSleep() {
        NSLog("BLEManager: Screen did sleep")
        Task { @MainActor in LogManager.shared.log("屏幕已休眠") }
        displaySleeping = true
        stopReconnectTimer()
        startResubscribeTimer()
    }

    @objc private func onScreenDidWake() {
        NSLog("BLEManager: Screen did wake (deviceState.isConnected=%d)", deviceState.isConnected ? 1 : 0)
        Task { @MainActor in LogManager.shared.log("屏幕已唤醒") }
        displaySleeping = false
        stopResubscribeTimer()
        queue.async { [weak self] in
            guard let self = self else { return }
            self.resubscribeNotifications()
            if !self.deviceState.isConnected {
                self.deviceState = .disconnected
                self.startReconnectTimer()
            }
        }
    }

    @objc private func onSystemWake() {
        NSLog("BLEManager: System wake (displaySleeping=%d)", displaySleeping ? 1 : 0)
        queue.async { [weak self] in
            self?.resubscribeNotifications()
        }
    }

    private func resubscribeNotifications() {
        guard let p = peripheral, p.state == .connected,
              let rspChar = rspCharacteristic, rspChar.properties.contains(.notify) else {
            return
        }
        NSLog("BLEManager: Re-subscribing RSP notifications")
        Task { @MainActor in LogManager.shared.log("重新订阅 GATT 通知") }
        p.setNotifyValue(true, for: rspChar)
    }

    private func startResubscribeTimer() {
        stopResubscribeTimer()
        // Prevent App Nap so the timer keeps firing during screen sleep
        napActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "BLE GATT resubscription during screen sleep")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10.0, repeating: 10.0)
        timer.setEventHandler { [weak self] in
            self?.resubscribeNotifications()
        }
        resubscribeTimer = timer
        timer.resume()
    }

    private func stopResubscribeTimer() {
        resubscribeTimer?.cancel()
        resubscribeTimer = nil
        if let activity = napActivity {
            ProcessInfo.processInfo.endActivity(activity)
            napActivity = nil
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

        // Already connecting (GATT discovery in progress), don't re-trigger
        if deviceState == .connecting {
            return
        }

        deviceState = .connecting
        NSLog("BLEManager: Looking for immurok device...")
        Task { @MainActor in LogManager.shared.log("BLE 扫描中...") }

        // Find already connected devices by immurok service UUID
        // Key: Use the custom service UUID, not HID service UUID!
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

        // Not found, start scanning for all devices (filter by name)
        NSLog("BLEManager: No connected device found, scanning...")
        centralManager.scanForPeripherals(withServices: nil, options: nil)
    }

    func disconnect() {
        if let peripheral = peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    /// Request unlock via AUTH_REQUEST - device waits for fingerprint
    /// Cancel a pending fingerprint-gated command on the device
    func cancelGate() {
        guard deviceState.isConnected else { return }
        NSLog("BLEManager: Sending GATE_CANCEL")
        sendCommand(.gateCancel) { _ in }
    }

    func requestUnlock(timeout: TimeInterval = 30.0, completion: @escaping (Bool) -> Void) {
        guard deviceState.isConnected else {
            NSLog("BLEManager: Not connected")
            completion(false)
            return
        }

        NSLog("BLEManager: Requesting unlock (AUTH_REQUEST)...")

        sendCommand(.authRequest) { [weak self] response in
            guard let self = self else {
                completion(false)
                return
            }
            guard let response = response, response.count >= 1 else {
                NSLog("BLEManager: No AUTH_REQUEST response")
                completion(false)
                return
            }

            let status = response[0]
            if status == ImmurokStatus.waitFingerprint.rawValue {
                NSLog("BLEManager: Waiting for fingerprint...")
                self.waitForFingerprintResult(timeout: timeout, completion: completion)
            } else {
                NSLog("BLEManager: AUTH_REQUEST failed: 0x%02x", status)
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
            NSLog("BLEManager: Fingerprint timeout")
            self?.fingerprintResultCompletion?(false)
            self?.onUnlockResult = previousCallback
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

    /// Start ECDH pairing with device
    func startPairing(completion: @escaping (Bool) -> Void) {
        guard deviceState.isConnected else {
            completion(false)
            return
        }

        NSLog("BLEManager: Starting ECDH pairing...")

        // Step 1: Send PAIR_INIT (no payload)
        sendCommand(.pairInit, timeout: 15.0) { [weak self] response in
            // Response: [0x30][compressed_pubkey:33B] or [0x30][error:1B]
            guard let self = self, let response = response, response.count >= 2 else {
                NSLog("BLEManager: PAIR_INIT no response")
                completion(false)
                return
            }

            if response[0] != ImmurokCommand.pairInit.rawValue {
                NSLog("BLEManager: PAIR_INIT unexpected response: 0x%02x", response[0])
                completion(false)
                return
            }

            if response.count < 34 {
                // Error response: [0x30][error_code]
                NSLog("BLEManager: PAIR_INIT error: 0x%02x", response[1])
                completion(false)
                return
            }

            // Got device compressed pubkey (33 bytes at offset 1)
            let devicePubKey = response[1..<34]
            NSLog("BLEManager: Got device pubkey (prefix=0x%02x)", devicePubKey[1])

            // Generate App key pair, get compressed pubkey
            let security = ImmurokSecurity.shared
            let appPubKey = security.startPairing()

            // Step 2: Send PAIR_CONFIRM with App compressed pubkey
            let payload = [UInt8](appPubKey)
            self.sendCommand(.pairConfirm, payload: payload) { response in
                // Response: [0x31][status:1B]
                guard let response = response, response.count >= 2 else {
                    NSLog("BLEManager: PAIR_CONFIRM no response")
                    completion(false)
                    return
                }

                if response[0] != ImmurokCommand.pairConfirm.rawValue {
                    NSLog("BLEManager: PAIR_CONFIRM unexpected: 0x%02x", response[0])
                    completion(false)
                    return
                }

                if response[1] != ImmurokStatus.ok.rawValue {
                    NSLog("BLEManager: PAIR_CONFIRM failed: 0x%02x", response[1])
                    completion(false)
                    return
                }

                // Device pairing succeeded, now derive shared key on App side
                let success = security.completePairing(deviceCompressedPubKey: Data(devicePubKey))
                NSLog("BLEManager: Pairing %@", success ? "succeeded" : "failed (App-side)")
                completion(success)

                DispatchQueue.main.async { [weak self] in
                    self?.onPairingCompleted?(success)
                }
            }
        }
    }

    /// Get fingerprint bitmap (which slots have fingerprints)
    /// Returns bitmap where bit N = 1 means slot N has a fingerprint
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
            if response.count >= 7 {
                firmwareVersion = "\(response[4]).\(response[5]).\(response[6])"
            } else {
                firmwareVersion = nil
            }
            NSLog("BLEManager: Status: bitmap=0x%02x, paired=%d, battery=%@, fw=%@", bitmap, isPaired ? 1 : 0, batteryLevel.map { "\($0)%" } ?? "n/a", firmwareVersion ?? "n/a")
            if let version = firmwareVersion {
                DispatchQueue.main.async {
                    self?.onFirmwareVersionRead?(version)
                }
            }
            completion(bitmap, isPaired, batteryLevel, firmwareVersion)
        }
    }

    /// Send factory reset command
    func factoryReset(completion: @escaping (Bool) -> Void) {
        guard deviceState.isConnected else {
            completion(false)
            return
        }

        sendCommand(.factoryReset) { [weak self] response in
            guard let response = response, response.count >= 1 else {
                completion(false)
                return
            }
            let status = response[0]
            if status == ImmurokStatus.ok.rawValue {
                completion(true)
            } else if status == ImmurokStatus.waitFingerprint.rawValue {
                NSLog("BLEManager: Factory reset waiting for FP gate")
                self?.pendingGateCompletion = completion
                self?.startGateTimeout()
                DispatchQueue.main.async { NotificationCenter.default.post(name: BLEManager.fingerprintGateRequiredNotification, object: nil) }
            } else {
                completion(false)
            }
        }
    }

    // MARK: - Keystore Methods

    /// Get entry count for a key category
    func getKeyCount(cat: KeystoreCategory, completion: @escaping (Int) -> Void) {
        guard deviceState.isConnected else {
            completion(0)
            return
        }

        sendCommand(.keyCount, payload: [cat.rawValue]) { response in
            guard let response = response, response.count >= 2,
                  response[0] == ImmurokStatus.ok.rawValue else {
                completion(0)
                return
            }
            completion(Int(response[1]))
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

    /// Read only the name (first 32 bytes) of a key entry via single KEY_READ
    /// Uses a single BLE command — safe against responseCallback races
    func readKeyEntryName(cat: KeystoreCategory, idx: UInt8, completion: @escaping (String?) -> Void) {
        guard deviceState.isConnected else {
            completion(nil)
            return
        }

        sendCommand(.keyRead, payload: [cat.rawValue, idx, 0]) { response in
            // Response: [OK][total_lo:1B][off:1B][data...<=59B]
            // total_lo may be 0 for 256B entries (uint8 truncation) — we only need data bytes
            guard let response = response, response.count > 3,
                  response[0] == ImmurokStatus.ok.rawValue else {
                completion(nil)
                return
            }

            let chunkData = response.subdata(in: 3..<response.count)
            let nameLen = min(32, chunkData.count)
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
            if let cb = self.pendingGateDataCompletion {
                NSLog("BLEManager: FP gate data timeout")
                self.pendingGateDataCompletion = nil
                cb(nil)
            }
            if let cb = self.pendingGateCompletion {
                NSLog("BLEManager: FP gate timeout")
                self.pendingGateCompletion = nil
                cb(false)
            }
        }
    }

    // MARK: - Private Methods

    /// Send ACK for fingerprint match notification (fire-and-forget)
    private func sendAck() {
        guard let cmdChar = cmdCharacteristic, let peripheral = peripheral else {
            NSLog("BLEManager: Cannot send ACK - not connected")
            return
        }

        // [cmd=0x22][len=0x00]
        let data = Data([ImmurokCommand.fpMatchAck.rawValue, 0x00])
        peripheral.writeValue(data, for: cmdChar, type: .withResponse)
        NSLog("BLEManager: ACK sent")
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
        Task { @MainActor in LogManager.shared.log("BLE 已连接: \(peripheral.name ?? "unknown")") }
        peripheral.discoverServices([IMMUROK_SERVICE_UUID, OTA_SERVICE_UUID, DEVICE_INFO_SERVICE_UUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        NSLog("BLEManager: Disconnected (displaySleeping=%d)", displaySleeping)
        Task { @MainActor in LogManager.shared.log("BLE 已断开") }

        responseCallback?(nil)
        responseCallback = nil
        commandInFlight = false
        otaReadCallback?(nil)
        otaReadCallback = nil
        otaCharacteristic = nil

        // Flush command queue
        let pending = commandQueue
        commandQueue.removeAll()
        for item in pending { item.completion(nil) }

        // Cancel pending fingerprint gate
        if let cb = pendingGateCompletion {
            pendingGateCompletion = nil
            cb(false)
        }

        deviceState = .disconnected
        onDeviceDisconnected?()

        if !displaySleeping {
            startReconnectTimer()
        } else {
            NSLog("BLEManager: Screen locked, defer reconnect until unlock")
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
            }
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
                Task { @MainActor in LogManager.shared.log("GATT 就绪: \(name)") }
                onDeviceConnected?(name)
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
        let name = peripheral.name ?? "immurok"
        deviceState = .connected(name: name)

        NSLog("BLEManager: Ready - %@", name)
        Task { @MainActor in LogManager.shared.log("GATT 就绪: \(name)") }
        onDeviceConnected?(name)
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
                cb(nil)
                if !commandInFlight { dequeueNext() }
            }
            return
        }

        let rxHex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        NSLog("BLEManager: didUpdateValueFor - data[%d]: %@, hasCallback=%d",
              data.count, rxHex, responseCallback != nil ? 1 : 0)
        Task { @MainActor in LogManager.shared.log("RX [\(rxHex)] (\(data.count)B)") }

        // Check for signed fingerprint match notification (0x21)
        // Format: [0x21][page_id:2B LE][hmac:8B] = 11 bytes
        if data[0] == 0x21 && data.count == 11 {
            let (pageId, valid) = ImmurokSecurity.shared.verifyFingerprintMatch(data: data)

            if valid {
                NSLog("BLEManager: FP match verified - page_id=%d", pageId)
                Task { @MainActor in LogManager.shared.log("FP匹配验签OK id=\(pageId)") }

                // Send ACK
                self.sendAck()

                DispatchQueue.main.async { [weak self] in
                    self?.onFingerprintMatch?(pageId)
                }
            } else {
                NSLog("BLEManager: FP match HMAC verification FAILED")
                Task { @MainActor in LogManager.shared.log("FP匹配验签失败！") }
            }
            return
        }

        // Check for fingerprint gate result with data (OTP_GET returns [OK][6B code])
        if let dataCompletion = pendingGateDataCompletion, responseCallback == nil {
            if data[0] == 0x11 && data.count == 4 {
                // Fall through to enrollment status handler below
            } else {
                let success = data[0] == ImmurokStatus.ok.rawValue
                NSLog("BLEManager: FP gate data result: 0x%02x (%@)", data[0], success ? "OK" : "failed")
                pendingGateDataCompletion = nil
                dataCompletion(success ? data : nil)
                return
            }
        }

        // Check for fingerprint gate result (after WAIT_FP for delete/enroll/setPassword/factoryReset)
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
                        cb(false)
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
                    gateCompletion(false)
                }
                return
            } else {
                let success = data[0] == ImmurokStatus.ok.rawValue
                NSLog("BLEManager: FP gate result: 0x%02x (%@)", data[0], success ? "OK" : "failed")
                pendingGateCompletion = nil
                gateCompletion(success)
                return
            }
        }

        // Check for AUTH_OK notification (fingerprint matched for AUTH_REQUEST)
        // Format: [0x00] = 1 byte OK
        if data.count == 1 && data[0] == ImmurokStatus.ok.rawValue && responseCallback == nil {
            NSLog("BLEManager: Received AUTH_OK notification")
            Task { @MainActor in LogManager.shared.log("AUTH 认证通过") }
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
                DispatchQueue.main.async { [weak self] in
                    self?.onUnlockResult?(false)
                }
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

            // If there's a pending responseCallback (waiting for ENROLL_START ACK),
            // complete it with success since we're receiving enrollment updates
            if let cb = responseCallback {
                NSLog("BLEManager: Completing pending callback (enrollment started)")
                responseCallback = nil
                commandInFlight = false
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
            callback(data)
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
