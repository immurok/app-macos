import SwiftUI

/// 引导流程里的设备示意图。
///
/// 存在的理由：有用户在绑定时按的是**顶面的指纹传感器**而不是**底面的按钮**，
/// 然后反馈「无法绑定」。文字再怎么写「设备底部的按钮」也拦不住这种误会，
/// 画出来才行。视角沿用用户手册的部件图（底面视图），用户把实物翻过来就能
/// 对上位置；按钮上用扩散的光环指位置，不画手指（手指会把按钮挡住）。
///
/// 全部用 Path 画，不放位图：颜色跟系统主色和深色模式走，手指按压可以动。
/// 画布固定 340×190，向导页和 400 宽的绑定引导框都放得下。
struct DeviceIllustration: View {
    enum Scene {
        /// 系统设置里点「连接」，设备蓝灯慢闪。
        case bluetoothConnect
        /// 翻到背面短按按钮：按钮上光环扩散。
        case pressButton
        /// 手指按顶面传感器（登记第二台主机的第一步）。
        case touchSensor
    }

    let scene: Scene

    /// 让按压动画只在等待用户动作时循环；计算密钥等阶段传 false 定格。
    var animated: Bool = true

    static let canvasSize = CGSize(width: 340, height: 190)

    @State private var pressed = false
    @State private var ledOn = true
    /// 按钮光圈的相位 0→1：环从按钮大小扩散出去并淡出，循环不往返。
    @State private var ripple: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch scene {
            case .bluetoothConnect: bluetoothScene
            case .pressButton:      pressButtonScene
            case .touchSensor:      touchSensorScene
            }
        }
        .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
        .onAppear {
            guard animated else { return }
            // 同 PairingGuideSheet：挂在下一个 runloop 起动，避免把 sheet
            // 呈现时的落位位移一起循环。
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pressed = true
                }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    ledOn = false
                }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    ripple = 1
                }
            }
        }
    }

    // MARK: - 场景

    private var bluetoothScene: some View {
        ZStack(alignment: .topLeading) {
            BluetoothWindowMock()
                .frame(width: 176, height: 96)
                .offset(x: 6, y: 44)

            arrow(from: CGPoint(x: 192, y: 92), to: CGPoint(x: 222, y: 92))

            TopFace(size: 96, sensorGlow: nil, ledBlue: ledOn)
                .position(x: 282, y: 88)
        }
    }

    private var pressButtonScene: some View {
        ZStack(alignment: .topLeading) {
            // 不画手指：手指会把按钮本身挡住。按钮上一圈光环向外扩散，
            // 既指明位置，又不遮挡。
            BottomFace(size: 140, ripple: animated ? ripple : 0)
                .position(x: 170, y: 84)

            Text("illus.button.flip".localized)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
                .frame(width: 300)
                .multilineTextAlignment(.center)
                .position(x: 170, y: 172)
        }
    }

    private var touchSensorScene: some View {
        ZStack(alignment: .topLeading) {
            TopFace(size: 140, sensorGlow: .green, ledBlue: nil)
                .position(x: 170, y: 100)
            Finger(length: 64, pressing: pressed)
                .rotationEffect(.degrees(180))
                .position(x: 170, y: 100 - 6)
            Text("pairing.guide.step.fp".localized)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
                .frame(width: 300)
                .multilineTextAlignment(.center)
                .position(x: 170, y: 180)
        }
    }

    // MARK: - 小部件

    private func arrow(from: CGPoint, to: CGPoint) -> some View {
        Path { p in
            p.move(to: from)
            p.addLine(to: to)
            p.move(to: CGPoint(x: to.x - 7, y: to.y - 6))
            p.addLine(to: to)
            p.addLine(to: CGPoint(x: to.x - 7, y: to.y + 6))
        }
        .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }
}

// MARK: - 底面（手册部件图视角）

/// 设备底面：外壳圆角方、内圈、四颗螺丝、中央圆盖、上方电源拨键、下方圆形按钮。
private struct BottomFace: View {
    let size: CGFloat
    /// 按钮光环相位 0→1（0 = 静态高亮一圈；nil = 不画光环，只画按钮本身）。
    let ripple: CGFloat?

    /// 按钮中心相对底面中心的纵向偏移（占边长比例）。
    ///
    /// 几何约束（都按边长比例）：中央圆盖 r=0.34；拨键/按钮必须整个落在圆盖
    /// 里（按钮 0.25+0.055、拨键 0.24+0.065 都 < 0.34）；螺丝必须落在内圈
    /// （±0.44）里（0.36+0.03 < 0.44）。早先按钮 r=0.075、偏移 0.27 时
    /// 按钮下沿压出了圆盖，螺丝也贴着内圈线——实机反馈「超出边界」。
    static let buttonOffsetRatio: CGFloat = 0.25
    static let switchOffsetRatio: CGFloat = 0.24
    static let buttonDiameterRatio: CGFloat = 0.11

