import Foundation

/// Shared append-only file logger. Writes are serialized on a utility-QoS
/// queue so logging never blocks the main thread; each line is flushed to
/// disk individually so no entries are lost on crash. Files live in
/// `~/Library/Logs/immurok/` (the macOS convention for app logs — visible
/// in Console.app via File → Open System Log... → custom path).
enum FileLogger {
    private static let writerQueue = DispatchQueue(label: "com.immurok.filelogger", qos: .utility)

    /// 单个日志文件上限。超过后轮转为 `<name>.1`（覆盖旧的 .1），最多占 2 倍空间。
    static let maxFileBytes: UInt64 = 5 * 1024 * 1024

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
            // 清理工具会把整个 ~/Library/Logs/immurok 删掉；目录只在首次访问时建一次，
            // 之后每次写入都静默失败，直到重启 App。写之前确认目录还在。
            if !FileManager.default.fileExists(atPath: logDirectory.path) {
                try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            }
            if FileManager.default.fileExists(atPath: url.path) {
                guard let handle = try? FileHandle(forWritingTo: url) else { return }
                let size = (try? handle.seekToEnd()) ?? 0
                try? handle.write(contentsOf: data)
                try? handle.close()
                if size + UInt64(data.count) > maxFileBytes {
                    let rotated = logDirectory.appendingPathComponent(name + ".1")
                    try? FileManager.default.removeItem(at: rotated)
                    try? FileManager.default.moveItem(at: url, to: rotated)
                }
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
