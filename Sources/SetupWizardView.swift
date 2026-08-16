import SwiftUI

/// 首次运行引导：从小白视角带用户走完「连接 → 配对 → 密码 → 指纹 → 权限」全流程。
/// - 步骤列表动态生成（PAM 已装则不出现安装检查步）
/// - 每步状态自动检测：完成后自动前进；启动时跳到第一个未完成步
/// - 密码/指纹可「跳过此步」，整个引导可「稍后再说」；完成或跳过后写
///   immurok.setup.completed，之后仅关键项缺失（PAM/辅助功能）才再唤起
struct SetupWizardView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var setupManager = SetupManager.shared
    @ObservedObject var localization = LocalizationManager.shared
    @StateObject private var fpViewModel = FingerprintViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var steps: [WizardStep] = []
    @State private var currentIndex = 0
    /// 用户点了「上一步」后暂停自动前进，避免回看已完成步骤时被立刻弹回
    @State private var suppressAutoAdvance = false
    /// 状态轮询（PAM 文件 / AXIsProcessTrusted 无推送，需要拉）
    private let pollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    static let completedKey = "immurok.setup.completed"

    enum WizardStep: Equatable {
        case welcome, pam, connect, pair, password, fingerprint, accessibility, finish

        var titleKey: String {
            switch self {
            case .welcome:       return "wizard.step.welcome"
            case .pam:           return "wizard.step.install"
            case .connect:       return "wizard.step.connect"
            case .pair:          return "wizard.step.pair"
            case .password:      return "wizard.step.password"
            case .fingerprint:   return "wizard.step.fingerprint"
            case .accessibility: return "wizard.step.accessibility"
            case .finish:        return "wizard.step.finish"
            }
        }

        var icon: String {
            switch self {
            case .welcome:       return "hand.wave"
            case .pam:           return "puzzlepiece.extension"
            case .connect:       return "antenna.radiowaves.left.and.right"
            case .pair:          return "link"
            case .password:      return "key"
            case .fingerprint:   return "touchid"
            case .accessibility: return "hand.raised"
            case .finish:        return "checkmark.seal"
            }
        }

        /// 未完成也允许「跳过此步」的非关键步骤
        var isSkippable: Bool {
            self == .password || self == .fingerprint
        }
    }

    private var currentStep: WizardStep {
        steps.indices.contains(currentIndex) ? steps[currentIndex] : .finish
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebarView
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    stepContent
                        .padding(28)
                        .frame(maxWidth: .infinity)
                }
                Divider()
                footerView
            }
        }
        .frame(width: 680, height: 500)
        .onAppear {
            setupManager.refreshStatus()
            buildSteps()
            jumpToFirstIncomplete()
        }
        .onReceive(pollTimer) { _ in
            // PAM/辅助功能没有变更推送，轮询刷新；其余状态由 @Published 驱动
            if currentStep == .pam || currentStep == .accessibility {
                setupManager.refreshStatus()
            }
            autoAdvanceIfSatisfied()
        }
        .sheet(isPresented: $fpViewModel.isEnrolling) {
            EnrollmentSheet(viewModel: fpViewModel)
        }
        .sheet(isPresented: $fpViewModel.gateController.isPresented) {
            FingerprintGateSheet(controller: fpViewModel.gateController)
        }
        // 配对分步引导：设置页早就用上了（PairingGuideView 注释里描述的
        // 「一行小字读不出两步」正是本向导原来的样子），新用户唯一入口
        // 必须享受同等待遇。
        .sheet(isPresented: $viewModel.isPairing) {
            PairingGuideSheet(viewModel: viewModel)
        }
    }

    // MARK: - 步骤构建 / 前进逻辑

    private func buildSteps() {
        var s: [WizardStep] = [.welcome]
        // pkg 安装的用户 PAM 必然已装；缺失（如手动拷贝 App）才插入安装检查步
        if !setupManager.isPAMModuleInstalled { s.append(.pam) }
        s.append(contentsOf: [.connect, .pair, .password, .fingerprint, .accessibility, .finish])
        steps = s
    }

    private func isSatisfied(_ step: WizardStep) -> Bool {
        switch step {
        case .welcome, .finish: return true
        case .pam:           return setupManager.isPAMModuleInstalled
        case .connect:       return viewModel.isDeviceConnected
        case .pair:          return viewModel.isDevicePaired
        case .password:      return viewModel.isPasswordConfigured
        case .fingerprint:   return viewModel.fingerprintCount > 0
        case .accessibility: return setupManager.hasAccessibilityPermission
        }
    }

    /// 启动时直接跳到第一个未完成的步骤（欢迎页仅在全新安装时展示）
    private func jumpToFirstIncomplete() {
        guard let first = steps.firstIndex(where: { $0 != .welcome && $0 != .finish && !isSatisfied($0) })
        else {
            currentIndex = steps.count - 1  // 全部完成 → 完成页
            return
        }
        // 什么都没配过（连接步就未完成）→ 从欢迎页开始；否则续接进度
        currentIndex = (steps[first] == .connect || steps[first] == .pam) ? 0 : first
    }

    private func autoAdvanceIfSatisfied() {
        guard !suppressAutoAdvance,
              currentStep != .welcome, currentStep != .finish,
              isSatisfied(currentStep) else { return }
        withAnimation { currentIndex += 1 }
    }

    private func goNext() {
        suppressAutoAdvance = false
        guard currentIndex < steps.count - 1 else { return }
        withAnimation { currentIndex += 1 }
    }

    private func goPrev() {
        suppressAutoAdvance = true
        guard currentIndex > 0 else { return }
        withAnimation { currentIndex -= 1 }
    }

    private func finishWizard() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        dismiss()
    }

    // MARK: - 侧栏

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "touchid")
                    .font(.system(size: 20))
                    .foregroundColor(.accentColor)
                Text("immurok")
                    .font(.headline)
            }
            .padding(.bottom, 16)

            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                sidebarRow(index: index, step: step)
            }

            Spacer()
        }
        .padding(16)
        .frame(width: 190)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func sidebarRow(index: Int, step: WizardStep) -> some View {
        let done = step != .welcome && step != .finish && isSatisfied(step)
        let isCurrent = index == currentIndex
        return HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : (isCurrent ? "circle.inset.filled" : "circle"))
                .font(.system(size: 12))
                .foregroundColor(done ? .green : (isCurrent ? .accentColor : .secondary.opacity(0.5)))
            Text(step.titleKey.localized)
                .font(.callout)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundColor(isCurrent ? .primary : .secondary)
            Spacer()
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            // 允许点侧栏回看，等价「上一步」语义（暂停自动前进）
            suppressAutoAdvance = index < currentIndex
            withAnimation { currentIndex = index }
        }
    }

    // MARK: - 底栏

    private var footerView: some View {
        HStack {
            if currentStep != .finish {
                Button("wizard.skip.later".localized) {
                    finishWizard()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .font(.callout)
            }

            Spacer()

            if currentIndex > 0 && currentStep != .finish {
                Button("wizard.prev".localized) { goPrev() }
                    .buttonStyle(.bordered)
            }

            if currentStep == .finish {
                Button("wizard.done".localized) { finishWizard() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else if isSatisfied(currentStep) {
                Button("wizard.next".localized) { goNext() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else if currentStep.isSkippable {
                Button("wizard.skip.step".localized) { goNext() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
    }

    // MARK: - 步骤内容

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .welcome:       welcomeStep
        case .pam:           pamStep
        case .connect:       connectStep
        case .pair:          pairStep
        case .password:      passwordStep
        case .fingerprint:   fingerprintStep
        case .accessibility: accessibilityStep
        case .finish:        finishStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            stepHeader(icon: "hand.wave", title: "wizard.welcome".localized)

            Text("wizard.intro".localized)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                featureRow(icon: "lock.open", text: "wizard.feature.unlock".localized)
                featureRow(icon: "terminal", text: "wizard.feature.sudo".localized)
                featureRow(icon: "gearshape", text: "wizard.feature.system".localized)
            }
            .padding(.vertical, 8)

            infoCard("wizard.welcome.needs".localized)

            Text("wizard.welcome.time".localized)
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }

    private var pamStep: some View {
        VStack(spacing: 20) {
            stepHeader(icon: setupManager.isPAMModuleInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle",
                       title: "wizard.pam.title".localized,
                       iconColor: setupManager.isPAMModuleInstalled ? .green : .orange)

            if setupManager.isPAMModuleInstalled {
                statusLabel(ok: true, text: "wizard.pam.installed".localized)
            } else {
                Text("wizard.pam.needpkg".localized)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                infoCard("wizard.pam.needpkg.hint".localized)
            }
        }
    }

    private var connectStep: some View {
        VStack(spacing: 20) {
            stepHeader(icon: "antenna.radiowaves.left.and.right", title: "wizard.connect.title".localized)

            Text("wizard.connect.body".localized)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            switch viewModel.bluetoothStatus {
            case .denied:
                statusLabel(ok: false, text: "wizard.connect.bt.denied".localized)
                Button("wizard.connect.bt.open".localized) {
                    viewModel.openBluetoothSettings()
                }
                .buttonStyle(.borderedProminent)
            case .poweredOff:
                statusLabel(ok: false, text: "wizard.connect.bt.off".localized)
                Button("wizard.connect.bt.open".localized) {
                    viewModel.openBluetoothPreferences()
                }
                .buttonStyle(.borderedProminent)
            default:
                if viewModel.isDeviceConnected {
                    statusLabel(ok: true,
                                text: "wizard.connect.connected".localized(viewModel.deviceName ?? "immurok IK-1"))
                } else {
                    // 设备是 BLE HID 键盘：必须先在系统蓝牙设置里手动连接一次
                    //（建立系统级配对），App 之后才能发现并通信
                    VStack(alignment: .leading, spacing: 8) {
                        Text("wizard.connect.step1".localized)
                        Text("wizard.connect.step2".localized)
                        Text("wizard.connect.step3".localized)
                    }
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)

                    Button("wizard.connect.bt.open".localized) {
                        viewModel.openBluetoothPreferences()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("wizard.connect.searching".localized)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var pairStep: some View {
        VStack(spacing: 20) {
            stepHeader(icon: "link", title: "wizard.pair.title".localized)

            Text("wizard.pair.body".localized)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if viewModel.isDevicePaired {
                statusLabel(ok: true, text: "wizard.pair.done".localized)
            } else if viewModel.isPairing || viewModel.isPreparingPairing {
                VStack(spacing: 12) {
                    ProgressView()
                    // 配对过程实时提示（如「请按一下设备按键确认」）
                    Text(viewModel.pairingPrompt ?? "pairing.in.progress".localized)
                        .font(.headline)
                        .foregroundColor(.accentColor)
                }
                .padding(.vertical, 8)
            } else {
                Button("wizard.pair.start".localized) {
                    viewModel.startPairing()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.isDeviceConnected)

                if !viewModel.isDeviceConnected {
                    statusLabel(ok: false, text: "wizard.pair.need.connect".localized)
                }
            }
        }
    }

    private var passwordStep: some View {
        VStack(spacing: 20) {
            stepHeader(icon: "key", title: "wizard.password.title".localized)

            Text("wizard.password.body".localized)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            infoCard("wizard.password.privacy".localized)

            if viewModel.isPasswordConfigured {
                statusLabel(ok: true, text: "wizard.password.done".localized)
            } else {
                Button("wizard.password.set".localized) {
                    viewModel.configurePassword()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.isDevicePaired)
            }
        }
    }

    private var fingerprintStep: some View {
        VStack(spacing: 20) {
            stepHeader(icon: "touchid", title: "wizard.fp.title".localized)

            Text("wizard.fp.body".localized)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if viewModel.fingerprintCount > 0 {
                statusLabel(ok: true, text: "wizard.fp.done".localized(viewModel.fingerprintCount))
            } else {
                Button("wizard.fp.start".localized) {
                    // 等 refresh 回调后再取槽位：缓存未命中时 isLoading 会挡住
                    // enrollFingerprint，原来的同步写法点第一下永远没反应。
                    // 只取认证槽（nextAvailableSlot 会把第 6 号切换槽也算进来）。
                    fpViewModel.refresh { [weak fpViewModel] in
                        guard let fpViewModel = fpViewModel else { return }
                        if let slot = fpViewModel.nextAvailableAuthSlot {
                            fpViewModel.enrollFingerprint(slot: slot)
                        } else {
                            NSLog("SetupWizard: no available auth slot after refresh")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.isDeviceConnected || fpViewModel.isEnrolling)

                infoCard("wizard.fp.hint".localized)
            }
        }
    }

    private var accessibilityStep: some View {
        VStack(spacing: 20) {
            stepHeader(icon: setupManager.hasAccessibilityPermission ? "checkmark.circle.fill" : "hand.raised",
                       title: "wizard.accessibility.title".localized,
                       iconColor: setupManager.hasAccessibilityPermission ? .green : .accentColor)

            if setupManager.hasAccessibilityPermission {
                statusLabel(ok: true, text: "wizard.accessibility.granted".localized)
            } else {
                Text("wizard.accessibility.description".localized)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 8) {
                    Text("wizard.accessibility.steps".localized)
                        .font(.callout)
                        .fontWeight(.medium)
                    Text("wizard.accessibility.step1".localized)
                    Text("wizard.accessibility.step2".localized)
                    Text("wizard.accessibility.step3".localized)
                }
                .font(.callout)
                .foregroundColor(.secondary)
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)

                Button("alert.authorize".localized) {
                    setupManager.requestAccessibilityPermission()
                    setupManager.openAccessibilitySettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var finishStep: some View {
        VStack(spacing: 20) {
            stepHeader(icon: "checkmark.seal.fill", title: "wizard.complete.title".localized, iconColor: .green)

            Text("wizard.complete.message".localized)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                summaryRow(text: "wizard.step.connect".localized, ok: viewModel.isDeviceConnected)
                summaryRow(text: "wizard.step.pair".localized, ok: viewModel.isDevicePaired)
                summaryRow(text: "wizard.step.password".localized, ok: viewModel.isPasswordConfigured)
                summaryRow(text: "wizard.step.fingerprint".localized, ok: viewModel.fingerprintCount > 0)
                summaryRow(text: "wizard.accessibility.title".localized, ok: setupManager.hasAccessibilityPermission)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            VStack(alignment: .leading, spacing: 8) {
                Text("wizard.try.title".localized)
                    .font(.callout)
                    .fontWeight(.medium)
                Label("wizard.try.unlock".localized, systemImage: "lock.open")
                Label("wizard.try.sudo".localized, systemImage: "terminal")
            }
            .font(.callout)
            .foregroundColor(.secondary)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08))
            .cornerRadius(8)

            Text("wizard.menubar.note".localized)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Helper Views

    private func stepHeader(icon: String, title: String, iconColor: Color = .accentColor) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(iconColor)
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
        }
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundColor(.accentColor)
            Text(text)
        }
    }

    private func statusLabel(ok: Bool, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundColor(ok ? .green : .orange)
            Text(text)
                .foregroundColor(ok ? .green : .orange)
        }
        .font(.headline)
    }

    private func summaryRow(text: String, ok: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(ok ? .green : .secondary)
            Text(text)
            Spacer()
        }
    }

    private func infoCard(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.leading)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
    }
}
