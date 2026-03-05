/*
 * CLISocketServer.swift - Unix socket server for imk CLI communication
 *
 * Listens on ~/.immurok/cli.sock for key read requests from imk CLI.
 * Protocol: line-based text, similar to PAMSocketServer pattern.
 *
 * Commands:
 *   PING           → OK:immurok
 *   LIST:cat       → OK:count\nname1\nname2\n\n
 *   GET:cat:name   → OK:value
 *   ERROR:reason
 */

import Foundation

class CLISocketServer {
    private let socketPath: String
    private var serverSocket: Int32 = -1
    private var isRunning = false
    private let bleManager: BLEManager

    init(bleManager: BLEManager) {
        self.bleManager = bleManager
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        socketPath = "\(home)/.immurok/cli.sock"
    }

    func start() throws {
        // Ensure ~/.immurok/ exists
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Remove existing socket
        unlink(socketPath)

        // Create socket
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw CLISocketError.socketCreationFailed
        }

        // Bind
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
            throw CLISocketError.bindFailed
        }

        // Owner-only access (0o600)
        chmod(socketPath, 0o600)

        guard listen(serverSocket, 5) >= 0 else {
            close(serverSocket)
            throw CLISocketError.listenFailed
        }

        isRunning = true
        NSLog("CLISocketServer: Listening on %@", socketPath)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        isRunning = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        unlink(socketPath)
        NSLog("CLISocketServer: Stopped")
    }

    // MARK: - Accept Loop

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
                if isRunning { NSLog("CLISocketServer: Accept failed") }
                continue
            }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(clientSocket)
            }
        }
    }

    // MARK: - Client Handler

    private func handleClient(_ clientSocket: Int32) {
        defer { close(clientSocket) }

        // Verify peer identity: only allow current user
        var euid: uid_t = 0
        var egid: gid_t = 0
        guard getpeereid(clientSocket, &euid, &egid) == 0 else {
            NSLog("CLISocketServer: getpeereid() failed")
            return
        }
        let myUid = getuid()
        guard euid == myUid else {
            NSLog("CLISocketServer: Rejected UID %d (expected %d)", euid, myUid)
            return
        }

        // 10s receive timeout
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Read request
        var buffer = [CChar](repeating: 0, count: 1024)
        let n = recv(clientSocket, &buffer, buffer.count - 1, 0)
        guard n > 0 else { return }

        let request = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("CLISocketServer: Received: %@", request)

        let parts = request.split(separator: ":", maxSplits: 2)
        guard let command = parts.first else {
            sendLine(clientSocket, "ERROR:EMPTY_REQUEST")
            return
        }

        switch command {
        case "PING":
            sendLine(clientSocket, "OK:immurok")

        case "LIST":
            guard parts.count >= 2, let cat = parseCategory(String(parts[1])) else {
                sendLine(clientSocket, "ERROR:INVALID_CATEGORY")
                return
            }
            handleList(clientSocket, cat: cat)

        case "GET":
            // GET:category:name → parts = ["GET", "category", "name"]
            guard parts.count >= 3,
                  let cat = parseCategory(String(parts[1])) else {
                sendLine(clientSocket, "ERROR:INVALID_FORMAT")
                return
            }
            let name = String(parts[2])
            handleGet(clientSocket, cat: cat, name: name)

        default:
            sendLine(clientSocket, "ERROR:UNKNOWN_COMMAND")
        }
    }

    // MARK: - Category Parsing

    private func parseCategory(_ str: String) -> KeystoreCategory? {
        switch str.lowercased() {
        case "ssh": return .ssh
        case "otp": return .otp
        case "api": return .api
        default: return nil
        }
    }

    // MARK: - LIST

    private func handleList(_ clientSocket: Int32, cat: KeystoreCategory) {
        guard bleManager.deviceState.isConnected else {
            sendLine(clientSocket, "ERROR:NOT_CONNECTED")
            return
        }

        let sem = DispatchSemaphore(value: 0)
        var names: [(index: Int, name: String)] = []

        bleManager.getKeyEntryNames(cat: cat) { result in
            names = result
            sem.signal()
        }

        guard sem.wait(timeout: .now() + 10) == .success else {
            sendLine(clientSocket, "ERROR:TIMEOUT")
            return
        }

        // Format: OK:count\nname1\nname2\n\n
        var response = "OK:\(names.count)\n"
        for entry in names {
            response += "\(entry.name)\n"
        }
        response += "\n"
        sendRaw(clientSocket, response)
    }

    // MARK: - GET

    private func handleGet(_ clientSocket: Int32, cat: KeystoreCategory, name: String) {
        guard bleManager.deviceState.isConnected else {
            sendLine(clientSocket, "ERROR:NOT_CONNECTED")
            return
        }

        // SSH public keys don't need fingerprint verification
        if cat == .ssh {
            handleGetSSH(clientSocket, name: name)
            return
        }

        // OTP uses device-side computation (includes FP gate)
        if cat == .otp {
            handleGetOTP(clientSocket, name: name)
            return
        }

        // Require fingerprint verification for API secrets
        let spinner = TerminalSpinner(clientSocket: clientSocket)
        spinner?.start()

        let previousAttemptFailed = bleManager.onFingerprintAttemptFailed
        bleManager.onFingerprintAttemptFailed = { remaining in spinner?.showTryAgain(remaining: remaining) }

        let sem = DispatchSemaphore(value: 0)
        var approved = false

        bleManager.requestUnlock(timeout: 30.0) { success in
            approved = success
            sem.signal()
        }

        let waitResult = sem.wait(timeout: .now() + 35)
        bleManager.onFingerprintAttemptFailed = previousAttemptFailed

        guard waitResult == .success, approved else {
            spinner?.stop(waitResult == .timedOut ? .timeout : .tryAgain)
            sendLine(clientSocket, "ERROR:FINGERPRINT_DENIED")
            return
        }

        spinner?.stop(.approved)

        handleGetAPI(clientSocket, name: name)
    }

    // MARK: - GET:ssh — return OpenSSH public key

    private func handleGetSSH(_ clientSocket: Int32, name: String) {
        // Look up in SSHKeyCache
        guard let entry = SSHKeyCache.shared.entries.first(where: { $0.name == name }) else {
            sendLine(clientSocket, "ERROR:NOT_FOUND:\(name)")
            return
        }
        let pubKey = SSHKeyCache.formatOpenSSHPublicKey(blob: entry.publicKeyBlob, comment: entry.name)
        sendLine(clientSocket, "OK:\(pubKey)")
    }

    // MARK: - GET:api — read raw secret

    private func handleGetAPI(_ clientSocket: Int32, name: String) {
        // Find index by name
        guard let idx = findKeyIndex(cat: .api, name: name) else {
            sendLine(clientSocket, "ERROR:NOT_FOUND:\(name)")
            return
        }

        // Read full 256B entry
        let sem = DispatchSemaphore(value: 0)
        var entryData: Data?

        bleManager.readKeyEntry(cat: .api, idx: UInt8(idx)) { data in
            entryData = data
            sem.signal()
        }

        guard sem.wait(timeout: .now() + 10) == .success, let data = entryData else {
            sendLine(clientSocket, "ERROR:READ_FAILED")
            return
        }

        // Entry layout: name[16] + secret[240]
        guard data.count > 16 else {
            sendLine(clientSocket, "ERROR:INVALID_DATA")
            return
        }
        let secretData = data[16...]
        let trimmed = secretData.prefix(while: { $0 != 0 })
        guard let secret = String(data: trimmed, encoding: .utf8), !secret.isEmpty else {
            sendLine(clientSocket, "ERROR:EMPTY_SECRET")
            return
        }
        sendLine(clientSocket, "OK:\(secret)")
    }

    // MARK: - GET:otp — device-side TOTP computation

    private func handleGetOTP(_ clientSocket: Int32, name: String) {
        guard let idx = findKeyIndex(cat: .otp, name: name) else {
            sendLine(clientSocket, "ERROR:NOT_FOUND:\(name)")
            return
        }

        let spinner = TerminalSpinner(clientSocket: clientSocket)
        spinner?.start()

        let previousAttemptFailed = bleManager.onFingerprintAttemptFailed
        bleManager.onFingerprintAttemptFailed = { remaining in spinner?.showTryAgain(remaining: remaining) }

        let sem = DispatchSemaphore(value: 0)
        var otpCode: String?

        bleManager.requestOTP(idx: UInt8(idx)) { code in
            otpCode = code
            sem.signal()
        }

        let waitResult = sem.wait(timeout: .now() + 35)
        bleManager.onFingerprintAttemptFailed = previousAttemptFailed

        guard waitResult == .success, let code = otpCode else {
            spinner?.stop(waitResult == .timedOut ? .timeout : .tryAgain)
            sendLine(clientSocket, "ERROR:FINGERPRINT_DENIED")
            return
        }

        spinner?.stop(.approved)
        sendLine(clientSocket, "OK:\(code)")
    }

    // MARK: - Helpers

    /// Find keystore index by name (synchronous, blocking)
    private func findKeyIndex(cat: KeystoreCategory, name: String) -> Int? {
        let sem = DispatchSemaphore(value: 0)
        var foundIndex: Int?

        bleManager.getKeyEntryNames(cat: cat) { names in
            foundIndex = names.first(where: { $0.name == name })?.index
            sem.signal()
        }

        guard sem.wait(timeout: .now() + 10) == .success else { return nil }
        return foundIndex
    }

    private func sendLine(_ socket: Int32, _ line: String) {
        let msg = line + "\n"
        _ = msg.withCString { ptr in
            send(socket, ptr, strlen(ptr), 0)
        }
    }

    private func sendRaw(_ socket: Int32, _ text: String) {
        _ = text.withCString { ptr in
            send(socket, ptr, strlen(ptr), 0)
        }
    }
}

// MARK: - Errors

enum CLISocketError: Error {
    case socketCreationFailed
    case bindFailed
    case listenFailed
}
