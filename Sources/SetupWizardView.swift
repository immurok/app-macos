import SwiftUI
import AuthInjectionKit

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

    @State private var selectedFeatures: Set<SetupFeature> = [.screenUnlock]
    @State private var securing = false
    @State private var setupError: String?
    private var plan: SetupPlan { SetupPlan(features: selectedFeatures) }
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

    }

    /// 未完成也允许「跳过此步」的非关键步骤；PAM 步只在模块已装、仅 pam.d 配置缺时可跳过
    /// （先走完连接/配对/指纹引导，修复入口由设置页横幅与菜单/通知兜底），模块缺失时不可跳过。
    private func isSkippable(_ step: WizardStep) -> Bool {
        switch step {
        case .password, .fingerprint, .accessibility, .pam: return true
        default: return false
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
        .frame(width: 760, height: 620)
        // 始终置顶：向导会把用户支到「系统设置 → 蓝牙」「隐私与安全性 → 辅助功能」
        // 去操作，这些窗口一弹出来向导就被盖住，用户回不来、也看不到「已连接」的反馈。
        .background(WindowLevelSetter(level: .floating))
        .onAppear {
            setupManager.refreshStatus()
            if let saved = UserDefaults.standard.stringArray(forKey: "immurok.setup.features") {
                selectedFeatures = Set(saved.compactMap(SetupFeature.init(rawValue:)))
            }
            buildSteps()
        }
        .onChange(of: selectedFeatures) { _ in
            if currentStep == .welcome { buildSteps() }
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
        // pkg 安装的用户 PAM 必然已装；模块缺失（如手动拷贝 App）或 pam.d 缺行
        // （macOS 27 安装时 TCC 被拒 / 系统升级重置）才插入安装检查步
        s.append(contentsOf: [.connect, .pair, .fingerprint])
        if plan.needsPassword { s.append(.password) }
        if plan.needsAccessibility { s.append(.accessibility) }
        if plan.needsPAM { s.append(.pam) }
        s.append(.finish)
        steps = s
    }

    private func isSatisfied(_ step: WizardStep) -> Bool {
        switch step {
        case .welcome: return !selectedFeatures.isEmpty
        case .finish: return true
        case .pam:           return setupManager.isPAMModuleInstalled && !setupManager.needsPAMRepair && setupManager.pamKeyStatus == .installed
        case .connect:       return viewModel.isDeviceConnected
        case .pair:          return viewModel.isDevicePaired && viewModel.hasLocalPairing && viewModel.isDeviceVerified
        case .password:      return viewModel.isPasswordConfigured
        case .fingerprint:   return viewModel.fingerprintCount > 0
        case .accessibility: return setupManager.hasAccessibilityPermission
        }
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
        if currentStep == .welcome {
            buildSteps()
            UserDefaults.standard.set(selectedFeatures.map(\.rawValue).sorted(), forKey: "immurok.setup.features")
        }
        withAnimation { currentIndex += 1 }
    }

    private func goPrev() {
        suppressAutoAdvance = true
        guard currentIndex > 0 else { return }
        withAnimation { currentIndex -= 1 }
    }

    private func finishWizard() {
        if currentStep == .finish {
            let d = UserDefaults.standard
            let deviceReady = viewModel.isDeviceConnected && viewModel.isDeviceVerified && viewModel.fingerprintCount > 0
            if selectedFeatures.contains(.screenUnlock), deviceReady,
               viewModel.isPasswordConfigured, setupManager.hasAccessibilityPermission {
                d.set(true, forKey: "immurok.screenUnlockEnabled")
            }
            if selectedFeatures.contains(.administrator), deviceReady, isSatisfied(.pam) {
                setupManager.setSudoAuthEnabled(true)
                setupManager.setAuthorizationEnabled(true)
            }
            // SSH stays scoped to explicit clients. Do not replace the user's existing agent.
            if selectedFeatures.contains(.ssh), deviceReady {
                do {
                    try SSHAgentServer.shared.start()
                    d.set(true, forKey: "immurok.sshAgentEnabled")
                } catch { setupError = error.localizedDescription; return }
            }
        }
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        dismiss()
    }

    // MARK: - 侧栏

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                AppLogoView(size: 24)
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
        return Button {
            suppressAutoAdvance = true
            withAnimation { currentIndex = index }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: done ? "checkmark.circle.fill" : (isCurrent ? "circle.inset.filled" : "circle"))
                    .foregroundColor(done ? .green : (isCurrent ? .accentColor : .secondary))
                Text(step.titleKey.localized).font(.callout).fontWeight(isCurrent ? .semibold : .regular)
                Spacer()
            }.padding(.vertical, 5).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(index > currentIndex)
            .accessibilityLabel(step.titleKey.localized)
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
            } else if isSkippable(currentStep) {
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
        VStack(alignment: .leading, spacing: 16) {
            Text("experience.welcome.title".localized).font(.largeTitle.weight(.semibold))
            Text("experience.welcome.detail".localized).foregroundColor(.secondary)
            ForEach(SetupFeature.allCases, id: \.self) { feature in
                FeatureChoiceCard(feature: feature, selected: selectedFeatures.contains(feature)) {
                    if selectedFeatures.contains(feature) { selectedFeatures.remove(feature) }
                    else { selectedFeatures.insert(feature) }
                }
            }
            Label("experience.welcome.privacy".localized, systemImage: "hand.raised")
                .font(.callout).foregroundColor(.secondary)
            Text("experience.connection.note".localized).font(.caption).foregroundColor(.secondary)
        }
    }

    private var pamStep: some View {
        let pamOK = setupManager.isPAMModuleInstalled && !setupManager.needsPAMRepair && setupManager.pamKeyStatus == .installed
        return VStack(spacing: 20) {
            stepHeader(icon: pamOK ? "checkmark.circle.fill" : "exclamationmark.triangle",
                       title: "wizard.pam.title".localized,
                       iconColor: pamOK ? .green : .orange)

            if !setupManager.isPAMModuleInstalled {
                Text("wizard.pam.needpkg".localized)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                infoCard("wizard.pam.needpkg.hint".localized)
            } else if setupManager.needsPAMRepair {
                // 模块在、pam.d 缺行：安装时 TCC 被拒（或系统升级重置），一键打开修复包
                Text("wizard.pam.denied".localized)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                infoCard("wizard.pam.denied.hint".localized)
                Button("wizard.pam.repair".localized) {
                    setupManager.repairAuthorization { _, error in
                        guard let error = error else { return }   // 取消/拒绝：静默，提示条仍在
                        let alert = NSAlert()
                        alert.messageText = "notify.authrepair.title".localized
                        alert.informativeText = error
                        alert.runModal()
                    }
                }
                .buttonStyle(.borderedProminent)
            } else if setupManager.pamKeyStatus != .installed {
                Text("security.pam.required".localized).foregroundColor(.secondary)
                Button("experience.pam.configure".localized) {
                    securing = true; setupError = nil
                    setupManager.installPamKey { _, error in
                        securing = false; setupError = error
                    }
                }.buttonStyle(.borderedProminent).disabled(securing)
                if securing { ProgressView().controlSize(.small) }
                if let setupError { Text(setupError).foregroundColor(.red).font(.caption) }
            } else {
                statusLabel(ok: true, text: "security.pam.ready".localized)
            }
        }
    }

    private var connectStep: some View {
        VStack(spacing: 20) {
            stepHeader(iconView: BluetoothGlyph()
                            .stroke(Color.accentColor,
                                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                            .frame(width: 30, height: 48),
                       title: "wizard.connect.title".localized)

            // 这一页只放图、按钮和等待指示，不放解释性小字——字一多就没人看了。
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
                    //（建立系统级配对），App 之后才能发现并通信。图示：系统设置
                    // 里点「连接」，设备蓝灯慢闪。
                    DeviceIllustration(scene: .bluetoothConnect)

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

            if viewModel.isDevicePaired && viewModel.hasLocalPairing && viewModel.isDeviceVerified {
                statusLabel(ok: true, text: "wizard.pair.done".localized)
            } else if viewModel.isDevicePaired && viewModel.hasLocalPairing && !viewModel.isDeviceVerified {
                Text("experience.status.unverified.detail".localized).foregroundColor(.secondary)
                Button("experience.status.unverified.action".localized) { viewModel.openBluetoothPreferences() }
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
                // 这里**不**画「按按钮」的示意图：点「开始绑定」之前就把图亮出来，
                // 用户会先去按设备按钮，而设备此时根本没在等按键。图示只在点击
                // 之后的 PairingGuideSheet 里、设备真正等待动作时出现。
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

            Text("security.password.explanation".localized)
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
                // isLoading 也要挡：refresh 命中缓存会把 isLoading 复位，第二下点击
                // 就能再发一次 ENROLL_START，固件回 0xFD 反而把第一次录入判成失败。
                .disabled(!viewModel.isDeviceConnected || fpViewModel.isEnrolling || fpViewModel.isLoading)

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
        VStack(alignment: .leading, spacing: 18) {
            Text("experience.finish.title".localized).font(.largeTitle.weight(.semibold))
            Text("experience.finish.detail".localized).foregroundColor(.secondary)
            summaryRow(text: "wizard.step.connect".localized, ok: viewModel.isDeviceConnected)
            summaryRow(text: "wizard.step.pair".localized, ok: isSatisfied(.pair))
            summaryRow(text: "wizard.step.fingerprint".localized, ok: viewModel.fingerprintCount > 0)
            if plan.needsPassword { summaryRow(text: "wizard.step.password".localized, ok: viewModel.isPasswordConfigured) }
            if plan.needsAccessibility { summaryRow(text: "wizard.accessibility.title".localized, ok: setupManager.hasAccessibilityPermission) }
            if plan.needsPAM { summaryRow(text: "experience.pam.configure".localized, ok: isSatisfied(.pam)) }
            Divider()
            if selectedFeatures.contains(.screenUnlock) { Text("experience.finish.unlock".localized) }
            if selectedFeatures.contains(.administrator) { Text("experience.finish.admin".localized) }
            if selectedFeatures.contains(.ssh) {
                Text("experience.finish.ssh".localized)
                Text("SSH_AUTH_SOCK=\(SSHAgentServer.shared.socketPath) ssh-add -L")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Label("experience.finish.fallback".localized, systemImage: "key")
                .font(.callout).foregroundColor(.secondary)
            if let setupError { Text(setupError).foregroundColor(.red) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helper Views

    private func stepHeader(icon: String, title: String, iconColor: Color = .accentColor) -> some View {
        stepHeader(iconView: Image(systemName: icon)
                                .font(.system(size: 44))
                                .foregroundColor(iconColor),
                   title: title)
    }

    /// 自定义图标的步骤头（SF Symbols 没有的图形，如蓝牙标志）。
    private func stepHeader<Icon: View>(iconView: Icon, title: String) -> some View {
        VStack(spacing: 14) {
            iconView
                .frame(height: 52)
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
