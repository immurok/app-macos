/*
 * PAMSocketServer.swift - Unix socket server for PAM module communication
 *
 * Listens on ~/.immurok/pam.sock for authentication requests from pam_immurok
 * Protocol: "AUTH:username:service" -> "OK" or "DENY"
 */

import Foundation

class PAMSocketServer {
    private let socketPath: String
    private var serverSocket: Int32 = -1
    private var isRunning = false
    private let bleManager: BLEManager

    // For proactive fingerprint approval
    private var pendingRequestSemaphore: DispatchSemaphore?
    private var pendingRequestApproved = false
    private let pendingLock = NSLock()

    // Pre-authorization: auto-approve PAM requests within a time window
    private var preAuthExpiry: Date?
    private var preAuthService: String?  // nil = any service
    private let preAuthLock = NSLock()

    // Enrollment status tracking
    private var enrollStatus: EnrollEvent = .waiting
    private var enrollCurrent: Int = 0
    private var enrollTotal: Int = 0
    private var enrollActive: Bool = false
    private let enrollLock = NSLock()

    init(bleManager: BLEManager) {
        self.bleManager = bleManager
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        socketPath = "\(home)/.immurok/pam.sock"
    }

    func hasPendingRequest() -> Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pendingRequestSemaphore != nil
    }

    func approvePendingRequest() {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        if let sem = pendingRequestSemaphore {
            pendingRequestApproved = true
            sem.signal()
        }
    }

    // MARK: - Pre-Authorization

    /// Set pre-authorization window (auto-approve PAM requests within duration)
    /// - Parameters:
    ///   - duration: Time window in seconds
    ///   - service: If non-nil, only consume for this PAM service
    func setPreAuthorization(duration: TimeInterval = 3.0, service: String? = nil) {
        preAuthLock.lock()
        defer { preAuthLock.unlock() }
        preAuthExpiry = Date().addingTimeInterval(duration)
        preAuthService = service
        if let s = service {
            NSLog("PAMSocketServer: Pre-authorization set for %.1f seconds (service=%@)", duration, s)
        } else {
            NSLog("PAMSocketServer: Pre-authorization set for %.1f seconds", duration)
        }
    }

    /// Check if pre-authorization is active and consume it
    private func consumePreAuthorization(service: String) -> Bool {
        preAuthLock.lock()
        defer { preAuthLock.unlock() }
        guard let expiry = preAuthExpiry else { return false }
        if Date() < expiry {
            // If a specific service is required, check it matches
            if let required = preAuthService, required != service {
                return false  // Service mismatch — don't consume
            }
            preAuthExpiry = nil  // Consume the pre-auth
            preAuthService = nil
            NSLog("PAMSocketServer: Pre-authorization consumed (service=%@)", service)
            return true
        }
        preAuthExpiry = nil  // Expired
        preAuthService = nil
        return false
    }

    /// Check if a PAM service is enabled in app settings
    private func isServiceEnabled(_ service: String) -> Bool {
        switch service {
        case "sudo", "sudo_local":
            return UserDefaults.standard.bool(forKey: "immurok.sudoAuthEnabled")
        case "authorization":
            return UserDefaults.standard.bool(forKey: "immurok.authorizationEnabled")
        default:
            // Unknown services: allow if any PAM feature is enabled
            return UserDefaults.standard.bool(forKey: "immurok.sudoAuthEnabled")
                || UserDefaults.standard.bool(forKey: "immurok.authorizationEnabled")
        }
    }

    // MARK: - Enrollment Status

    func updateEnrollStatus(event: EnrollEvent, current: Int, total: Int) {
        enrollLock.lock()
        defer { enrollLock.unlock() }
        enrollStatus = event
        enrollCurrent = current
        enrollTotal = total
        NSLog("PAMSocketServer: Enroll status updated: event=%d, progress=%d/%d", event.rawValue, current, total)
    }

    func startEnrollment() {
        enrollLock.lock()
        defer { enrollLock.unlock() }
        enrollActive = true
        enrollStatus = .waiting
        enrollCurrent = 0
        enrollTotal = 6  // Match firmware ENROLL_CAPTURE_COUNT
    }

    func endEnrollment() {
        enrollLock.lock()
        defer { enrollLock.unlock() }
        enrollActive = false
    }

    func start() throws {
        // Ensure ~/.immurok/ directory exists
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Remove existing socket file
        unlink(socketPath)

        // Create socket
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw PAMSocketError.socketCreationFailed
        }

        // Bind to socket path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                _ = strcpy(pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { $0 }, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult >= 0 else {
            close(serverSocket)
            throw PAMSocketError.bindFailed
        }

        // Owner-only access; PAM runs as root which bypasses file permissions
        chmod(socketPath, 0o600)

        // Listen for connections
        guard listen(serverSocket, 5) >= 0 else {
            close(serverSocket)
            throw PAMSocketError.listenFailed
        }

        isRunning = true
        NSLog("PAMSocketServer: Listening on %@", socketPath)

        // Accept loop in background
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop()
        }
    }

    private func acceptLoop() {
        while isRunning {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(serverSocket, sockaddrPtr, &clientLen)
                }
            }

            if clientSocket < 0 {
                if isRunning {
                    NSLog("PAMSocketServer: Accept failed")
                }
                continue
            }

            // Handle each client in its own thread
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(clientSocket)
            }
        }
    }

    private func handleClient(_ clientSocket: Int32) {
        defer { close(clientSocket) }

        // Verify peer identity: only allow root (UID 0) or current user
        var euid: uid_t = 0
        var egid: gid_t = 0
        guard getpeereid(clientSocket, &euid, &egid) == 0 else {
            NSLog("PAMSocketServer: getpeereid() failed")
            return
        }
        let myUid = getuid()
        guard euid == 0 || euid == myUid else {
            NSLog("PAMSocketServer: Rejected UID %d (expected 0 or %d)", euid, myUid)
            return
        }

        // Set receive timeout (5 seconds)
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Read request
        var buffer = [CChar](repeating: 0, count: 256)
        let n = recv(clientSocket, &buffer, buffer.count - 1, 0)

        guard n > 0 else {
            NSLog("PAMSocketServer: No data received")
            return
        }

        let request = String(cString: buffer)
        NSLog("PAMSocketServer: Received: %@", request)

        // Parse request
        let parts = request.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count >= 1 else {
            NSLog("PAMSocketServer: Empty request")
            sendResponse(clientSocket, response: "ERROR")
            return
        }

        let command = String(parts[0])

        // Handle different commands
        switch command {
        case "STATUS":
            handleStatus(clientSocket)
            return
        case "FP":
            handleFingerprint(clientSocket, parts: Array(parts))
            return
        case "OTA":
            handleOTASession(clientSocket, firstParts: Array(parts))
            return
        case "AUTH":
            break  // Continue to auth handling below
        default:
            NSLog("PAMSocketServer: Unknown command: %@", command)
            sendResponse(clientSocket, response: "ERROR")
            return
        }

        // AUTH command handling
        guard parts.count >= 2 else {
            NSLog("PAMSocketServer: Invalid AUTH format")
            sendResponse(clientSocket, response: "ERROR")
            return
        }

        let user = String(parts[1])
        let service = parts.count >= 3 ? String(parts[2]) : "unknown"

        NSLog("PAMSocketServer: Auth request for user=%@, service=%@", user, service)

        // Check if this service is enabled in app settings
        if !isServiceEnabled(service) {
            NSLog("PAMSocketServer: Service '%@' is disabled, denying", service)
            sendResponse(clientSocket, response: "DENY")
            return
        }

        // Check pre-authorization first (user already verified fingerprint)
        if consumePreAuthorization(service: service) {
            NSLog("PAMSocketServer: Auth approved via pre-authorization for %@", user)
            sendResponse(clientSocket, response: "OK")
            return
        }

        // Check BLE device connection
        guard bleManager.deviceState.isConnected else {
            NSLog("PAMSocketServer: BLE device not connected")
            sendResponse(clientSocket, response: "DENY")
            return
        }

        // Set up pending request for proactive fingerprint approval
        let semaphore = DispatchSemaphore(value: 0)
        pendingLock.lock()
        pendingRequestSemaphore = semaphore
        pendingRequestApproved = false
        pendingLock.unlock()

        // Hook fingerprint failure to send RETRY to PAM module
        let previousAttemptFailed = bleManager.onFingerprintAttemptFailed
        bleManager.onFingerprintAttemptFailed = { [weak self] remaining in
            self?.sendResponse(clientSocket, response: "RETRY:\(remaining)")
        }

        // Request unlock from device (wait for fingerprint)
        var authResult = false
        var isTimeout = false
        let startTime = Date()

        bleManager.requestUnlock(timeout: 30.0) { [weak self] success in
            self?.pendingLock.lock()
            if self?.pendingRequestApproved == true {
                // Already approved by proactive fingerprint match
                authResult = true
            } else {
                authResult = success
                // Fingerprint mismatch responds in <3s; timeout takes ~30s
                if !success {
                    isTimeout = Date().timeIntervalSince(startTime) >= 25.0
                }
            }
            self?.pendingRequestSemaphore = nil
            self?.pendingLock.unlock()
            semaphore.signal()
        }

        // Wait for result (with timeout)
        let waitResult = semaphore.wait(timeout: .now() + 35)
        bleManager.onFingerprintAttemptFailed = previousAttemptFailed

        pendingLock.lock()
        pendingRequestSemaphore = nil
        let approved = pendingRequestApproved
        pendingRequestApproved = false
        pendingLock.unlock()

        if waitResult == .timedOut && !approved {
            NSLog("PAMSocketServer: Auth timeout waiting for device")
            sendResponse(clientSocket, response: "TIMEOUT")
            return
        }

        // Check if approved by proactive fingerprint
        if approved {
            authResult = true
        }

        let response: String
        if authResult {
            response = "OK"
        } else if isTimeout {
            response = "TIMEOUT"
        } else {
            response = "DENY"
        }

        NSLog("PAMSocketServer: Auth result for %@: %@", user, response)
        sendResponse(clientSocket, response: response)
    }

    private func sendResponse(_ socket: Int32, response: String) {
        _ = response.withCString { ptr in
            send(socket, ptr, strlen(ptr), 0)
        }
    }

    // MARK: - Status Command

    private func handleStatus(_ clientSocket: Int32) {
        let connected = bleManager.deviceState.isConnected
        let deviceName: String
        if case .connected(let name) = bleManager.deviceState {
            deviceName = name
        } else {
            deviceName = ""
        }

        let response = "STATUS:\(connected ? "1" : "0"):\(deviceName)"
        NSLog("PAMSocketServer: Status response: %@", response)
        sendResponse(clientSocket, response: response)
    }

    // MARK: - Fingerprint Commands

    private func handleFingerprint(_ clientSocket: Int32, parts: [Substring]) {
        guard parts.count >= 2 else {
            NSLog("PAMSocketServer: Invalid FP command format")
            sendResponse(clientSocket, response: "ERROR:INVALID_FORMAT")
            return
        }

        let subCommand = String(parts[1])

        switch subCommand {
        case "ENROLL":
            handleEnroll(clientSocket, parts: parts)
        case "DELETE":
            handleDelete(clientSocket, parts: parts)
        case "LIST":
            handleList(clientSocket)
        case "STATUS":
            handleEnrollStatus(clientSocket)
        default:
            NSLog("PAMSocketServer: Unknown FP subcommand: %@", subCommand)
            sendResponse(clientSocket, response: "ERROR:UNKNOWN_COMMAND")
        }
    }

    private func handleEnroll(_ clientSocket: Int32, parts: [Substring]) {
        guard parts.count >= 3, let slotId = UInt8(String(parts[2])) else {
            sendResponse(clientSocket, response: "ERROR:INVALID_SLOT")
            return
        }

        guard bleManager.deviceState.isConnected else {
            sendResponse(clientSocket, response: "ERROR:NOT_CONNECTED")
            return
        }

        NSLog("PAMSocketServer: Starting enrollment for slot %d", slotId)

        // Mark enrollment as active
        startEnrollment()

        let semaphore = DispatchSemaphore(value: 0)
        var success = false

        bleManager.startEnrollment(slotId: slotId) { result in
            success = result
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 5)

        if success {
            sendResponse(clientSocket, response: "OK:ENROLL_STARTED")
        } else {
            endEnrollment()
            sendResponse(clientSocket, response: "ERROR:ENROLL_FAILED")
        }
    }

    private func handleDelete(_ clientSocket: Int32, parts: [Substring]) {
        guard parts.count >= 3, let slotId = UInt8(String(parts[2])) else {
            sendResponse(clientSocket, response: "ERROR:INVALID_SLOT")
            return
        }

        guard bleManager.deviceState.isConnected else {
            sendResponse(clientSocket, response: "ERROR:NOT_CONNECTED")
            return
        }

        NSLog("PAMSocketServer: Deleting fingerprint slot %d", slotId)

        let semaphore = DispatchSemaphore(value: 0)
        var success = false

        bleManager.deleteFingerprint(slotId: slotId) { result in
            success = result
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 5)

        if success {
            sendResponse(clientSocket, response: "OK:DELETED")
        } else {
            sendResponse(clientSocket, response: "ERROR:DELETE_FAILED")
        }
    }

    private func handleList(_ clientSocket: Int32) {
        guard bleManager.deviceState.isConnected else {
            sendResponse(clientSocket, response: "ERROR:NOT_CONNECTED")
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        var count = 0

        bleManager.getFingerprintCount { result in
            count = result
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 5)

        sendResponse(clientSocket, response: "OK:\(count)")
    }

    private func handleEnrollStatus(_ clientSocket: Int32) {
        enrollLock.lock()
        let active = enrollActive
        let status = enrollStatus
        let current = enrollCurrent
        let total = enrollTotal
        enrollLock.unlock()

        // Always return final status (complete/failed) even if enrollment ended
        // This ensures the app can see the result before we return IDLE
        if status == .complete || status == .failed {
            sendResponse(clientSocket, response: "OK:\(status.rawValue):\(current):\(total)")
            return
        }

        if !active {
            sendResponse(clientSocket, response: "OK:IDLE")
            return
        }

        // Format: OK:event:current:total
        // event: 0=waiting, 1=captured, 2=processing, 3=liftFinger, 4=complete, 255=failed
        sendResponse(clientSocket, response: "OK:\(status.rawValue):\(current):\(total)")
    }

    // MARK: - OTA Commands

    // OTA protocol constants (must match firmware ota.h V1 layout)
    private static let IMAGE_B_START: UInt32 = 0x00037000  // IMAGE_A_START(0x1000) + IMAGE_SIZE(216KB)
    private static let FLASH_BLOCK_SIZE: UInt32 = 4096
    private static let IMAGE_B_BLOCKS: UInt16 = 54  // 216KB / 4KB
    private static let OTA_MAX_DATA: Int = 240  // ≤243, 16-byte aligned

    private func handleOTASession(_ clientSocket: Int32, firstParts: [Substring]) {
        NSLog("PAMSocketServer: OTA session started")

        // Increase socket timeout for OTA session
        var tv = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Process the first command (already parsed)
        if firstParts.count >= 2 {
            let handled = processOTACommand(clientSocket, parts: firstParts)
            if !handled { return }
        } else {
            sendLine(clientSocket, line: "ERROR:INVALID_FORMAT")
            return
        }

        // Persistent connection: read more commands line by line
        var buffer = Data()
        var readBuf = [UInt8](repeating: 0, count: 4096)

        while true {
            let n = recv(clientSocket, &readBuf, readBuf.count, 0)
            if n <= 0 { break }

            buffer.append(contentsOf: readBuf[0..<n])

            // Process complete lines
            while let newlineRange = buffer.range(of: Data([0x0A])) {
                let lineData = buffer[buffer.startIndex..<newlineRange.lowerBound]
                buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

                guard let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !line.isEmpty else { continue }

                let parts = line.split(separator: ":")
                guard parts.count >= 1 else { continue }

                let shouldContinue = processOTACommand(clientSocket, parts: Array(parts))
                if !shouldContinue { return }
            }
        }

        NSLog("PAMSocketServer: OTA session ended")
    }

    /// Process a single OTA command. Returns false if session should end.
    private func processOTACommand(_ clientSocket: Int32, parts: [Substring]) -> Bool {
        // parts[0] is "OTA", subcommand is parts[1]
        guard parts.count >= 2 else {
            sendLine(clientSocket, line: "ERROR:INVALID_FORMAT")
            return true
        }

        let subCmd = String(parts[1])
        if subCmd != "WRITE" {
            NSLog("PAMSocketServer: OTA cmd: %@", subCmd)
        }

        switch subCmd {
        case "INFO":
            handleOTAInfo(clientSocket)
        case "ERASE":
            handleOTAErase(clientSocket)
        case "HEADER":
            handleOTAHeader(clientSocket, parts: parts)
        case "WRITE":
            handleOTAWrite(clientSocket, parts: parts)
        case "VERIFY":
            handleOTAVerify(clientSocket, parts: parts)
        case "END":
            handleOTAEnd(clientSocket)
            return false  // Session ends after END
        default:
            sendLine(clientSocket, line: "ERROR:UNKNOWN_OTA_CMD")
        }
        return true
    }

    private func sendLine(_ socket: Int32, line: String) {
        let msg = line + "\n"
        _ = msg.withCString { ptr in
            send(socket, ptr, strlen(ptr), 0)
        }
    }

    // OTA:INFO → query device info
    private func handleOTAInfo(_ clientSocket: Int32) {
        guard bleManager.isOTAAvailable else {
            sendLine(clientSocket, line: "ERROR:OTA_NOT_AVAILABLE")
            return
        }

        // CMD_IAP_INFO: [0x84, 0x02, 0x00, 0x00]
        let cmd = Data([0x84, 0x02, 0x00, 0x00])
        let sem = DispatchSemaphore(value: 0)
        var result: Data?

        bleManager.otaWriteAndRead(data: cmd, timeout: 5.0) { data in
            result = data
            sem.signal()
        }

        _ = sem.wait(timeout: .now() + 8)

        guard let resp = result, resp.count >= 9 else {
            sendLine(clientSocket, line: "ERROR:NO_RESPONSE")
            return
        }

        // Parse: [image_flag, size[4], block_size[2], chip_id[2], ...]
        let imageFlag = resp[0]
        let imageSize = UInt32(resp[1]) | (UInt32(resp[2]) << 8) |
                       (UInt32(resp[3]) << 16) | (UInt32(resp[4]) << 24)
        let blockSize = UInt16(resp[5]) | (UInt16(resp[6]) << 8)
        let chipId = UInt16(resp[7]) | (UInt16(resp[8]) << 8)

        let reply = String(format: "OK:%02x:%08x:%04x:%04x", imageFlag, imageSize, blockSize, chipId)
        NSLog("PAMSocketServer: OTA INFO: %@", reply)
        sendLine(clientSocket, line: reply)
    }

    // OTA:ERASE → erase entire Image B
    private func handleOTAErase(_ clientSocket: Int32) {
        guard bleManager.isOTAAvailable else {
            sendLine(clientSocket, line: "ERROR:OTA_NOT_AVAILABLE")
            return
        }

        // Erase from offset 0, 54 blocks
        // Address encoding: addr * 16 + IMAGE_B_START = target flash address
        // So addr = 0 (offset 0 from Image B start)
        let startAddr: UInt16 = 0
        let blockNum = Self.IMAGE_B_BLOCKS

        // CMD_IAP_ERASE: [0x81, 0x04, addr_lo, addr_hi, blocks_lo, blocks_hi]
        let cmd = Data([
            0x81, 0x04,
            UInt8(startAddr & 0xFF), UInt8(startAddr >> 8),
            UInt8(blockNum & 0xFF), UInt8(blockNum >> 8)
        ])

        let sem = DispatchSemaphore(value: 0)
        var result: Data?

        // Erase is async on device - can take several seconds
        bleManager.otaWriteAndRead(data: cmd, timeout: 15.0) { data in
            result = data
            sem.signal()
        }

        _ = sem.wait(timeout: .now() + 20)

        guard let resp = result, resp.count >= 1 else {
            sendLine(clientSocket, line: "ERROR:ERASE_TIMEOUT")
            return
        }

        if resp[0] == 0x00 {
            NSLog("PAMSocketServer: OTA ERASE success")
            sendLine(clientSocket, line: "OK")
        } else {
            NSLog("PAMSocketServer: OTA ERASE failed: 0x%02x", resp[0])
            sendLine(clientSocket, line: "ERROR:ERASE_FAILED:\(String(format: "%02x", resp[0]))")
        }
    }

    // OTA:WRITE:offset_hex:base64data → write data to Image B
    private func handleOTAWrite(_ clientSocket: Int32, parts: [Substring]) {
        guard parts.count >= 4 else {
            sendLine(clientSocket, line: "ERROR:INVALID_FORMAT")
            return
        }

        guard bleManager.isOTAAvailable else {
            sendLine(clientSocket, line: "ERROR:OTA_NOT_AVAILABLE")
            return
        }

        guard let offset = UInt32(String(parts[2]), radix: 16) else {
            sendLine(clientSocket, line: "ERROR:INVALID_OFFSET")
            return
        }

        guard let data = Data(base64Encoded: String(parts[3])) else {
            sendLine(clientSocket, line: "ERROR:INVALID_DATA")
            return
        }

        // Address encoding: encoded_addr = offset / 16 (offset is relative to Image B start)
        let encodedAddr = UInt16(offset / 16)

        // CMD_IAP_PROM: [0x80, len, addr_lo, addr_hi, data...]
        var cmd = Data([
            0x80,
            UInt8(data.count),
            UInt8(encodedAddr & 0xFF),
            UInt8(encodedAddr >> 8)
        ])
        cmd.append(data)

        // Write Without Response for throughput — integrity verified by SHA256+HMAC at END
        let sem = DispatchSemaphore(value: 0)
        var ok = false

        bleManager.otaWriteOnly(data: cmd) { success in
            ok = success
            sem.signal()
        }

        _ = sem.wait(timeout: .now() + 8)

        if ok {
            sendLine(clientSocket, line: "OK")
        } else {
            sendLine(clientSocket, line: "ERROR:WRITE_FAILED")
        }
    }

    // OTA:VERIFY:offset_hex:base64data → verify data in Image B
    private func handleOTAVerify(_ clientSocket: Int32, parts: [Substring]) {
        guard parts.count >= 4 else {
            sendLine(clientSocket, line: "ERROR:INVALID_FORMAT")
            return
        }

        guard bleManager.isOTAAvailable else {
            sendLine(clientSocket, line: "ERROR:OTA_NOT_AVAILABLE")
            return
        }

        guard let offset = UInt32(String(parts[2]), radix: 16) else {
            sendLine(clientSocket, line: "ERROR:INVALID_OFFSET")
            return
        }

        guard let data = Data(base64Encoded: String(parts[3])) else {
            sendLine(clientSocket, line: "ERROR:INVALID_DATA")
            return
        }

        let encodedAddr = UInt16(offset / 16)

        // CMD_IAP_VERIFY: [0x82, len, addr_lo, addr_hi, data...]
        var cmd = Data([
            0x82,
            UInt8(data.count),
            UInt8(encodedAddr & 0xFF),
            UInt8(encodedAddr >> 8)
        ])
        cmd.append(data)

        let sem = DispatchSemaphore(value: 0)
        var result: Data?

        bleManager.otaWriteAndRead(data: cmd, timeout: 5.0) { resp in
            result = resp
            sem.signal()
        }

        _ = sem.wait(timeout: .now() + 8)

        guard let resp = result, resp.count >= 1 else {
            sendLine(clientSocket, line: "ERROR:VERIFY_TIMEOUT")
            return
        }

        if resp[0] == 0x00 {
            sendLine(clientSocket, line: "OK")
        } else {
            sendLine(clientSocket, line: "ERROR:VERIFY_FAILED:\(String(format: "%02x", resp[0]))")
        }
    }

    // OTA:HEADER:base64data → send .imfw header (96 bytes) to device
    private func handleOTAHeader(_ clientSocket: Int32, parts: [Substring]) {
        guard parts.count >= 3 else {
            sendLine(clientSocket, line: "ERROR:INVALID_FORMAT")
            return
        }

        guard bleManager.isOTAAvailable else {
            sendLine(clientSocket, line: "ERROR:OTA_NOT_AVAILABLE")
            return
        }

        guard let headerData = Data(base64Encoded: String(parts[2])) else {
            sendLine(clientSocket, line: "ERROR:INVALID_DATA")
            return
        }

        guard headerData.count == 96 else {
            sendLine(clientSocket, line: "ERROR:INVALID_HEADER_SIZE")
            return
        }

        // CMD_IAP_HEADER: [0x85, 0x60(96), header_data...]
        var cmd = Data([0x85, UInt8(headerData.count)])
        cmd.append(headerData)

        let sem = DispatchSemaphore(value: 0)
        var result: Data?

        bleManager.otaWriteAndRead(data: cmd, timeout: 5.0) { data in
            result = data
            sem.signal()
        }

        _ = sem.wait(timeout: .now() + 8)

        guard let resp = result, resp.count >= 1 else {
            sendLine(clientSocket, line: "ERROR:HEADER_TIMEOUT")
            return
        }

        if resp[0] == 0x00 {
            NSLog("PAMSocketServer: OTA HEADER accepted")
            sendLine(clientSocket, line: "OK")
        } else {
            NSLog("PAMSocketServer: OTA HEADER rejected: 0x%02x", resp[0])
            sendLine(clientSocket, line: "ERROR:HEADER_REJECTED:\(String(format: "%02x", resp[0]))")
        }
    }

    // OTA:END → finish upgrade, device reboots (with security verification)
    private func handleOTAEnd(_ clientSocket: Int32) {
        guard bleManager.isOTAAvailable else {
            sendLine(clientSocket, line: "ERROR:OTA_NOT_AVAILABLE")
            return
        }

        // CMD_IAP_END: [0x83, 0x02, 0x00, 0x00]
        let cmd = Data([0x83, 0x02, 0x00, 0x00])

        let sem = DispatchSemaphore(value: 0)
        var result: Data?

        // Device may reboot (success) or respond with error code
        bleManager.otaWriteAndRead(data: cmd, timeout: 5.0) { data in
            result = data
            sem.signal()
        }

        _ = sem.wait(timeout: .now() + 8)

        let respHex = result.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "nil"
        NSLog("PAMSocketServer: OTA END response: %@", respHex)

        if let resp = result, resp.count >= 1 {
            switch resp[0] {
            case 0xF1:
                sendLine(clientSocket, line: "ERROR:SHA256_MISMATCH")
                return
            case 0xF2:
                sendLine(clientSocket, line: "ERROR:HMAC_MISMATCH")
                return
            default:
                break
            }
        }

        // No response or success (device rebooted)
        sendLine(clientSocket, line: "OK")
    }

    func stop() {
        isRunning = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        unlink(socketPath)
        NSLog("PAMSocketServer: Stopped")
    }
}

// MARK: - Errors

enum PAMSocketError: Error {
    case socketCreationFailed
    case bindFailed
    case listenFailed

    var localizedDescription: String {
        switch self {
        case .socketCreationFailed:
            return "Failed to create socket"
        case .bindFailed:
            return "Failed to bind to socket path"
        case .listenFailed:
            return "Failed to listen on socket"
        }
    }
}
