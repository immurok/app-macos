import AppKit
import SwiftUI

/// 双主机槽位的 UI 状态。
///
/// 登记第二台主机不需要老主机参与：在那台电脑上点配对、按一次已登记的
/// 指纹、再按一下设备按钮即可。两道门都是物理在场凭证，设备被偷也过不了。
@MainActor
final class DualHostViewModel: ObservableObject {
    /// 槽位占用位图：bit0 = 槽 1、bit1 = 槽 2
    @Published var slotBitmap: UInt8 = 0
    @Published var activeSlot: UInt8 = 1
    @Published var isClearing = false
    @Published var errorMessage: String?
    /// 跨槽解绑走指纹门时的提示（"请按已登记指纹"），门结果回来即清。 */
    @Published var gatePrompt: String?

    private let ble = BLEManager.shared

    func isPaired(slot: UInt8) -> Bool { slotBitmap & (1 << (slot - 1)) != 0 }

    var slot1Paired: Bool { isPaired(slot: 1) }
    var slot2Paired: Bool { isPaired(slot: 2) }
    var bothSlotsFull: Bool { slot1Paired && slot2Paired }

    /// 本机是否是「第二台主机」：本机所在的槽还空，而另一个槽已被占。
    /// 设备通过 SLOT_STATUS 让新主机自知身份，据此把配对提示换成
    /// 「指纹 + 按键」而不是首次配对的「只按按键」。
    var isSecondHostCandidate: Bool {
        guard !ImmurokSecurity.shared.isPaired else { return false }
        return isPaired(slot: otherSlot)
    }

    /// 另一个槽的编号（1↔2）。
    ///
    /// 设备只在活动槽的地址上广播，所以「连着的这台主机」必然坐在活动槽上
    /// —— 活动槽即本机的槽，另一个槽就是那台不在身边的主机。
    var otherSlot: UInt8 { activeSlot == 1 ? 2 : 1 }

    var otherSlotPaired: Bool { isPaired(slot: otherSlot) }

    /// 解绑不在身边的那台主机。设备会要求按一次已登记指纹。
    ///
    /// 只清对方的槽，本机的槽不动，所以设备不重启、连接不断。
    func clearOtherSlot() {
        guard !isClearing else { return }
        errorMessage = nil
        isClearing = true
        // 设备收到 SLOT_CLEAR(other) 会回 WAIT_FP 并等一次已登记指纹 —— 明确
        // 提示用户去按,否则"点了没反应"。门结果回来时清掉。
        gatePrompt = "dualhost.clear.press.fp".localized
        let target = otherSlot
        ble.clearSlot(target) { [weak self] ok in
            Task { @MainActor in
                guard let self = self else { return }
                self.isClearing = false
                self.gatePrompt = nil
                if ok {
                    LogManager.shared.log("Dual-host: slot \(target) cleared")
                } else {
                    self.errorMessage = "dualhost.clear.failed".localized
                }
                self.refresh()
            }
        }
    }

    func refresh() {
        // 断开时清空槽状态,否则卡片会一直停在断开前的旧 bitmap/active(#3)。
        guard ble.deviceState.isConnected else {
            slotBitmap = 0
            activeSlot = 1
            gatePrompt = nil
            return
        }
        ble.getSlotStatus { [weak self] bitmap, active in
            Task { @MainActor in
                self?.slotBitmap = bitmap
                self?.activeSlot = active
            }
        }
    }
}

/// 双主机面板：两张主机卡片，各自带自己的操作。
///
/// 取代了原先「槽位徽章 + 另一个 Pairing 区块」的两段式布局 —— 那样用户
/// 得在两处之间对应「我是哪一台、按钮作用在谁身上」。现在一台主机一张卡，
/// 操作就在卡里。
///
/// 能力边界诚实呈现：**空的对方槽没有配对按钮**。本机没法替另一台电脑
/// 完成配对（ECDH 要在那台机器上做），画一个按下去只会失败的按钮不如
/// 直接说清楚该去哪儿操作。
struct DualHostPanel: View {
    @ObservedObject var viewModel: DualHostViewModel
    @ObservedObject var appViewModel: AppViewModel
    /// 鼠标当前悬停在哪张卡上 —— 只有悬停的卡才浮现自己的 unpair 按钮。
    @State private var hoveredSlot: UInt8?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("dualhost.title".localized, systemImage: "laptopcomputer.and.iphone")
                    .font(.headline)

                // 断连时 refresh() 把 slotBitmap 清零，两张卡会画成「空槽」
                // 还提示去另一台电脑配对——本机绑定明明还在。断连没有可信
                // 的槽位信息，只说「未连接」。
                if !appViewModel.isDeviceConnected {
                    Text("dualhost.disconnected".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        card(slot: 1)
                        card(slot: 2)
                    }

                    Text(viewModel.bothSlotsFull
                         ? "dualhost.hint.full".localized
                         : "dualhost.hint".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let err = viewModel.errorMessage {
                        Text(err).font(.caption).foregroundColor(.red)
                    }

                    // 跨槽解绑等指纹门时的提示（#1）——否则用户点了"解绑另一台"
                    // 却不知道要去设备上按指纹。
                    if let prompt = viewModel.gatePrompt {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.6)
                            Text(prompt).font(.caption).foregroundColor(.blue)
                        }
                    }

