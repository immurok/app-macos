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

    func log(_ message: String) {
        let entry = LogEntry(timestamp: Date(), message: message)
        entries.append(entry)
        NSLog("%@", message)
    }

    func clear() {
        entries.removeAll()
    }
}
