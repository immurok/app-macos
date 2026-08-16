import SwiftUI

// MARK: - Gate State

enum FingerprintGateState: Equatable {
    case waiting                       // Waiting for FP touch
    case attemptFailed(remaining: Int) // Single attempt failed
    case processing                    // FP approved, operation in progress (e.g. ECC keygen)
    case success                       // Operation completed
    case failed                        // All attempts exhausted or timeout
}

/// 门失败的原因。「按错手指三次」「30 秒没碰」「设备断了」的处置方式
/// 完全不同，failed 态必须分开告诉用户，不能共用一句「识别失败或超时」。
enum GateFailureReason {
    case attempts      // 尝试次数耗尽
    case timeout       // 倒计时归零，没有指纹触摸
    case disconnected  // 设备断连
    case generic       // 其他（调用方只拿到 success=false）
}

// MARK: - Gate Controller

@MainActor
class FingerprintGateController: ObservableObject {
    @Published var isPresented = false
    @Published var state: FingerprintGateState = .waiting
    @Published var countdown: Int = 30
    @Published var title: String = ""
    @Published var failureReason: GateFailureReason = .generic
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
        self.failureReason = .generic
        self.countdown = Self.timeout
        self.isPresented = true
        hookAttemptCallback()
        startCountdown()
    }

    /// Called when fingerprintGateRequiredNotification fires — shows sheet if not already shown
    func onGateRequired() {
        guard !isPresented else { return }
        state = .waiting
        failureReason = .generic
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

    func reportFailed(reason: GateFailureReason = .generic) {
        guard isPresented else { return }
        if case .failed = state { return }
        // 断连时各调用方只拿到 success=false —— 在失败瞬间看连接状态，
        // 能把「设备断了」从「识别失败」里区分出来。
        if reason == .generic && !bleManager.deviceState.isConnected {
            failureReason = .disconnected
        } else {
            failureReason = reason
        }
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

    /// 门禁已**成功**解决后的收尾 (例如 ENROLL_START 解锁、首次登记无门禁)。
    /// 不发 GATE_CANCEL —— 固件侧 pending 已被指纹匹配清掉 (或从未开门禁),
    /// 再发 cancel 会触发固件红灯 1s, 盖掉接下来 enroll 的绿色采集闪烁
    /// (即"验证后闪红 + 第 1 次采集无绿闪"的 App 侧成因)。
    func resolveAndDismiss() {
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
                    self.reportFailed(reason: .attempts)
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
            // 归零本地直接判超时。真正的超时源是 BLE 侧 30s 定时器，但两套
            // 时钟有偏差时，用户会看到红环空转、文字停在「请验证指纹」。
            guard let self = self, self.isPresented, !Task.isCancelled else { return }
            switch self.state {
            case .waiting, .attemptFailed:
                self.reportFailed(reason: .timeout)
            case .processing, .success, .failed:
                break
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
            switch controller.failureReason {
            case .attempts: return "gate.failed.attempts".localized
            case .timeout: return "gate.failed.timeout".localized
            case .disconnected: return "gate.failed.disconnected".localized
            case .generic: return "fingerprint.test.failed".localized
            }
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
