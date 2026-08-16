import SwiftUI

/// 配对引导框。
///
/// 存在的理由：登记第二台主机是**两个物理动作**（按指纹 → 按设备按钮），
/// 而原来只有一行小字提示，用户读不出那是两步，按完指纹就干等着，直到
/// 30 秒超时。这里把两步画成清单，当前该做哪一步一目了然。
///
/// 每一步的推进都由设备通知驱动（`0x34` 的 0x03 / 0x01），**不猜**：
/// 猜出来的勾会在用户还没按指纹时就点亮，比没有引导更糟。
///
/// 首次配对只有按键一步，此时清单只画一行，不硬凑成两步。
struct PairingGuideSheet: View {
    @ObservedObject var viewModel: AppViewModel

    @State private var pulse: CGFloat = 1.0

    private var steps: [Step] {
        var out: [Step] = []
        if viewModel.pairingNeedsFingerprint {
            out.append(Step(index: .waitingFingerprint,
                            symbol: "touchid",
                            title: "pairing.guide.step.fp".localized,
                            detail: "pairing.guide.step.fp.detail".localized))
        }
        out.append(Step(index: .waitingButton,
                        symbol: "button.horizontal.top.press",
                        title: "pairing.guide.step.button".localized,
                        detail: "pairing.guide.step.button.detail".localized))
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("pairing.guide.title".localized)
                .font(.headline)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(steps) { step in
                    row(step)
                }
            }

            Divider()

            HStack(spacing: 8) {
                if viewModel.pairingStep == .computing {
                    ProgressView().controlSize(.small)
                    Text("pairing.guide.working".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("pairing.guide.cancelhint".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
        .padding(24)
        .frame(width: 400)
        // Esc 只会关掉这层 UI（isPairing 被掰成 false），BLE 配对状态机
        // 还在后台跑：用户以为取消了，稍后误碰设备按钮流程会「复活」并
        // 凭空弹结果框。App 侧取消路径见 cancelhint（长按按钮/等 30 秒）。
        .interactiveDismissDisabled()
        .onAppear {
            // repeatForever 挂在 .animation(_:value:) 上、触发值在下一个
            // runloop 才改 —— 直接在 onAppear 里 withAnimation 会把 sheet
            // 呈现时「内容落位」那段位移也一起循环，整个框来回飘。
            // 与 EnrollmentSheet 同样的处理。
            DispatchQueue.main.async { pulse = 1.35 }
        }
    }

    private func row(_ step: Step) -> some View {
        let state = state(of: step.index)
        return HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(state == .done ? Color.green.opacity(0.15)
                                         : Color.accentColor.opacity(state == .active ? 0.15 : 0.06))
                    .frame(width: 40, height: 40)

                if state == .active {
                    Circle()
                        .stroke(Color.accentColor.opacity(0.35), lineWidth: 2)
                        .frame(width: 40, height: 40)
                        .scaleEffect(pulse)
                        .opacity(2.0 - Double(pulse))
                        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                                   value: pulse)
                }

                Image(systemName: state == .done ? "checkmark" : step.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(state == .done ? .green
                                     : state == .active ? .accentColor : .secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.callout)
                    .fontWeight(state == .active ? .semibold : .regular)
                    .foregroundColor(state == .pending ? .secondary : .primary)
                Text(step.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 每一步的三态

    private enum StepState { case pending, active, done }

    private func state(of index: AppViewModel.PairingGuideStep) -> StepState {
        let current = viewModel.pairingStep.rawValue
        if current > index.rawValue { return .done }
        if current == index.rawValue { return .active }
        return .pending
    }

    private struct Step: Identifiable {
        let index: AppViewModel.PairingGuideStep
        let symbol: String
        let title: String
        let detail: String
        var id: Int { index.rawValue }
    }
}
