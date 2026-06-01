import Foundation

/// Shared append-only file logger. Writes are serialized on a utility-QoS
/// queue so logging never blocks the main thread; each line is flushed to
/// disk individually so no entries are lost on crash. Files live in
/// `~/Library/Logs/immurok/` (the macOS convention for app logs — visible
/// in Console.app via File → Open System Log... → custom path).
enum FileLogger {
    private static let writerQueue = DispatchQueue(label: "com.immurok.filelogger", qos: .utility)

    static let logDirectory: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/immurok", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Append a line to the named log file (creates the file if absent).
    /// Caller is responsible for terminating with `\n` if line-orientation
    /// is desired.
    static func append(_ line: String, toFileNamed name: String) {
        let url = logDirectory.appendingPathComponent(name)
        writerQueue.async {
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                guard let handle = try? FileHandle(forWritingTo: url) else { return }
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

/// Battery sample log writer. Format: `YYYY-MM-DD HH:MM:SS,pct,mv` per line.
/// Used by AppViewModel's 5-min sampling timer.
enum BatteryLogger {
    static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    static func record(pct: Int, mv: Int) {
        let ts = timestampFormatter.string(from: Date())
        FileLogger.append("\(ts),\(pct),\(mv)\n", toFileNamed: "ik-batt.log")
    }
}
