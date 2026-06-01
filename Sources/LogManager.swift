import Foundation

@MainActor
class LogManager: ObservableObject {
    static let shared = LogManager()

    @Published var entries: [LogEntry] = []

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
        NSLog("%@", message)
        // Persist to ~/Library/Logs/immurok/immurok.log (append-only).
        let line = "\(Self.fileTimestampFormatter.string(from: now)) \(message)\n"
        FileLogger.append(line, toFileNamed: "immurok.log")
    }

    func clear() {
        entries.removeAll()
    }
}
