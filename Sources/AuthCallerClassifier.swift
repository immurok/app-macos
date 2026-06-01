import Darwin
import Foundation

/// Classifies the originator of a PAM auth request as either an AI agent or
/// a manual user action (sudo from a terminal). Used to suppress the on-screen
/// auth overlay for human-initiated sudo where the user already knows what
/// they're doing — the overlay matters only when an AI agent might be doing
/// something behind the user's attention.
enum AuthCaller: Equatable {
    /// Optional command string is non-nil only when an explicit `imk run
    /// --agent` marker was found and carried it. Heuristic detection (known
    /// agent binary in the chain) returns .agent(command: nil).
    case agent(command: String?)
    case manual
}

enum AuthCallerClassifier {

    /// Walk the parent chain starting at the unix-socket peer PID. Stop at the
    /// first known agent — or at a terminal emulator / init — and return.
    static func classify(socketFD: Int32) -> AuthCaller {
        guard let peerPid = peerPid(of: socketFD) else { return .manual }
        return classify(fromPid: peerPid)
    }

    static func classify(fromPid startPid: pid_t) -> AuthCaller {
        var pid = startPid
        // 12 levels is enough for sudo → shell → wrapper → agent → editor stacks
        for _ in 0..<12 {
            // 1) Explicit marker dropped by `imk run --agent ... -- cmd`.
            //    Highest confidence: the user / agent declared itself.
            if let marker = readAgentMarker(pid: pid) {
                return .agent(command: marker.command)
            }
            guard let path = procPath(pid: pid) else { break }
            // 2) Heuristic: known agent binary in the chain (no command info).
            if matchAgent(path: path) {
                return .agent(command: nil)
            }
            // 3) Hit a terminal emulator before any agent → clearly manual.
            if isTerminalEmulator(path: path) {
                return .manual
            }
            guard let parent = parentPid(of: pid), parent > 1 else { break }
            pid = parent
        }
        return .manual
    }

    private struct MarkerInfo {
        let expiry: Int
        let command: String?
    }

    /// Read `~/.immurok/markers/<pid>`. Returns nil unless the marker exists
    /// and isn't past its expiry epoch. Format must mirror
    /// AgentMarker.write() in CLISources/AgentMarker.swift:
    ///   line 1: expiry epoch (seconds)
    ///   line 2: optional command string (display only)
    private static func readAgentMarker(pid: pid_t) -> MarkerInfo? {
        guard let home = ProcessInfo.processInfo.environment["HOME"] else { return nil }
        let path = "\(home)/.immurok/markers/\(pid)"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let lines = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let firstLine = lines.first,
              let expiry = Int(firstLine.trimmingCharacters(in: .whitespaces))
        else {
            return nil
        }
        if Int(Date().timeIntervalSince1970) > expiry {
            // Stale (imk SIGKILL'd before defer ran). Ignore and best-effort
            // cleanup so it doesn't pollute future scans.
            try? FileManager.default.removeItem(atPath: path)
            return nil
        }
        let command: String?
        if lines.count >= 2 {
            let raw = String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            command = raw.isEmpty ? nil : raw
        } else {
            command = nil
        }
        return MarkerInfo(expiry: expiry, command: command)
    }

    // MARK: - Agent / terminal pattern lists

    /// Any of these substrings appearing in a process path marks the chain
    /// as an AI agent. Display name is dropped — the binary signal (agent yes
    /// / no) is all the overlay decision needs.
    private static let agentPatterns: [String] = [
        "/claude",
        "/Claude.app",
        "/cursor",
        "Cursor.app",
        "/cline",
        "/aider",
        "/codex",
        "/windsurf",
        "Windsurf.app",
        "/continue",
        "/roo",
        "/zed",
        "Zed.app",
    ]

    /// Recognized terminal emulators — hitting one of these in the parent chain
    /// before an agent means the request was a human typing into a real shell.
    private static let terminalPatterns: [String] = [
        "Terminal.app",
        "iTerm.app",
        "iTerm2",
        "Warp.app",
        "WarpPreview.app",
        "Alacritty.app",
        "/alacritty",
        "kitty.app",
        "/kitty",
        "WezTerm.app",
        "Wezterm.app",
        "/wezterm",
        "Hyper.app",
        "ghostty.app",
        "Ghostty.app",
        "/ghostty",
        "tmux",
        "screen",
    ]

    private static func matchAgent(path: String) -> Bool {
        agentPatterns.contains { path.contains($0) }
    }

    private static func isTerminalEmulator(path: String) -> Bool {
        terminalPatterns.contains { path.contains($0) }
    }

    // MARK: - Process introspection

    private static func peerPid(of socket: Int32) -> pid_t? {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        if getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) != 0 {
            return nil
        }
        return pid
    }

    private static func procPath(pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        if n <= 0 { return nil }
        return String(cString: buf)
    }

    private static func parentPid(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var size = MemoryLayout<kinfo_proc>.stride
        let result = mib.withUnsafeMutableBufferPointer { buf -> Int32 in
            sysctl(buf.baseAddress, UInt32(buf.count), &info, &size, nil, 0)
        }
        if result != 0 || size == 0 { return nil }
        return info.kp_eproc.e_ppid
    }
}
