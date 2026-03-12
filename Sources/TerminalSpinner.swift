/*
 * TerminalSpinner.swift - Animated fingerprint prompt for terminal
 *
 * Shows a spinning indicator while waiting for fingerprint verification.
 * Detects the client's TTY via LOCAL_PEERPID + ps.
 */

import Foundation

class TerminalSpinner {

    enum Result {
        case approved
        case tryAgain
        case timeout
    }

    private static let frames = ["⠖", "⠲", "⢲", "⢰", "⣰", "⣠", "⣄", "⣆", "⡆", "⡖"]

    private let ttyPath: String
    private var ttyHandle: FileHandle?
    private var isRunning = false
    private var generation = 0  // invalidates old animation loops
    private let message: String

    init?(clientSocket: Int32, message: String = "Please verify your fingerprint...") {
        guard let path = Self.findTTY(clientSocket: clientSocket) else { return nil }
        self.ttyPath = path
        self.message = message
    }

    /// Start the spinner animation (non-blocking, runs on background thread)
    /// Can be called to switch from signing animation to fingerprint prompt.
    func start() {
        guard ensureTTY() else { return }
        isRunning = false
        generation += 1
        let myGen = generation
        Thread.sleep(forTimeInterval: 0.1) // let old loop exit

        isRunning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var frame = 0
            while self.isRunning && self.generation == myGen {
                let spinner = Self.frames[frame % Self.frames.count]
                self.write("\r\u{1B}[K\u{1B}[33m\(spinner) \(self.message)\u{1B}[0m")
                frame += 1
                Thread.sleep(forTimeInterval: 0.08)
            }
        }
    }

    /// Show intermediate failure (wrong fingerprint) — spinner continues after
    func showTryAgain(remaining: Int) {
        let wasRunning = isRunning
        isRunning = false
        generation += 1  // immediately invalidate old spinner loop
        Thread.sleep(forTimeInterval: 0.1) // let old loop exit
        let s = remaining == 1 ? "" : "s"
        write("\r\u{1B}[K\u{1B}[31m✗ Not matched, \(remaining) attempt\(s) left\u{1B}[0m")
        Thread.sleep(forTimeInterval: 0.5)
        write("\r\u{1B}[K") // erase before restarting spinner
        if wasRunning {
            start()
        }
    }

    /// Transition to signing animation (can be called before or after start)
    func showSigning() {
        guard ensureTTY() else { return }
        isRunning = false
        generation += 1  // immediately invalidate old spinner loop
        let myGen = generation
        Thread.sleep(forTimeInterval: 0.1) // let old loop exit

        isRunning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var dots = 0
            while self.isRunning && self.generation == myGen {
                let n = (dots % 3) + 1
                let dotStr = String(repeating: ".", count: n)
                let pad = String(repeating: " ", count: 3 - n)
                self.write("\r\u{1B}[K\u{1B}[32m✓ Approved, now signing\(dotStr)\(pad)\u{1B}[0m")
                dots += 1
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
    }

    /// Stop the spinner silently (erase line, no message)
    func dismiss() {
        isRunning = false
        generation += 1
        Thread.sleep(forTimeInterval: 0.1)
        write("\r\u{1B}[K")
        ttyHandle?.closeFile()
        ttyHandle = nil
    }

    /// Stop the spinner and show final result
    func stop(_ result: Result) {
        isRunning = false
        generation += 1
        Thread.sleep(forTimeInterval: 0.1) // let animation loop exit

        switch result {
        case .approved:
            write("\r\u{1B}[K\u{1B}[32m✓ Approved!\u{1B}[0m")
        case .tryAgain:
            write("\r\u{1B}[K\u{1B}[31m✗ Try again\u{1B}[0m")
        case .timeout:
            write("\r\u{1B}[K\u{1B}[31m✗ Time out\u{1B}[0m")
        }

        Thread.sleep(forTimeInterval: 0.5)
        write("\r\u{1B}[K") // erase result line
        ttyHandle?.closeFile()
        ttyHandle = nil
    }

    // MARK: - Private

    private func ensureTTY() -> Bool {
        if ttyHandle == nil {
            ttyHandle = FileHandle(forWritingAtPath: ttyPath)
        }
        return ttyHandle != nil
    }

    private func write(_ text: String) {
        ttyHandle?.write(Data(text.utf8))
    }

    /// Find the controlling TTY of the peer process connected to a Unix socket
    static func findTTY(clientSocket: Int32) -> String? {
        var pid: pid_t = 0
        var pidLen = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(clientSocket, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidLen) == 0,
              pid > 0 else {
            return nil
        }

        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "tty=", "-p", "\(pid)"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let ttyName = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !ttyName.isEmpty, ttyName != "??" else {
            return nil
        }

        return ttyName.hasPrefix("/dev/") ? ttyName : "/dev/\(ttyName)"
    }
}
