import Foundation

/// Context for SSH/secret fingerprint gates, regardless of manual or agent origin.
/// Shows only when the device requests a touch. Requester identity is a process
/// snapshot; command text is informational, not an authorization boundary.
/// All UI calls hop to the main actor; gate state is protected by a lock.
final class AgentGateOverlaySession {
    /// What the overlay prints as the command line.
    private let requester: ApprovalRequester
    private let command: String
    private let service: String
    private let kind: AuthRequestKind
    private let onReject: () -> Void
    private let lock = NSLock()
    private var shown = false
    private var finished = false

    /// The optional initializer is retained for existing call sites.
    /// `fallbackCommand` is used when the chain carries no `imk run --agent`
    /// marker (heuristic agent-binary match only), so the user still sees
    /// what the touch is for.
    init?(
        socketFD: Int32,
        service: String,
        fallbackCommand: String,
        kind: AuthRequestKind,
        onReject: @escaping () -> Void
    ) {
        let caller = AuthCallerClassifier.classify(socketFD: socketFD)
        switch caller {
        case .agent(let cmd):
            self.command = cmd ?? fallbackCommand
        case .manual:
            self.command = fallbackCommand
        }
        self.requester = ApprovalRequester.capture(socketFD: socketFD)
        self.service = service
        self.kind = kind
        self.onReject = onReject
    }

    /// Device replied WAIT_FP — a real touch is needed. Idempotent.
    func gateRequired() {
        lock.lock()
        let alreadyShown = shown || finished
        shown = true
        lock.unlock()
        guard !alreadyShown else { return }

        let requester = self.requester
        let command = self.command
        let service = self.service
        let kind = self.kind
        let onReject = self.onReject
        Task { @MainActor in
            LogManager.shared.log("gate overlay: \(service) shown")
            AuthRequestOverlay.shared.show(
                user: NSUserName(),
                service: service,
                command: command,
                kind: kind,
                requester: requester,
                timeout: 30.0,
                onReject: onReject
            )
        }
    }

    func attemptFailed(remaining: Int) {
        guard isShown else { return }
        Task { @MainActor in AuthRequestOverlay.shared.reportRetry(remaining: remaining) }
    }

    /// Terminal state. No-op unless the overlay was actually shown, so a
    /// cooldown-covered gate never flashes a panel. Idempotent.
    func finish(_ status: AuthRequestState.Status) {
        lock.lock()
        let shouldDismiss = shown && !finished
        finished = true
        lock.unlock()
        guard shouldDismiss else { return }
        Task { @MainActor in AuthRequestOverlay.shared.dismiss(status: status) }
    }

    private var isShown: Bool {
        lock.lock(); defer { lock.unlock() }
        return shown
    }
}
