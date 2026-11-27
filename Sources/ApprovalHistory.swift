import SwiftUI

/// Session-only history intentionally stores no command, username, executable
/// path, key name or secret. Nothing is written to disk or sent over the network.
@MainActor
final class ApprovalHistory: ObservableObject {
    static let shared = ApprovalHistory()
    struct Event: Identifiable {
        let id = UUID()
        let date: Date
        let categoryKey: String
        let outcomeKey: String
    }
    @Published private(set) var events: [Event] = []
    func record(service: String, status: AuthRequestState.Status) {
        let category: String
        switch service {
        case "sudo", "sudo_local", "authorization", "auth-gui": category = "admin"
        case "ssh-agent": category = "ssh"
        case "imk-cli": category = "secret"
        default: category = "command"
        }
        let outcome: String
        switch status {
        case .approved: outcome = "approved"
        case .denied: outcome = "denied"
        case .timedOut: outcome = "timedOut"
        default: return
        }
        events.insert(Event(date: Date(), categoryKey: "experience.history.\(category)",
                            outcomeKey: "experience.history.\(outcome)"), at: 0)
        events = Array(events.prefix(50))
    }
    func clear() { events.removeAll() }
}

struct ApprovalHistoryView: View {
    @ObservedObject private var history = ApprovalHistory.shared
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("experience.history.title".localized, systemImage: "clock.arrow.circlepath").font(.headline)
                    Spacer()
                    Button("experience.history.clear".localized) { history.clear() }.disabled(history.events.isEmpty)
                }
                Text("experience.history.privacy".localized).font(.caption).foregroundColor(.secondary)
                if history.events.isEmpty {
                    Text("experience.history.empty".localized).font(.callout).foregroundColor(.secondary)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(history.events) { event in
                                HStack {
                                    Text(event.date, style: .time).monospacedDigit().foregroundColor(.secondary)
                                    Text(event.categoryKey.localized)
                                    Spacer()
                                    Text(event.outcomeKey.localized)
                                }.font(.caption)
                            }
                        }
                    }.frame(maxHeight: 140)
                }
            }.padding(4)
        }
    }
}
