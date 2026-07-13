import Foundation
import Darwin

/// Talks to the App's PAM socket to ask for pre-execution approval of an
/// agent-initiated command. Used by `imk run --agent` to surface the overlay
/// BEFORE the wrapped command runs — covering non-PAM commands (`git pull`,
/// `rm`, `npm install`, etc.) that wouldn't otherwise trigger the overlay.
///
/// Protocol over the existing PAM unix socket:
///   imk  → App: `AGENT_APPROVE:<command-string>`
///   App  → imk: `OK` (fingerprint matched, pre-auth set for sudo)
///                `REJECT` (user closed overlay or 30s timeout)
///                `BUSY`   (another auth in flight)
///                `ERROR`  (BLE not connected, app not running, etc.)
enum AgentApproval {
    enum Result {
        case approved
        case rejected
        case error(String)
    }

    /// Block until the App responds (or our local timeout fires).
    static func request(command: String, timeoutSeconds: Int = 35) -> Result {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"
        let socketPath = "\(home)/.immurok/pam.sock"

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return .error("socket() failed") }
        defer { close(sock) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let pathCap = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < pathCap else { return .error("socket path too long") }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: pathCap) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = b }
                dst[pathBytes.count] = 0
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.stride)
        let connectRet = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, addrLen)
            }
        }
        guard connectRet >= 0 else {
            return .error("immurok app not running (socket connect failed)")
        }

        let request = "AGENT_APPROVE:\(command)"
        let sent = request.withCString { send(sock, $0, strlen($0), 0) }
        guard sent > 0 else { return .error("send() failed") }

        // Server-side already has its own 30s timeout; ours is a safety net.
        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buf = [CChar](repeating: 0, count: 256)
        let n = recv(sock, &buf, 255, 0)
        guard n > 0 else {
            return .error("no response from app (timeout or disconnect)")
        }
        let resp = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)

        switch resp {
        case "OK":     return .approved
        case "REJECT": return .rejected
        case "BUSY":   return .error("another auth or key operation is in flight — retry in a moment")
        default:       return .error("unexpected response: \(resp)")
        }
    }
}
