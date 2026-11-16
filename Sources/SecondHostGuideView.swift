import SwiftUI

/// 「如何添加第二台主机」的图文引导。
///
/// 从空着的对方主机卡片上点开。三步都发生在设备或另一台电脑上，本机替不了，
/// 所以这里只讲清楚顺序，不带任何操作按钮：
///   1. 录入「主机切换」指纹
///   2. 用这根手指按一下，设备切到空槽
///   3. 指示灯闪烁，第二台电脑搜索并连接
///
/// 指示灯颜色跟目标槽走：固件在槽 2 上广播闪白灯、槽 1 闪蓝灯。本机坐在
/// 槽 2 而槽 1 空着时，照着「白灯」找会对不上，所以按 `targetSlot` 换色换字。
struct SecondHostGuideSheet: View {
    /// 「主机切换」指纹是否已经录入，录了就在第一步打勾。
    let hasSwitchFinger: Bool
    /// 要去填的那个空槽（1 或 2）。
    let targetSlot: UInt8

    @Environment(\.dismiss) private var dismiss
    @State private var pressed = false
    @State private var ledOn = true

    private var ledIsWhite: Bool { targetSlot == 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("dualhost.guide.title".localized)
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                row(1,
                    title: "dualhost.guide.step1.title".localized,
                    detail: "dualhost.guide.step1.detail".localized,
                    done: hasSwitchFinger) { enrollArt }
                row(2,
                    title: "dualhost.guide.step2.title".localized,
                    detail: "dualhost.guide.step2.detail".localized) { touchArt }
                row(3,
                    title: (ledIsWhite ? "dualhost.guide.step3.title.white"
                                       : "dualhost.guide.step3.title.blue").localized,
                    detail: "dualhost.guide.step3.detail".localized) { connectArt }
            }

            Divider()

            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text("dualhost.guide.footer".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("wizard.done".localized) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            // 挂到下一个 runloop 再起动，避免把 sheet 呈现时的落位位移一起
            // repeatForever（同 PairingGuideSheet / DeviceIllustration）。
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pressed = true
                }
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    ledOn = false
                }
            }
        }
    }

    // MARK: - 一行：插画 + 序号 + 文字

    private func row<Art: View>(_ number: Int, title: String, detail: String,
                                done: Bool = false,
                                @ViewBuilder art: () -> Art) -> some View {
        HStack(alignment: .center, spacing: 16) {
            art()
                .frame(width: 132, height: 100)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.07)))

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(number)")
                        .font(.caption.weight(.bold))
                        .foregroundColor(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.accentColor))
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if done {
                    Label("dualhost.guide.step1.done".localized,
                          systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 插画

    /// 第 1 步：指纹列表的简笔画，最后一行是高亮的「主机切换」位。
    private var enrollArt: some View {
        VStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 6) {
                    Image(systemName: "touchid")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Capsule()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 46, height: 5)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1))
            }
            HStack(spacing: 5) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                Text("fingerprint.switch.name".localized)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 12))
            }
            .foregroundColor(.accentColor)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(Color.accentColor, lineWidth: 1.2))
        }
        .frame(width: 108)
    }

    /// 第 2 步：手指按顶面传感器。
    private var touchArt: some View {
        ZStack {
            TopFace(size: 66, sensorGlow: .accentColor, ledBlue: nil)
                .offset(y: 8)
            // Finger 的视图中心就是指腹圆心，转 180° 后指身朝上伸出。
            Finger(length: 32, pressing: pressed)
                .rotationEffect(.degrees(180))
                .offset(y: 6)
        }
    }

    /// 第 3 步：设备指示灯闪烁，旁边的电脑来连。
    private var connectArt: some View {
        HStack(spacing: 8) {
            ZStack {
                TopFace(size: 50, sensorGlow: nil, ledBlue: nil)
                led.offset(y: 25 + 7)
            }
            .offset(y: -4)
            Image(systemName: "wave.3.right")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            Image(systemName: "laptopcomputer")
                .font(.system(size: 30))
                .foregroundColor(.primary)
        }
    }

    /// 指示灯。白灯在浅色背景上靠填充看不出亮灭，所以加描边，再用一圈
    /// 随亮灭变化的光晕表示「在闪」。
    private var led: some View {
        let color: Color = ledIsWhite ? .white : .blue
        return Capsule()
            .fill(color.opacity(ledOn ? 1 : 0.1))
            .overlay(Capsule().stroke(Color.primary.opacity(ledIsWhite ? 0.7 : 0), lineWidth: 1))
            .frame(width: 14, height: 6)
            .background(
                Circle()
                    .fill((ledIsWhite ? Color.primary : Color.blue).opacity(ledOn ? 0.22 : 0))
                    .frame(width: 30, height: 30)
                    .blur(radius: 5)
            )
    }
}
