/*
 * CLISocketServer.swift - Unix socket server for imk CLI communication
 *
 * Listens on ~/.immurok/cli.sock for key read requests from imk CLI.
 * Protocol: line-based text, similar to PAMSocketServer pattern.
 *
 * Commands:
 *   PING           → OK:immurok
 *   LIST:cat       → OK:count\n
 *                    <line>\n × count\n
 *                    \n
 *                    line format:
 *                      otp/api: <name>
 *                      ssh:     <name>\t<algo> <base64-pubkey>
 *   GET:cat:name   → OK:value
 *   PAM_KEY        → OK:key_hex64          （仅 root 对端；imk pam-key install 用）
 *   PAM_KEY_ID     → OK:key_id16           （本用户或 root）
 *   ERROR:reason
 *
 * root 对端（euid 0）只放行 PING / PAM_KEY / PAM_KEY_ID，LIST/GET 一律拒绝。
 * server 无条件启动；「imk CLI」开关（immurok.cliEnabled）关闭时 LIST/GET 回
 * ERROR:CLI_DISABLED，PING / PAM_KEY / PAM_KEY_ID 不受影响。
 */

import Foundation
import AuthInjectionKit

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
        // root 只允许拿 pam_key（imk pam-key install 以 sudo 运行）；其余命令仍只认本用户。
        guard euid == myUid || euid == 0 else {
            NSLog("CLISocketServer: Rejected UID %d (expected %d or 0)", euid, myUid)
            return
        }
        let isRoot = euid == 0 && myUid != 0

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

        case "PAM_KEY":
            guard isRoot else {
                sendLine(clientSocket, "ERROR:ROOT_REQUIRED")
                return
            }
            guard let key = ImmurokSecurity.shared.loadOrCreatePamKey() else {
                sendLine(clientSocket, "ERROR:KEYCHAIN")
                return
            }
            NSLog("CLISocketServer: pam_key handed to root peer (imk pam-key install)")
            sendLine(clientSocket, "OK:" + key.map { String(format: "%02x", $0) }.joined())

        case "PAM_KEY_ID":
            guard let id = ImmurokSecurity.shared.pamKeyId() else {
                sendLine(clientSocket, "ERROR:NO_KEY")
                return
            }
            sendLine(clientSocket, "OK:" + id)

        case "LIST":
            if isRoot { sendLine(clientSocket, "ERROR:UNKNOWN_COMMAND"); return }
            guard cliEnabled else { sendLine(clientSocket, "ERROR:CLI_DISABLED"); return }
            guard parts.count >= 2, let cat = parseCategory(String(parts[1])) else {
                sendLine(clientSocket, "ERROR:INVALID_CATEGORY")
                return
            }
            handleList(clientSocket, cat: cat)

        case "GET":
            if isRoot { sendLine(clientSocket, "ERROR:UNKNOWN_COMMAND"); return }
            guard cliEnabled else { sendLine(clientSocket, "ERROR:CLI_DISABLED"); return }
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

    /// 「imk CLI」开关只关掉 LIST/GET；PING / PAM_KEY / PAM_KEY_ID 始终可用，
    /// 否则关了开关就装不上 PAM 强认证密钥。
    private var cliEnabled: Bool {
        UserDefaults.standard.bool(forKey: "immurok.cliEnabled")
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
        // Route through the App's cache layer so digest-matched listings
        // come straight from disk (one ~6-byte BLE round-trip for the
        // checksum, zero per-entry reads). Falls back to full BLE fetch
        // only when the device-reported (count, checksum) differs from
        // what we have cached.
        let sem = DispatchSemaphore(value: 0)
        if cat == .ssh {
            SSHKeyCache.shared.sync { sem.signal() }
        } else {
            KeyNameCache.shared.syncCategory(cat) { sem.signal() }
        }
        // 10 s budget covers a worst-case full re-fetch on a slow link.
        // If the device is disconnected, sync completes immediately with
        // whatever's in the cache — we still serve stale entries rather
        // than fail outright.
        _ = sem.wait(timeout: .now() + 10)

        // Format:
        //   OK:count\n
        //   <name>\n                                  (otp/api)
        //   <name>\t<algo> <base64-pubkey>\n          (ssh)
        //   ...
        //   \n   (terminator blank line)
        var response: String
        switch cat {
        case .ssh:
            let entries = SSHKeyCache.shared.entries
            response = "OK:\(entries.count)\n"
            for e in entries {
                let b64 = e.publicKeyBlob.base64EncodedString()
                response += "\(e.name)\tecdsa-sha2-nistp256 \(b64)\n"
            }
        default:
            let entries = KeyNameCache.shared.entries(for: cat)
            response = "OK:\(entries.count)\n"
            for e in entries {
                response += "\(e.name)\n"
            }
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

        // OTP/API are FP-gated device flows — take the exclusive activity
        // slot so a GET can't interleave with keystore maintenance (batch
        // delete reindexes entries mid-flight → stale index reads) or with
        // another in-flight auth.
        guard let activityToken = DeviceActivityCoordinator.shared.tryBegin(.auth) else {
            let blocker = DeviceActivityCoordinator.shared.currentActivity?.rawValue ?? "unknown"
            NSLog("CLISocketServer: GET rejected — %@ in flight", blocker)
            sendLine(clientSocket, "ERROR:BUSY:\(blocker)")
            return
        }
        defer { DeviceActivityCoordinator.shared.end(activityToken) }

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

        // Ctrl+C kills `imk` instantly; nothing else would tell us. Without
        // this the device kept waiting for a touch and the spinner kept
        // repainting over the shell prompt for the remaining ~30 s.
        let disconnectWatcher = ClientDisconnectWatcher.start(socket: clientSocket) { [weak self] in
            NSLog("CLISocketServer: GET client gone (Ctrl+C) — cancelling fingerprint gate")
            spinner?.abandon()
            self?.bleManager.cancelUnlock()
        }
        defer { disconnectWatcher.stop() }

        let sem = DispatchSemaphore(value: 0)
        var approved = false

        bleManager.requestUnlock(timeout: 30.0) { success in
            approved = success
            sem.signal()
        }

        let waitResult = sem.wait(timeout: .now() + 35)
        bleManager.onFingerprintAttemptFailed = previousAttemptFailed
        // Stop watching before the secret read below: cancelUnlock() releases
        // the BLE queue hold, which would corrupt an in-flight KEY_READ.
        disconnectWatcher.stop()

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
            sendLine(clientSocket, notFoundResponse(name: name))
            return
        }
        let pubKey = SSHKeyCache.formatOpenSSHPublicKey(blob: entry.publicKeyBlob, comment: entry.name)
        sendLine(clientSocket, "OK:\(pubKey)")
    }

    // MARK: - GET:api — read raw secret

    private func handleGetAPI(_ clientSocket: Int32, name: String) {
        // Find index by name
        guard let idx = findKeyIndex(cat: .api, name: name) else {
            sendLine(clientSocket, notFoundResponse(name: name))
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

        // Entry layout (api_entry_t in firmware/APP/immurok_keystore.h):
        // name[32] + key[128] = 160 bytes total
        guard data.count > 32 else {
            sendLine(clientSocket, "ERROR:INVALID_DATA")
            return
        }
        let secretData = data[32...]
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
            sendLine(clientSocket, notFoundResponse(name: name))
            return
        }

        let spinner = TerminalSpinner(clientSocket: clientSocket)
        spinner?.start()

        let previousAttemptFailed = bleManager.onFingerprintAttemptFailed
        bleManager.onFingerprintAttemptFailed = { remaining in spinner?.showTryAgain(remaining: remaining) }

        // Same Ctrl+C handling as GET:api. OTP runs on the device behind the
        // FP gate, so the cancel goes through cancelGateAndRelease() (which
        // clears pendingGateDataCompletion) rather than cancelUnlock().
        let disconnectWatcher = ClientDisconnectWatcher.start(socket: clientSocket) { [weak self] in
            NSLog("CLISocketServer: OTP client gone (Ctrl+C) — cancelling fingerprint gate")
            spinner?.abandon()
            self?.bleManager.cancelGateAndRelease()
        }
        defer { disconnectWatcher.stop() }

        let sem = DispatchSemaphore(value: 0)
        var otpCode: String?

        bleManager.requestOTP(idx: UInt8(idx)) { code in
            otpCode = code
            sem.signal()
        }

        let waitResult = sem.wait(timeout: .now() + 35)
        disconnectWatcher.stop()
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

    /// Find keystore index by name (synchronous, blocking).
    /// Routes through the same cache that `imk list` uses
    /// (KeyNameCache / SSHKeyCache) — guarantees `get` sees exactly what
    /// `list` shows, and skips the redundant 128 KEY_READ round-trip
    /// chain the legacy bleManager.getKeyEntryNames was doing on each
    /// `imk get` call. The cache's syncCategory does a single 6-byte
    /// (count, checksum) digest probe and only re-fetches when the
    /// device-side digest changed — usually instant.
    private func findKeyIndex(cat: KeystoreCategory, name: String) -> Int? {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Sync cache to current device state.
        let sem = DispatchSemaphore(value: 0)
        if cat == .ssh {
            SSHKeyCache.shared.sync { sem.signal() }
        } else {
            KeyNameCache.shared.syncCategory(cat) { sem.signal() }
        }
        _ = sem.wait(timeout: .now() + 10)

        // Read entries from the cache.
        let entries: [(index: Int, name: String)]
        if cat == .ssh {
            entries = SSHKeyCache.shared.entries.map { (index: $0.index, name: $0.name) }
        } else {
            entries = KeyNameCache.shared.entries(for: cat).map { (index: $0.index, name: $0.name) }
        }
        let availableNames = entries.map(\.name)

        // 3-pass match: exact → trimmed → control-char-stripped + trimmed.
        if let hit = entries.first(where: { $0.name == name }) {
            return hit.index
        }
        if let hit = entries.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == target
        }) {
            return hit.index
        }
        let cleanedTarget = Self.cleanedName(target)
        if let hit = entries.first(where: {
            Self.cleanedName($0.name) == cleanedTarget
        }) {
            return hit.index
        }

        self.lastAvailableNames = availableNames
        let quoted = availableNames
            .map { "\"\($0)\" (\($0.utf8.count)B)" }
            .joined(separator: ", ")
        NSLog("CLISocketServer: GET %@/'%@' not found. Available: [%@]",
              String(describing: cat), name, quoted)
        return nil
    }

    /// Last lookup's available names — surfaced in NOT_FOUND error responses
    /// so the user sees the real stored content in their terminal.
    private var lastAvailableNames: [String] = []

    private static func cleanedName(_ s: String) -> String {
        s.unicodeScalars
            .filter { !$0.properties.isDefaultIgnorableCodePoint && $0.value >= 0x20 }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build a NOT_FOUND error response that includes the available names so
    /// the user can immediately spot encoding mismatches without checking
    /// Console.app. Format keeps the response on a single line.
    private func notFoundResponse(name: String) -> String {
        let dump = lastAvailableNames
            .map { "'\($0)'" }
            .joined(separator: ", ")
        return dump.isEmpty
            ? "ERROR:NOT_FOUND:\(name)"
            : "ERROR:NOT_FOUND:\(name) | available: [\(dump)]"
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
