import Foundation

@MainActor
class LogManager: ObservableObject {
    static let shared = LogManager()

    @Published var entries: [LogEntry] = []

    /// 内存日志上限。超过 maxEntries + trimSlack 时一次裁到 maxEntries（摊销裁剪成本）。
    /// 完整历史在 ~/Library/Logs/immurok/immurok.log；内存这份只供诊断页显示，
    /// 不设上限时长期运行会无限增长，诊断页每来一条都整体重排，拖慢主线程。
    private static let maxEntries = 2000
    private static let trimSlack = 500

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
    }

    private static let fileTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    func log(_ message: String) {
        let now = Date()
        let entry = LogEntry(timestamp: now, message: message)
        entries.append(entry)
        if entries.count > Self.maxEntries + Self.trimSlack {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        NSLog("%@", message)
        // Persist to ~/Library/Logs/immurok/immurok.log (append, rotated at FileLogger.maxFileBytes).
        let line = "\(Self.fileTimestampFormatter.string(from: now)) \(message)\n"
        FileLogger.append(line, toFileNamed: "immurok.log")
    }

    func clear() {
        entries.removeAll()
    }
}
