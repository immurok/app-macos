import SwiftUI

// MARK: - Gate State

enum FingerprintGateState: Equatable {
    case waiting                       // Waiting for FP touch
    case attemptFailed(remaining: Int) // Single attempt failed
    case processing                    // FP approved, operation in progress (e.g. ECC keygen)
    case success                       // Operation completed
    case failed                        // All attempts exhausted or timeout
}

// MARK: - Gate Controller

@MainActor
class FingerprintGateController: ObservableObject {
    @Published var isPresented = false
    @Published var state: FingerprintGateState = .waiting
    @Published var countdown: Int = 30
    @Published var title: String = ""
    var successMessage: String?  // Custom success text (e.g. "生成成功"), nil = default

    static let timeout = 30

    private var countdownTask: Task<Void, Never>?
    private var autoDismissTask: Task<Void, Never>?
    private var previousAttemptFailedCallback: ((Int) -> Void)?
    private var previousGateApprovedCallback: (() -> Void)?
    private var callbackHooked = false
    private var onCancel: (() -> Void)?

    private let bleManager = BLEManager.shared

    // MARK: - Present

    /// Show gate sheet for FP verification, auto-dismiss on success
    func present(title: String, onCancel: (() -> Void)? = nil) {
        guard !isPresented else { return }
        self.title = title
        self.onCancel = onCancel
        self.state = .waiting
        self.countdown = Self.timeout
        self.isPresented = true
        hookAttemptCallback()
        startCountdown()
    }

    /// Called when fingerprintGateRequiredNotification fires — shows sheet if not already shown
    func onGateRequired() {
        guard !isPresented else { return }
        state = .waiting
        countdown = Self.timeout
        isPresented = true
        hookAttemptCallback()
        startCountdown()
    }

    // MARK: - State transitions

    func reportProcessing() {
        guard isPresented else { return }
        countdownTask?.cancel()
        state = .processing
    }

    func reportSuccess() {
        guard isPresented else { return }
        countdownTask?.cancel()
        state = .success
        // Quick dismiss (0.4s = icon transition 0.3s + brief dwell). 1.5s
        // would block any progress UI the caller pops up immediately after
        // FP success — common pattern for import/delete/export batches.
        scheduleAutoDismiss(0.4)
    }

    func reportFailed() {
        guard isPresented else { return }
        if case .failed = state { return }
        state = .failed
        countdownTask?.cancel()
        // Keep 1.5s for failure — user needs time to read the reason.
        scheduleAutoDismiss(1.5)
    }

    func cancel() {
        let cb = onCancel
        cleanup()
        isPresented = false
        // 必须用 cancelGateAndRelease 而不是 cancelGate, 否则 ENROLL_START /
        // DELETE_FP / KEY_SIGN / AUTH_REQUEST 等返回 WAIT_FP 后 hold 住的
        // 命令队列让 gateCancel 进队不出队, 固件不知道要取消.
        bleManager.cancelGateAndRelease()
        cb?()
    }

    func reset() {
        // 防御性: 任何 reset 路径 (断连等) 都发一次 cancel.
        // cancelGateAndRelease 内部 guard isConnected, 断连时 no-op 安全.
        bleManager.cancelGateAndRelease()
        cleanup()
        isPresented = false
    }

    // MARK: - Private

    private func hookAttemptCallback() {
        guard !callbackHooked else { return }
        callbackHooked = true
        previousAttemptFailedCallback = bleManager.onFingerprintAttemptFailed
        previousGateApprovedCallback = bleManager.onFingerprintGateApproved
        bleManager.onFingerprintAttemptFailed = { [weak self] remaining in
            Task { @MainActor in
                guard let self = self, self.isPresented else { return }
                if remaining <= 0 {
                    self.state = .failed
                    self.countdownTask?.cancel()
                    self.scheduleAutoDismiss(1.5)
                } else {
                    self.state = .attemptFailed(remaining: remaining)
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        if case .attemptFailed = self.state {
                            self.state = .waiting
                        }
                    }
                }
            }
        }
        bleManager.onFingerprintGateApproved = { [weak self] in
            Task { @MainActor in
                self?.reportProcessing()
            }
        }
    }

    private func cleanup() {
        countdownTask?.cancel()
        autoDismissTask?.cancel()
        if callbackHooked {
            bleManager.onFingerprintAttemptFailed = previousAttemptFailedCallback
            bleManager.onFingerprintGateApproved = previousGateApprovedCallback
            previousAttemptFailedCallback = nil
            previousGateApprovedCallback = nil
            callbackHooked = false
        }
        onCancel = nil
        successMessage = nil
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { @MainActor [weak self] in
            while let self = self, self.countdown > 0, self.isPresented {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard self.isPresented, !Task.isCancelled else { return }
                self.countdown -= 1
            }
        }
    }

    private func scheduleAutoDismiss(_ seconds: TimeInterval) {
        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self = self, !Task.isCancelled else { return }
            self.cleanup()
            self.isPresented = false
        }
    }
}

// MARK: - Gate Sheet View

struct FingerprintGateSheet: View {
    @ObservedObject var controller: FingerprintGateController

    private var progress: CGFloat {
        CGFloat(controller.countdown) / CGFloat(FingerprintGateController.timeout)
    }

    private var ringColor: Color {
        switch controller.state {
        case .success: return .green
        case .failed: return .red
        case .attemptFailed: return .orange
        case .processing: return .green
        case .waiting: return progress > 0.17 ? .accentColor : .red
        }
    }

    private var iconName: String {
        switch controller.state {
        case .success: return "checkmark"
        case .failed: return "xmark"
        case .processing: return "checkmark"
        default: return "touchid"
        }
    }

    private var iconColor: Color {
        switch controller.state {
        case .success: return .green
        case .failed: return .red
        case .attemptFailed: return .orange
        case .processing: return .green
        default: return .accentColor
        }
    }

    private var statusText: String {
        switch controller.state {
        case .waiting:
            return "fingerprint.verify.required".localized
        case .attemptFailed(let remaining):
            return "gate.attempt.remaining".localized(remaining)
        case .processing:
            return "gate.processing".localized
        case .success:
            return controller.successMessage ?? "fingerprint.test.success".localized
        case .failed:
            return "fingerprint.test.failed".localized
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(controller.title)
                .font(.headline)

            // Circular countdown + icon
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 4)
                    .frame(width: 100, height: 100)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 100, height: 100)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: controller.countdown)

                Image(systemName: iconName)
                    .font(.system(size: 40))
                    .foregroundColor(iconColor)
                    .animation(.easeInOut(duration: 0.3), value: controller.state)
            }

            Text(statusText)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // Buttons
            switch controller.state {
            case .waiting, .attemptFailed:
                Button("alert.cancel".localized) {
                    controller.cancel()
                }
                .keyboardShortcut(.cancelAction)

            case .processing:
                ProgressView()
                    .controlSize(.small)

            case .success, .failed:
                EmptyView()
            }
        }
        .padding(32)
        .frame(width: 280, height: 320)
        .interactiveDismissDisabled()
        .onDisappear {
            // 防御性: sheet 因外部原因关闭 (主窗口被 ⌘W / app 进程异常退出 /
            // 上层 isPresented 被直接 reset) 时, 如果固件还在 waiting 状态,
            // 主动发 GATE_CANCEL 避免固件 pending_cmd 一直挂着. processing
            // 表示固件已 ack 命令开始 EXEC, success/failed 表示已自然结束.
            switch controller.state {
            case .waiting, .attemptFailed:
                BLEManager.shared.cancelGateAndRelease()
            case .processing, .success, .failed:
                break
            }
        }
    }
}