    var body: some View {
        let r = size * 0.22
        let inset = size * 0.06
        ZStack {
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .stroke(Color.primary, lineWidth: 2)
            RoundedRectangle(cornerRadius: r - inset * 0.8, style: .continuous)
                .stroke(Color.secondary, lineWidth: 1.2)
                .padding(inset)

            // 四颗螺丝
            ForEach(0..<4, id: \.self) { i in
                let sx: CGFloat = (i % 2 == 0) ? -1 : 1
                let sy: CGFloat = (i < 2) ? -1 : 1
                Circle()
                    .stroke(Color.secondary, lineWidth: 1.2)
                    .frame(width: size * 0.06, height: size * 0.06)
                    .offset(x: sx * size * 0.36, y: sy * size * 0.36)
            }

            // 中央圆盖
            Circle()
                .stroke(Color.secondary, lineWidth: 1.2)
                .frame(width: size * 0.68, height: size * 0.68)

            // 电源拨键（上）
            Capsule()
                .stroke(Color.secondary, lineWidth: 1.2)
                .frame(width: size * 0.07, height: size * 0.13)
                .offset(y: -size * Self.switchOffsetRatio)
            Circle()
                .fill(Color.secondary)
                .frame(width: size * 0.045, height: size * 0.045)
                .offset(y: -size * Self.switchOffsetRatio - size * 0.03)

            // 按钮（下）—— 蓝色光环从按钮向外扩散并淡出
            if let phase = ripple {
                Circle()
                    .stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: size * Self.buttonDiameterRatio, height: size * Self.buttonDiameterRatio)
                    .scaleEffect(1 + phase * 2.2)
                    .opacity(Double(1 - phase) * 0.9)
                    .offset(y: size * Self.buttonOffsetRatio)
            }
            Circle()
                .stroke(Color.primary, lineWidth: 2)
                .background(Circle().fill(ripple != nil ? Color.accentColor.opacity(0.25) : Color.clear))
                .frame(width: size * Self.buttonDiameterRatio, height: size * Self.buttonDiameterRatio)
                .offset(y: size * Self.buttonOffsetRatio)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 顶面

/// 设备顶面：外壳圆角方 + 中央指纹传感器双环。
/// `sensorGlow` 给传感器上色（按指纹时绿灯）；
/// `ledBlue` 非 nil 时在下边缘画指示灯，true 亮 / false 暗（配合闪烁动画）。
struct TopFace: View {
    let size: CGFloat
    let sensorGlow: Color?
    let ledBlue: Bool?

    var body: some View {
        let r = size * 0.24
        let sensor = size * 0.32
        ZStack {
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .stroke(Color.primary, lineWidth: 2)

            if let glow = sensorGlow {
                Circle()
                    .fill(glow.opacity(0.25))
                    .frame(width: sensor * 1.4, height: sensor * 1.4)
            }
            Circle()
                .stroke(Color.primary, lineWidth: 1.6)
                .frame(width: sensor, height: sensor)
            Circle()
                .stroke(Color.secondary, lineWidth: 1.2)
                .frame(width: sensor * 0.72, height: sensor * 0.72)

            // 指示灯在机身侧面，顶视图里画在下边缘外侧一点
            if let on = ledBlue {
                Capsule()
                    .fill(Color.blue.opacity(on ? 1 : 0.15))
                    .frame(width: size * 0.14, height: size * 0.05)
                    .offset(y: size * 0.5 + size * 0.07)
            }

        }
        .frame(width: size, height: size)
    }
}

// MARK: - 手指

/// 一根从下往上指的手指。视图高度是指长的两倍减去指宽、内容贴底对齐，所以
/// **视图中心就是指腹圆心**：调用方用 position 把指尖放到目标点，再用 rotationEffect（默认
/// 绕中心）转到想要的方向，指尖位置不变。
/// `pressing` 为 true 时整体沿指向前顶 5pt，配合 repeatForever 就是按压动画。
struct Finger: View {
    let length: CGFloat
    let pressing: Bool

    var body: some View {
        let w = length * 0.42
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // 指身填底色，把压在下面的设备线条遮掉，否则线条互相穿插很乱。
                Path { p in
                    p.move(to: CGPoint(x: 0, y: length))
                    p.addLine(to: CGPoint(x: 0, y: w / 2))
                    p.addArc(center: CGPoint(x: w / 2, y: w / 2), radius: w / 2,
                             startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                    p.addLine(to: CGPoint(x: w, y: length))
                    p.closeSubpath()
                }
                .fill(Color(nsColor: .windowBackgroundColor))
                // 指身：顶部半圆 + 直边
                Path { p in
                    p.move(to: CGPoint(x: 0, y: length))
                    p.addLine(to: CGPoint(x: 0, y: w / 2))
                    p.addArc(center: CGPoint(x: w / 2, y: w / 2), radius: w / 2,
                             startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                    p.addLine(to: CGPoint(x: w, y: length))
                }
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                // 指甲
                Path { p in
                    p.addArc(center: CGPoint(x: w / 2, y: w * 0.62), radius: w * 0.3,
                             startAngle: .degrees(200), endAngle: .degrees(-20), clockwise: false)
                }
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            }
            .frame(width: w, height: length)
        }
        // 内容贴底、高度 2×length − w：视图中点正好是指腹圆心（顶端往下 w/2），
        // 而不是半圆的最高点，这样 position 到按钮中心时指腹盖在按钮上。
        .frame(width: w, height: length * 2 - w, alignment: .bottom)
        .offset(y: pressing ? -5 : 2)
    }
}

// MARK: - 系统设置「蓝牙」窗口的简笔画

private struct BluetoothWindowMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().stroke(Color.secondary, lineWidth: 1).frame(width: 7, height: 7)
                }
            }
            .padding(.top, 8)
            .padding(.leading, 10)

            Text("illus.bt.title".localized)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
                .padding(.top, 10)
                .padding(.leading, 12)

            HStack {
                Text("immurok IK-1")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                Spacer()
                Text("illus.bt.connect".localized)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .overlay(Capsule().stroke(Color.accentColor, lineWidth: 1.2))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary, lineWidth: 1.2))
            .padding(.horizontal, 10)
            .padding(.top, 12)

            Spacer(minLength: 0)
        }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary, lineWidth: 2))
    }
}
