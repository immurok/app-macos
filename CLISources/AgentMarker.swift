import Foundation

/// Marker file conventions shared between the `imk` CLI and the App's PAM
/// socket server. When `imk run --agent <name>` is invoked, the CLI writes a
/// marker keyed by its own PID; later, when the wrapped command (e.g. sudo)
/// triggers PAM auth, the App walks the AUTH-peer's parent chain looking for
/// any of these marker files. Match → request is treated as agent-initiated
/// → on-screen auth overlay is shown.
///
/// The shared format is mirrored in app-macos/Sources/AgentMarker.swift; keep
/// them in sync.
enum AgentMarker {
    /// Default 1 hour. Stale markers (process killed -9, machine reboot) are
    /// ignored on read so leaks self-heal.
    static let defaultTTL: TimeInterval = 3600

    static var directory: String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"
        return "\(home)/.immurok/markers"
    }

    static func path(forPid pid: Int32) -> String {
        "\(directory)/\(pid)"
    }

    /// Hard cap on the command string written into the marker — keeps the
    /// file well-bounded even if a runaway script gets wrapped.
    static let maxCommandLength = 1024

    /// Create the marker for the current process, recording an absolute expiry
    /// epoch and (optionally) the wrapped command for display in the auth
    /// overlay. Line 1 is the expiry epoch; line 2, when present, is the
    /// command as a single line (newlines stripped). File mode 0600 keeps
    /// other local users from fabricating markers under our PIDs.
    static func write(command: String? = nil, ttl: TimeInterval = defaultTTL) {
        let dir = directory
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let pid = getpid()
        let expiry = Int(Date().addingTimeInterval(ttl).timeIntervalSince1970)
        var content = "\(expiry)\n"
        if let raw = command, !raw.isEmpty {
            // Defensive: collapse newlines/tabs so the second line stays a
            // single logical token, then cap length.
            let collapsed = raw.replacingOccurrences(of: "\n", with: " ")
                               .replacingOccurrences(of: "\t", with: " ")
            let trimmed = String(collapsed.prefix(maxCommandLength))
            content += "\(trimmed)\n"
        }
        let p = path(forPid: pid)
        try? content.write(toFile: p, atomically: true, encoding: .utf8)
        chmod(p, 0o600)
    }

    /// Remove the marker for the current process. Safe to call multiple times.
    static func remove() {
        let p = path(forPid: getpid())
        try? FileManager.default.removeItem(atPath: p)
    }
}
