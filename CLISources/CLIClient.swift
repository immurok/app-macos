/*
 * CLIClient.swift - Unix socket client for communicating with immurok App
 *
 * Connects to ~/.immurok/cli.sock and sends line-based commands.
 */

import Foundation

struct CLIClient {
    static let socketPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.immurok/cli.sock"
    }()

    /// Send a command and return the raw response string
    static func send(_ command: String) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CLIError.connectionFailed("Cannot create socket")
        }
        defer { close(fd) }

        // Connect
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                _ = strcpy(pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { $0 }, ptr)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Foundation.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult >= 0 else {
            throw CLIError.connectionFailed(
                "Cannot connect to \(socketPath). Is immurok.app running?"
            )
        }

        // Set recv timeout. Must exceed the App's own wait budget for a
        // fingerprint-gated GET (30 s device gate + 5 s margin = 35 s),
        // otherwise `imk get imk://api/...` gave up at 15 s with "Empty
        // response from server" while the device was still waiting for a
        // touch — and left the gate open behind it.
        var tv = timeval(tv_sec: 40, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Send
        let msg = command + "\n"
        _ = msg.withCString { ptr in
            Foundation.send(fd, ptr, strlen(ptr), 0)
        }

        // Read response (may be multi-line for LIST)
        var response = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            response.append(contentsOf: buf[0..<n])
            // For single-line responses, check if we got a newline
            // For multi-line (LIST), check for double newline
            if response.contains(where: { $0 == 0x0A }) {
                // If response ends with \n\n or is a single OK/ERROR line, we're done
                if response.hasSuffix(Data([0x0A, 0x0A])) || !response.starts(with: Data("OK:".utf8)) {
                    break
                }
                // Single-line OK response (no LIST)
                let text = String(data: response, encoding: .utf8) ?? ""
                if !text.hasPrefix("OK:") || text.split(separator: "\n").count <= 1 {
                    // Could be a single-line response ending with \n
                    let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
                    if firstLine.hasPrefix("OK:") && !firstLine.hasPrefix("OK:0\n") {
                        // Might be multi-line LIST response, continue reading
                        // Check if first line looks like LIST response (OK:N where N > 0)
                        let afterOK = firstLine.dropFirst(3)
                        if let count = Int(afterOK), count > 0 {
                            continue  // Keep reading for names
                        }
                    }
                    break
                }
            }
        }

        guard let text = String(data: response, encoding: .utf8), !text.isEmpty else {
            throw CLIError.emptyResponse
        }

        return text.trimmingCharacters(in: .newlines)
    }

    /// Parse an error response, returns nil if response is OK
    static func checkError(_ response: String) -> String? {
        if response.hasPrefix("ERROR:") {
            let reason = String(response.dropFirst(6))
            if reason.hasPrefix("BUSY") {
                return "device busy (another auth or key operation in progress) — retry in a moment"
            }
            return reason
        }
        return nil
    }
}

enum CLIError: Error, CustomStringConvertible {
    case connectionFailed(String)
    case emptyResponse
    case serverError(String)

    var description: String {
        switch self {
        case .connectionFailed(let msg): return msg
        case .emptyResponse: return "Empty response from server"
        case .serverError(let msg): return msg
        }
    }
}

extension Data {
    func hasSuffix(_ suffix: Data) -> Bool {
        guard count >= suffix.count else { return false }
        return self[(count - suffix.count)...] == suffix
    }
}
