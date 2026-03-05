/*
 * SSHAgentServer.swift - SSH Agent protocol server
 *
 * Implements the SSH agent protocol over Unix socket (~/.immurok/agent.sock).
 * Proxies sign requests to the hardware device via BLE.
 *
 * Supported messages:
 *   SSH_AGENTC_REQUEST_IDENTITIES (11) → SSH_AGENT_IDENTITIES_ANSWER (12)
 *   SSH_AGENTC_SIGN_REQUEST (13)       → SSH_AGENT_SIGN_RESPONSE (14)
 *   All other                          → SSH_AGENT_FAILURE (5)
 */

import Foundation
import CryptoKit

class SSHAgentServer {

    static let shared = SSHAgentServer()

    // SSH Agent message types
    private let SSH_AGENT_FAILURE: UInt8 = 5
    private let SSH_AGENTC_REQUEST_IDENTITIES: UInt8 = 11
    private let SSH_AGENT_IDENTITIES_ANSWER: UInt8 = 12
    private let SSH_AGENTC_SIGN_REQUEST: UInt8 = 13
    private let SSH_AGENT_SIGN_RESPONSE: UInt8 = 14

    private var serverSocket: Int32 = -1
    private var isRunning = false
    let socketPath: String

    private init() {
        let immurokDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".immurok")
        try? FileManager.default.createDirectory(at: immurokDir, withIntermediateDirectories: true)
        socketPath = immurokDir.appendingPathComponent("agent.sock").path
    }

    // MARK: - Lifecycle

    func start() throws {
        unlink(socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            NSLog("SSHAgentServer: socket() failed: %d", errno)
            throw SSHAgentError.socketCreationFailed
        }

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
            throw SSHAgentError.bindFailed
        }

        // Only current user should access the agent socket
        chmod(socketPath, 0o600)

        guard listen(serverSocket, 5) >= 0 else {
            close(serverSocket)
            throw SSHAgentError.listenFailed
        }

        isRunning = true
        NSLog("SSHAgentServer: Listening on %@", socketPath)

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
        NSLog("SSHAgentServer: Stopped")
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
                if isRunning {
                    NSLog("SSHAgentServer: accept() failed: %d", errno)
                }
                continue
            }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(clientSocket)
            }
        }
    }

    // MARK: - Client Handling

    private func handleClient(_ clientSocket: Int32) {
        defer { close(clientSocket) }

        // Verify peer identity: only allow current user
        var euid: uid_t = 0
        var egid: gid_t = 0
        guard getpeereid(clientSocket, &euid, &egid) == 0 else {
            NSLog("SSHAgentServer: getpeereid() failed")
            return
        }
        let myUid = getuid()
        guard euid == myUid else {
            NSLog("SSHAgentServer: Rejected UID %d (expected %d)", euid, myUid)
            return
        }

        // SSH agent protocol: multiple request/response exchanges per connection
        while isRunning {
            // Set receive timeout (60 seconds — SSH may hold connections)
            var tv = timeval(tv_sec: 60, tv_usec: 0)
            setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            // Read message: [uint32 length][uint8 type][payload...]
            guard let msgData = readAgentMessage(clientSocket) else {
                break  // Connection closed or error
            }

            guard msgData.count >= 1 else {
                sendFailure(clientSocket)
                continue
            }

            let msgType = msgData[0]
            let payload = msgData.count > 1 ? msgData.subdata(in: 1..<msgData.count) : Data()

            switch msgType {
            case SSH_AGENTC_REQUEST_IDENTITIES:
                handleRequestIdentities(clientSocket)

            case SSH_AGENTC_SIGN_REQUEST:
                handleSignRequest(clientSocket, payload: payload)

            default:
                NSLog("SSHAgentServer: Unknown message type: %d", msgType)
                sendFailure(clientSocket)
            }
        }
    }

    // MARK: - REQUEST_IDENTITIES

    private func handleRequestIdentities(_ clientSocket: Int32) {
        let identities = SSHKeyCache.shared.allIdentities()

        var body = Data()
        body.append(SSH_AGENT_IDENTITIES_ANSWER)

        // nkeys (uint32)
        body.appendSSHUInt32(UInt32(identities.count))

        for entry in identities {
            // key blob (string)
            body.appendSSHString(entry.publicKeyBlob)
            // comment (string)
            body.appendSSHString(entry.name)
        }

        sendAgentMessage(clientSocket, data: body)
    }

    // MARK: - SIGN_REQUEST

    private func handleSignRequest(_ clientSocket: Int32, payload: Data) {
        // Parse: [string key_blob][string data][uint32 flags]
        var offset = 0

        guard let (keyBlob, keyBlobSize) = payload.readSSHString(at: offset) else {
            sendFailure(clientSocket)
            return
        }
        offset += keyBlobSize

        guard let (signData, signDataSize) = payload.readSSHString(at: offset) else {
            sendFailure(clientSocket)
            return
        }
        offset += signDataSize

        // flags (optional, uint32) — we ignore flags for now
        // let flags = payload.readSSHUInt32(at: offset) ?? 0

        // Find key index
        guard let idx = SSHKeyCache.shared.findIndex(forKeyBlob: keyBlob) else {
            NSLog("SSHAgentServer: Key not found in cache")
            sendFailure(clientSocket)
            return
        }

        let keyName = SSHKeyCache.shared.entries.first(where: { $0.index == idx })?.name ?? "key"
        NSLog("SSHAgentServer: Sign request for key idx=%d (%@), data=%d bytes", idx, keyName, signData.count)

        // Hash the data (SHA-256)
        let hash = Data(SHA256.hash(data: signData))

        // Start spinner on client terminal
        let spinner = TerminalSpinner(clientSocket: clientSocket)
        spinner?.start()

        // Hook up retry and gate-approved feedback
        let previousAttemptFailed = BLEManager.shared.onFingerprintAttemptFailed
        let previousGateApproved = BLEManager.shared.onFingerprintGateApproved
        BLEManager.shared.onFingerprintAttemptFailed = { remaining in spinner?.showTryAgain(remaining: remaining) }
        BLEManager.shared.onFingerprintGateApproved = { spinner?.showSigning() }

        // Sign via BLE (blocking)
        let semaphore = DispatchSemaphore(value: 0)
        var signature: Data?

        BLEManager.shared.sshSign(idx: UInt8(idx), hash: hash) { sig in
            signature = sig
            semaphore.signal()
        }

        // Wait up to 35 seconds (30s FP gate + 5s command timeout)
        let result = semaphore.wait(timeout: .now() + 35.0)
        BLEManager.shared.onFingerprintAttemptFailed = previousAttemptFailed
        BLEManager.shared.onFingerprintGateApproved = previousGateApproved

        guard result == .success, let sig = signature, sig.count == 64 else {
            spinner?.dismiss()
            NSLog("SSHAgentServer: Sign failed (timeout or error)")
            sendFailure(clientSocket)
            return
        }

        spinner?.dismiss()

        // Build SSH signature response
        let r = sig.subdata(in: 0..<32)
        let s = sig.subdata(in: 32..<64)

        // Build ecdsa signature blob: [string "ecdsa-sha2-nistp256"][string ecdsa_sig]
        // where ecdsa_sig = [mpint r][mpint s]
        var ecdsaSig = Data()
        ecdsaSig.appendSSHMpint(r)
        ecdsaSig.appendSSHMpint(s)

        var sigBlob = Data()
        sigBlob.appendSSHString("ecdsa-sha2-nistp256")
        sigBlob.appendSSHString(ecdsaSig)

        var body = Data()
        body.append(SSH_AGENT_SIGN_RESPONSE)
        body.appendSSHString(sigBlob)

        sendAgentMessage(clientSocket, data: body)
        NSLog("SSHAgentServer: Sign response sent (%d bytes)", sigBlob.count)
    }

    // MARK: - Wire Protocol

    /// Read an SSH agent message (4-byte length prefix + body)
    private func readAgentMessage(_ fd: Int32) -> Data? {
        // Read 4-byte length
        var lenBuf = [UInt8](repeating: 0, count: 4)
        var totalRead = 0
        while totalRead < 4 {
            let n = lenBuf.withUnsafeMutableBufferPointer { ptr in
                recv(fd, ptr.baseAddress! + totalRead, 4 - totalRead, 0)
            }
            if n <= 0 { return nil }
            totalRead += n
        }

        let msgLen = Int(lenBuf[0]) << 24
                   | Int(lenBuf[1]) << 16
                   | Int(lenBuf[2]) << 8
                   | Int(lenBuf[3])

        guard msgLen > 0, msgLen <= 256 * 1024 else { return nil }  // Sanity check

        // Read body
        var body = Data(count: msgLen)
        totalRead = 0
        while totalRead < msgLen {
            let n = body.withUnsafeMutableBytes { ptr in
                recv(fd, ptr.baseAddress! + totalRead, msgLen - totalRead, 0)
            }
            if n <= 0 { return nil }
            totalRead += n
        }

        return body
    }

    /// Send an SSH agent message (4-byte length prefix + body)
    private func sendAgentMessage(_ fd: Int32, data: Data) {
        var lenBuf = [UInt8](repeating: 0, count: 4)
        let len = data.count
        lenBuf[0] = UInt8((len >> 24) & 0xFF)
        lenBuf[1] = UInt8((len >> 16) & 0xFF)
        lenBuf[2] = UInt8((len >> 8) & 0xFF)
        lenBuf[3] = UInt8(len & 0xFF)

        _ = lenBuf.withUnsafeBufferPointer { ptr in
            send(fd, ptr.baseAddress!, 4, 0)
        }
        data.withUnsafeBytes { ptr in
            _ = send(fd, ptr.baseAddress!, data.count, 0)
        }
    }

    /// Send SSH_AGENT_FAILURE
    private func sendFailure(_ fd: Int32) {
        sendAgentMessage(fd, data: Data([SSH_AGENT_FAILURE]))
    }
}

// MARK: - Errors

enum SSHAgentError: Error {
    case socketCreationFailed
    case bindFailed
    case listenFailed
}