                    // 引导框接管了配对期间的提示（见 PairingGuideSheet）；这行
                    // 小字保留，用于框被拖开或在别的显示器上时仍能看到状态。
                    if appViewModel.isPairing {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.6)
                            Text(appViewModel.pairingPrompt ?? "pairing.in.progress".localized)
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                }
            }
            .padding(4)
        }
        .onAppear { viewModel.refresh() }
        // 连接状态变化时刷新槽卡片：断开→清空,重连→拉最新（#3）。
        .onChange(of: appViewModel.isDeviceConnected) { _ in viewModel.refresh() }
    }

    // MARK: - 单张卡片

    /// 这个槽是不是本机。设备只在活动槽广播，所以连着的这台主机必然坐在
    /// 活动槽上；未连接时无从判断，一律不标。
    private func isThisMac(_ slot: UInt8) -> Bool {
        appViewModel.isDeviceConnected && viewModel.activeSlot == slot
    }

    private func card(slot: UInt8) -> some View {
        let paired = viewModel.isPaired(slot: slot)
        let mine = isThisMac(slot)

        /* 头部刻意压成**一行**：标题旁边放「本机」徽章，而不是标题下面另起
         * 一行。条件渲染的第二行会把其中一张卡的头部撑高，两张卡的图标就
         * 错位了（2026-08-04 实机反馈）。同理不设 minHeight —— HStack 里
         * 的兄弟视图本就会拉齐到最高的那张，固定高度只会平白留出空白。 */
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 16))
                    .foregroundColor(paired ? .accentColor : .secondary)
                Text(slot == 1 ? "dualhost.slot1".localized : "dualhost.slot2".localized)
                    .font(.callout)
                    .fontWeight(mine ? .semibold : .regular)
                Spacer(minLength: 4)
                if mine {
                    Text("dualhost.card.thismac".localized)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundColor(.accentColor)
                }
            }
            .frame(height: 22)

            HStack(spacing: 6) {
                Circle()
                    .fill(paired ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
                Text(paired ? "dualhost.card.bound".localized
                            : "dualhost.card.empty".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // 本机已绑定但验证不过 —— 设备侧有这个槽，本机却拿不出能对上的
            // 共享密钥（换过设备 / Keychain 被清）。必须显式提示，否则用户
            // 只会看到「已绑定」却处处认证失败。
            if mine && paired && !appViewModel.isDeviceVerified
                && appViewModel.isDeviceConnected {
                Text("device.not.verified".localized)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            action(slot: slot, paired: paired, mine: mine)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(mine ? Color.accentColor.opacity(0.06)
                           : Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(mine ? Color.accentColor.opacity(0.35) : Color.clear,
                        lineWidth: 1)
        )
        // 悬停整张卡片时才浮现该卡的 unpair 按钮（见 action）。
        .contentShape(Rectangle())  // 让整卡（含透明区域）都能接收 hover
        .onHover { hovering in hoveredSlot = hovering ? slot : nil }
    }

    @ViewBuilder
    private func action(slot: UInt8, paired: Bool, mine: Bool) -> some View {
        if mine {
            if paired && appViewModel.hasLocalPairing {
                // 默认隐藏,悬停本卡才浮现;居中、比原来大一号。
                Button("unpair.confirm".localized) { appViewModel.unpair() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity)
                    .opacity(hoveredSlot == slot ? 1 : 0)
                    .allowsHitTesting(hoveredSlot == slot)
                    .animation(.easeInOut(duration: 0.15), value: hoveredSlot)
            } else {
                // 配对与「解绑后重来」共用这个按钮。设备端按活动槽判断该走
                // 首次配对还是登记第二台主机，app 侧不分叉。
                //
                // paired && !hasLocalPairing 也走这里：设备侧有槽、本机没
                // 密钥，是状态分裂的逃生口 —— 早先两个按钮各自置灰，这种
                // 情况下界面会彻底死掉。
                Button("pairing.start".localized) { appViewModel.startPairing() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!appViewModel.isDeviceConnected || appViewModel.isPairing
                              || appViewModel.isPreparingPairing)
            }
        } else if paired {
            if viewModel.isClearing {
                // 该做什么由标准指纹门 sheet 说，这里只表示"进行中"，
                // 免得两处同时喊"请按指纹"。
                ProgressView().controlSize(.small)
            } else {
                // 默认隐藏,悬停本卡才浮现;居中、比原来大一号。
                Button("unpair.confirm".localized) { confirmClearOther() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity)
                    .opacity(hoveredSlot == slot ? 1 : 0)
                    .allowsHitTesting(hoveredSlot == slot)
                    .animation(.easeInOut(duration: 0.15), value: hoveredSlot)
                    .disabled(!appViewModel.isDeviceConnected)
            }
        } else {
            // 空的对方槽：本机替不了那台电脑做 ECDH，只能说清去哪儿操作。
            Text("dualhost.card.otherhint".localized)
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func confirmClearOther() {
        let alert = NSAlert()
        alert.messageText = "dualhost.clear.confirm.title".localized(Int(viewModel.otherSlot))
        alert.informativeText = "dualhost.clear.confirm.message".localized
        alert.alertStyle = .warning
        alert.addButton(withTitle: "alert.cancel".localized)
        alert.addButton(withTitle: "dualhost.clear.confirm.ok".localized)
        if alert.runModal() == .alertSecondButtonReturn {
            viewModel.clearOtherSlot()
        }
    }
}
