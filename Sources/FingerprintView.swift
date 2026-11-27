import SwiftUI
import FirmwareUpdateKit
import Combine

extension Notification.Name {
    static let fingerprintCacheUpdated = Notification.Name("fingerprintCacheUpdated")
    /// 设备 connect / disconnect 时由 AppViewModel 发出,让指纹列表刷新
    /// （BLEManager.deviceState 不是 @Published,无法 Combine 订阅）。
    static let deviceConnectionChanged = Notification.Name("deviceConnectionChanged")
}

struct FingerprintView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = FingerprintViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header
            headerSection

            // Fingerprint icons
            fingerprintIconsSection

            Spacer()
        }
        .padding(24)
        .frame(width: 500, height: 480)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            viewModel.refresh()
        }
        .sheet(isPresented: $viewModel.isEnrolling) {
            EnrollmentSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.gateController.isPresented) {
            FingerprintGateSheet(controller: viewModel.gateController)
        }
        .background(
            // Hidden button for CMD+R shortcut
            Button("") {
                viewModel.forceRefresh()
            }
            .keyboardShortcut("r", modifiers: .command)
            .opacity(0)
        )
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("fingerprint.title".localized)
                    .font(.title)
                    .fontWeight(.bold)

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text("fingerprint.description".localized)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Fingerprint Icons Section

    private var fingerprintIconsSection: some View {
        Group {
            if viewModel.isLoading {
                // Loading state
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("fingerprint.loading".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(height: 100)
            } else {
                HStack(spacing: 32) {
                    Spacer()

                    // Show enrolled fingerprints based on actual slot indices (bitmap)
                    ForEach(viewModel.enrolledSlots, id: \.self) { slotIndex in
                        fingerprintIcon(slot: slotIndex)
                    }

                    // Show add button while slots remain (5 认证 + 可选的第 6 切换槽)
                    if viewModel.fingerprintCount < viewModel.maxSlots {
                        addFingerprintButton
                    }

                    Spacer()
                }
                .padding(.vertical, 16)
                // 上限也要纳入 id：supportsSwitchSlot 翻转时位图往往没变（一直是
                // 0x1f），只按位图做 id 会让 SwiftUI 不重建这棵子树，第 6 个
                // 添加位就永远出不来。
                .id("\(viewModel.fingerprintBitmap)-\(viewModel.maxSlots)")
            }
        }
    }

    private func fingerprintIcon(slot: Int) -> some View {
        FingerprintIconView(
            index: slot,
            name: viewModel.fingerprintName(for: slot),
            onDelete: {
                viewModel.deleteFingerprint(slot: slot)
            },
            onRename: { newName in
                viewModel.setFingerprintName(newName, for: slot)
            }
        )
    }

    private var addFingerprintButton: some View {
        VStack(spacing: 8) {
            Button(action: {
                // Use first available slot from bitmap
                NSLog("FingerprintView: Add button pressed, bitmap=0x%02X, nextAvailable=%@",
                      viewModel.fingerprintBitmap, viewModel.nextAvailableSlot.map { String($0) } ?? "nil")
                if let slot = viewModel.nextAvailableSlot {
                    viewModel.enrollFingerprint(slot: slot)
                }
            }) {
                ZStack {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 2)
                        .frame(width: 64, height: 64)

                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.isDeviceConnected || viewModel.isEnrolling || viewModel.isLoading || viewModel.nextAvailableSlot == nil)

            Text("fingerprint.add".localized)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

}

// Separate view for hover state
struct FingerprintIconView: View {
    let index: Int
    let name: String
    let onDelete: () -> Void
    /// nil = 名字不可编辑（主机切换指纹用固定名，改名会抹掉它的特殊身份，
    /// 用户会忘记这根手指不能解锁）。
    let onRename: ((String) -> Void)?
    @State private var isHovering = false
    @State private var isEditing = false
    @State private var editText = ""

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color(NSColor.controlBackgroundColor))
                    .frame(width: 64, height: 64)

                Image(systemName: "touchid")
                    .font(.system(size: 32))
                    .foregroundColor(.accentColor)

                // Delete button on hover
                if isHovering {
                    Circle()
                        .fill(Color.black.opacity(0.5))
                        .frame(width: 64, height: 64)

                    Button(action: onDelete) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .onHover { hovering in
                isHovering = hovering
            }

            if isEditing, let onRename = onRename {
                TextField("", text: $editText, onCommit: {
                    let trimmed = editText.trimmingCharacters(in: .whitespaces)
                    onRename(trimmed)
                    isEditing = false
                })
                .textFieldStyle(.plain)
                .font(.caption)
                .multilineTextAlignment(.center)
                .frame(width: 80)
            } else {
                Text(name)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .onTapGesture {
                        guard onRename != nil else { return }
                        editText = name
                        isEditing = true
                    }
            }
        }
    }
}

// MARK: - Enrollment Step Helpers

/// 6-step guided enrollment offset map (椭圆偏移量，px).
/// progress 1: 正中 / 2: 左 / 3: 右 / 4: 上(指尖) / 5: 下(手腕) / 6: 再次正中
/// mode-1 强制前 5 步采集**不同**区域，所以每步都要换位置——重合太多会被
/// 传感器以 0x28 拒绝。第 6 步回到正中、与第 1 步重合是有意的：固件 1.8.8 起
/// 只在这一步关掉区域控制，给核心指腹补一个样本。
/// Out-of-range (0 pre-start, >6 done) returns .zero.
fileprivate func enrollOffsetForStep(_ progress: Int) -> CGSize {
    switch progress {
    case 1:      return .zero
    case 2:      return CGSize(width: -16, height: 0)
    case 3:      return CGSize(width: 16, height: 0)
    case 4:      return CGSize(width: 0, height: -16)
    case 5:      return CGSize(width: 0, height: 16)
    case 6:      return .zero
    default:     return .zero
    }
}

/// SF Symbol name for direction arrow at given step (only the 4 directional steps).
fileprivate func enrollArrowSymbolForStep(_ progress: Int) -> String {
    switch progress {
    case 2:      return "arrow.left"
    case 3:      return "arrow.right"
    case 4:      return "arrow.up"
    case 5:      return "arrow.down"
    default:     return "arrow.up"
    }
}

/// Arrow position offset relative to the 60×80 ellipse (椭圆外侧).
/// Direction-aware: arrow sits outside the ellipse in the same direction
/// the user should tilt toward.
fileprivate func enrollArrowOffsetForStep(_ progress: Int) -> CGSize {
    switch progress {
    case 2:      return CGSize(width: -55, height: 0)   // 左侧
    case 3:      return CGSize(width: 55, height: 0)    // 右侧
    case 4:      return CGSize(width: 0, height: -55)   // 顶部
    case 5:      return CGSize(width: 0, height: 55)    // 底部
    default:     return CGSize(width: 0, height: -55)
    }
}

/// Localization key for the step's primary title text.
fileprivate func enrollTitleKeyForStep(_ progress: Int) -> String {
    switch progress {
    case 1:      return "enroll.step.center.first"
    case 2:      return "enroll.step.left.first"
    case 3:      return "enroll.step.right.first"
    case 4:      return "enroll.step.up"
    case 5:      return "enroll.step.down"
    case 6:      return "enroll.step.center.again"
    default:     return "enroll.step.center.first"
    }
}

/// True for steps where the target region moves (用于橙色闪烁提示).
/// Under mode-1 every capture is a new region, so flash on each step ≥2 to
/// draw the user's eye to the relocated ellipse.
fileprivate func enrollIsTransitionStep(_ progress: Int) -> Bool {
    progress >= 2 && progress <= 6
}

// MARK: - Enrollment Sheet

struct EnrollmentSheet: View {
    @ObservedObject var viewModel: FingerprintViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var pulseScale: CGFloat = 1.0
    @State private var arrowOpacity: Double = 1.0
    @State private var transitionFlash: Bool = false
    @State private var shakeOffset: CGFloat = 0   // overlap "shift finger" shake cue

    /// Step the user should perform NEXT (1..6).
    /// `enrollmentProgress` 是已完成捕获帧数; UI 要提示下一帧姿势, 所以 +1.
    /// progress=0 (init) → 1; progress=6 (完成) → 6.
    private var animProgress: Int {
        min(max(viewModel.enrollmentProgress + 1, 1), 6)
    }

    private var isTransitionStep: Bool {
        enrollIsTransitionStep(animProgress)
    }

    /// 正中阶段 (step 1 与 step 6) 不显示方向箭头, 避免被误读为"向上偏移".
    /// 只有四向偏移步 (2 左 / 3 右 / 4 上 / 5 下) 显示箭头.
    private var showArrow: Bool {
        animProgress >= 2 && animProgress <= 5
    }

    /// 刚用旧手指过门：先停在「验证通过，换成新手指」，不摆采集引导
    /// （见 EnrollHandoff）。
    private var isHandoff: Bool { viewModel.enrollHandoff }

    var body: some View {
        VStack(spacing: 20) {
            // sensor 圆 + 偏移椭圆 + 方向箭头
            ZStack {
                // 背景圆（不变）
                Circle()
                    .fill(Color(NSColor.controlBackgroundColor))
                    .frame(width: 120, height: 120)

                // 采集引导三件套。过渡期间只用 opacity 藏起来、不从视图树里摘掉：
                // 摘掉再插回来时 pulseScale / arrowOpacity 已经是终值，
                // repeatForever 等不到值变化，脉动就再也不会启动。
                Group {
                    // pulse 圆（不变，等待手指视觉提示）
                    // repeatForever 必须挂在这里，绝不能用 onAppear 里的
                    // withAnimation：sheet 呈现时 onAppear 与布局在同一个事务中，
                    // withAnimation 会把「内容从原点落到居中」这段位移也一起
                    // repeatForever，整个对话框内容就在居中与左上角之间无限摆动。
                    Circle()
                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 2)
                        .frame(width: 60, height: 60)
                        .scaleEffect(pulseScale)
                        .opacity(2.0 - Double(pulseScale))
                        .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                                   value: pulseScale)

                    // 手指椭圆（按 progress 偏移）
                    RoundedRectangle(cornerRadius: 30)
                        .fill(transitionFlash ? Color.orange : Color.accentColor)
                        .frame(width: 60, height: 80)
                        .offset(enrollOffsetForStep(animProgress))
                        .offset(x: shakeOffset)   // horizontal shake on overlap reject
                        .opacity(viewModel.enrollmentProgress > 0 ? 1.0 : 0.5)
                        .animation(.easeInOut(duration: 0.3), value: animProgress)

                    // 方向箭头（位置 + symbol 都按 progress 切换, 正中阶段隐藏）
                    Image(systemName: enrollArrowSymbolForStep(animProgress))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.accentColor)
                        .offset(enrollArrowOffsetForStep(animProgress))
                        .opacity(showArrow ? arrowOpacity : 0)
                        .animation(.easeInOut(duration: 0.3), value: animProgress)
                        // 同上：脉动只绑到 arrowOpacity，不走 onAppear 的 withAnimation
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                                   value: arrowOpacity)
                }
                .opacity(isHandoff ? 0 : 1)

                // 换手指过渡：对勾
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundColor(.green)
                    .opacity(isHandoff ? 1 : 0)
            }

            // 主步骤标题（切换步加粗）；过渡期间是「验证通过」
            Text((isHandoff ? "enroll.verified" : enrollTitleKeyForStep(animProgress)).localized)
                .font(.headline)
                .fontWeight(isTransitionStep && !isHandoff ? .semibold : .regular)
                .multilineTextAlignment(.center)

            // 现有 status text（waiting / captured / lift_finger 等动态文案）；
            // 过渡期间是「抬起手指，换成新手指」
            Text(isHandoff ? "enroll.verified.hint".localized : viewModel.enrollmentStatus)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // 过渡期间还没开始采集，进度留位但不显示（免得布局跳动）
            ProgressView(value: Double(viewModel.enrollmentProgress), total: Double(viewModel.enrollmentTotal))
                .frame(width: 200)
                .opacity(isHandoff ? 0 : 1)

            Text("\(viewModel.enrollmentProgress)/\(viewModel.enrollmentTotal)")
                .font(.caption)
                .foregroundColor(.secondary)
                .opacity(isHandoff ? 0 : 1)

            Button("alert.cancel".localized) {
                viewModel.cancelEnrollment()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(32)
        .frame(width: 300, height: 380)
        .onChange(of: viewModel.enrollmentProgress) { newProgress in
            if enrollIsTransitionStep(newProgress) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    transitionFlash = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        transitionFlash = false
                    }
                }
            }
        }
        .onChange(of: viewModel.overlapNudge) { _ in
            // (mode 1) overlap reject: orange flash + quick left-right shake to
            // tell the user to move the finger to a new spot before re-pressing.
            withAnimation(.easeInOut(duration: 0.15)) { transitionFlash = true }
            let steps: [(TimeInterval, CGFloat)] = [
                (0.00, -10), (0.07, 10), (0.14, -7), (0.21, 7), (0.28, 0)
            ]
            for (delay, dx) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    withAnimation(.easeInOut(duration: 0.07)) { shakeOffset = dx }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.easeInOut(duration: 0.15)) { transitionFlash = false }
            }
        }
        .onAppear {
            // 必须推到下一个 runloop：onAppear 与首次布局在同一个事务里，
            // 此刻改这两个值会让 repeatForever 的 .animation 把「内容从原点
            // 落到最终位置」这段位移也一起动画化并无限重复 —— 表现为圆环
            // 反复从旁边飞入。async 到独立事务后，布局已定，动画只作用于
            // scale/opacity 本身。
            //
            // 同理绝不能在这里包 withAnimation（见 pulse 圆处的注释），那是
            // 同一个坑的另一种触发方式。
            DispatchQueue.main.async {
                pulseScale = 1.6
                arrowOpacity = 0.4   // 箭头脉动节奏（0.8s 周期）
            }
        }
    }
}

// MARK: - View Model

@MainActor
class FingerprintViewModel: ObservableObject {
    @Published var isDeviceConnected = false
    @Published var fingerprintBitmap: UInt8 = 0  // Bitmap: bit N = slot N has fingerprint
    @Published var isLoading = false
    @Published var isEnrolling = false
    @Published var enrollmentStatus = ""
    @Published var enrollmentProgress = 0
    @Published var enrollmentTotal = 6  // Single-slot: 6 captures (mode-1 broad coverage)
    @Published var overlapNudge = 0     // bumped on each mode-1 overlap reject → UI shake cue
    /// 刚用旧手指过门、还没开始采集：录入 sheet 显示「验证通过，换成新手指」。
    @Published var enrollHandoff = false

    var gateController = FingerprintGateController()

    // Track current enrollment slot
    private var currentEnrollSlot: Int?

    // 验证旧指纹 → 换手指 → 采集新指纹 的过渡（帧裁决见 EnrollHandoff）
    private var handoff = EnrollHandoff()
    private var handoffDwellTask: Task<Void, Never>?
    /// 这次录入真的过了指纹门（设备回过 WAIT_FP）。不能用「设备上已有指纹」代替：
    /// 门在冷却期内会被固件跳过，那时传感器上没有旧手指，也谈不上「验证通过」。
    private var enrollViaGate = false

    // MARK: - Slot capacity
    //
    // 固件 1.6.4 起把 FP_USER_MAX 从 5 提到 6：第 6 槽（index 5）专用于
    // 双主机切换，不参与认证。按设备实际固件版本决定上限，这样连着旧固件
    // 的设备不会多出一个点了没用的槽位。

    /// 第 6 槽起用的固件版本
    private static let dualHostMinFirmware = FirmwareVersion("1.6.4")!

    /// 专用切换指纹的槽位（固件 FP_SWITCH_SLOT）
    static let switchSlotIndex = 5

    /// 设备是否支持双主机切换槽。
    ///
    /// 必须是 @Published 的存储属性，不能写成读 bleManager.firmwareVersion
    /// 的计算属性 —— 那个字段不是 @Published，SwiftUI 不会因它变化而重绘，
    /// 而固件版本往往晚于视图首次渲染才到，界面就会永远停在 5 槽。
    /// 2026-08-03 真机踩到。
    @Published var supportsSwitchSlot: Bool = false

    /// 从 BLEManager 上报的版本串刷新 supportsSwitchSlot。
    /// 设备上报的可能带 build 号（"1.6.5.d664"），取前三段比较。
    private func refreshSwitchSlotSupport() {
        guard let raw = bleManager.firmwareVersion else {
            supportsSwitchSlot = false
            return
        }
        let core = raw.split(separator: ".").prefix(3).joined(separator: ".")
        let ok = FirmwareVersion(core).map { $0 >= Self.dualHostMinFirmware } ?? false
        if ok != supportsSwitchSlot {
            // 用 LogManager 而非 NSLog —— 本 app 的 NSLog 进不了 immurok.log，
            // 诊断信息看不到等于没有。
            LogManager.shared.log("FP slots: fw=\(raw) core=\(core) "
                                  + "switchSlot=\(ok ? "yes" : "no") max=\(ok ? 6 : 5)")
            supportsSwitchSlot = ok
        }
    }

    /// 用户可见的指纹槽总数（含切换槽）
    var maxSlots: Int { supportsSwitchSlot ? 6 : 5 }

    // MARK: - 认证槽 vs 切换槽
    //
    // 前 5 槽是认证指纹，顺序录入；第 6 槽（switchSlotIndex）专用于主机
    // 切换，UI 上独立成一块、可直接录入 —— 用户不必先把 5 根认证指纹录满
    // 才能拿到切换功能。

    /// 认证指纹的槽位上限（不含切换槽）
    static let authSlotMax = 5

    /// 已录入的认证指纹槽位
    var authSlots: [Int] {
        (0..<Self.authSlotMax).filter { fingerprintBitmap & (1 << $0) != 0 }
    }

    var authCount: Int { authSlots.count }

    /// 下一个可用的认证槽（顺序分配）
    var nextAvailableAuthSlot: Int? {
        (0..<Self.authSlotMax).first { fingerprintBitmap & (1 << $0) == 0 }
    }

    /// 切换指纹是否已录入
    var hasSwitchFinger: Bool {
        supportsSwitchSlot && (fingerprintBitmap & (1 << Self.switchSlotIndex)) != 0
    }

    // Computed properties for bitmap
    var fingerprintCount: Int {
        (0..<maxSlots).filter { fingerprintBitmap & (1 << $0) != 0 }.count
    }

    /// List of enrolled slot indices
    var enrolledSlots: [Int] {
        (0..<maxSlots).filter { fingerprintBitmap & (1 << $0) != 0 }
    }

    /// Find first available slot for enrollment (returns nil if all slots full)
    var nextAvailableSlot: Int? {
        (0..<maxSlots).first { fingerprintBitmap & (1 << $0) == 0 }
    }

    // Fingerprint names (stored in UserDefaults, not synced to firmware)
    @Published var fingerprintNames: [Int: String] = [:]

    func fingerprintName(for slot: Int) -> String {
        // 第 6 槽是双主机切换指纹，不参与认证 —— 名字固定且不吃自定义名
        //（含历史遗留的自定义名）：改成「右手食指」之类后，界面上再没有
        // 任何东西标记这根手指只切换主机、不能解锁。
        if slot == Self.switchSlotIndex && supportsSwitchSlot {
            return "fingerprint.switch.name".localized
        }
        if let custom = fingerprintNames[slot] { return custom }
        return "fingerprint.finger".localized(slot + 1)
    }

    func setFingerprintName(_ name: String, for slot: Int) {
        if name.isEmpty || name == "fingerprint.finger".localized(slot + 1) {
            fingerprintNames.removeValue(forKey: slot)
        } else {
            fingerprintNames[slot] = name
        }
        saveFingerprintNames()
    }

    private func saveFingerprintNames() {
        let dict = fingerprintNames.reduce(into: [String: String]()) { $0["\($1.key)"] = $1.value }
        UserDefaults.standard.set(dict, forKey: "immurok.fingerprintNames")
    }

    /// 清除全部自定义指纹名。解除配对时必须调用 —— 名字存在 UserDefaults，
    /// 不随配对数据走；不清的话重新绑定后旧名字还在，让人以为指纹没清干净。
    static func clearAllNames() {
        UserDefaults.standard.removeObject(forKey: "immurok.fingerprintNames")
    }

    private func loadFingerprintNames() {
        guard let dict = UserDefaults.standard.dictionary(forKey: "immurok.fingerprintNames") as? [String: String] else { return }
        fingerprintNames = dict.reduce(into: [Int: String]()) { result, pair in
            if let key = Int(pair.key) { result[key] = pair.value }
        }
    }

    private let bleManager = BLEManager.shared
    private var gateCancellable: AnyCancellable?

    // Fingerprint bitmap cache (shared across instances)
    static var cachedBitmap: UInt8 = 0
    private static var lastConnectionState: Bool = false  // Track connection state for cache invalidation
    static var isCacheValid: Bool = false

    init() {
        // Forward gate controller changes so SwiftUI sheet binding updates
        gateCancellable = gateController.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        loadFingerprintNames()
        setupEnrollmentCallback()

        // 连接变化时刷新指纹列表:断开→清空(refresh 里 guard 清 bitmap),
        // 重连→强制重新拉取(forceRefresh 跳过旧缓存)。否则列表停在断开前。
        connObserver = NotificationCenter.default.addObserver(
            forName: .deviceConnectionChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh(forceRefresh: true) }
        }
    }

    private var connObserver: Any?

    /// Check if device connection state changed and invalidate cache if needed
    private func checkConnectionStateChange() {
        let currentlyConnected = bleManager.deviceState.isConnected

        // If connection state changed from disconnected to connected, invalidate cache
        if currentlyConnected && !Self.lastConnectionState {
            NSLog("FingerprintView: Device reconnected, invalidating cache")
            Self.isCacheValid = false
        }

        // If disconnected, reset cache
        if !currentlyConnected && Self.lastConnectionState {
            NSLog("FingerprintView: Device disconnected, clearing cache")
            Self.isCacheValid = false
            Self.cachedBitmap = 0
        }

        Self.lastConnectionState = currentlyConnected
    }

    /// Invalidate cache (call from outside when device reconnects)
    static func invalidateCache() {
        isCacheValid = false
        NSLog("FingerprintView: Cache invalidated externally")
    }

    private var gateObserver: Any?
    private var enrollObserver: Any?

    deinit {
        [gateObserver, enrollObserver, connObserver].compactMap { $0 }
            .forEach(NotificationCenter.default.removeObserver)
    }

    private func setupEnrollmentCallback() {
        // When device requires FP verification before executing a command
        gateObserver = NotificationCenter.default.addObserver(
            forName: BLEManager.fingerprintGateRequiredNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                // Gate sheet handles FP verification UI for both delete and enroll
                if self.isLoading || self.currentEnrollSlot != nil {
                    self.gateController.onGateRequired()
                }
                // 设备对 ENROLL_START 回了 WAIT_FP：门过之后先进「换手指」过渡。
                if self.currentEnrollSlot != nil {
                    self.handoff.arm()
                }
            }
        }

        // 监听广播而不是赋值 bleManager.onEnrollStatus：那是单槽闭包，向导页 /
        // 设置页 / 指纹页的多个 ViewModel 会互相覆盖（见 BLEManager.enrollStatusNotification）。
        enrollObserver = NotificationCenter.default.addObserver(
            forName: BLEManager.enrollStatusNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let payload = EnrollStatusPayload(note) else { return }
            let (event, current, total) = (payload.event, payload.current, payload.total)
            Task { @MainActor in
                // isArmed：门刚过、completion 还没把 isEnrolling 置 true 时到达的帧
                // 也要让过渡状态机看到（见 EnrollHandoff.frame 的 .armed 分支）。
                guard let self = self, self.isEnrolling || self.handoff.isArmed else { return }
                let decision = self.handoff.frame(payload)
                self.syncHandoff()
                guard decision == .apply, self.isEnrolling else { return }
                self.applyEnrollFrame(payload)
            }
        }
    }

    /// 把过渡状态机的结论同步到界面；过渡结束时顺手停掉停留计时。
    private func syncHandoff() {
        let active = handoff.isActive
        if !active { handoffDwellTask?.cancel() }
        if enrollHandoff != active { enrollHandoff = active }
    }

    /// 过渡画面至少停留 EnrollHandoff.minDwell；这期间压着的帧到点再处理。
    private func startHandoffDwell() {
        handoffDwellTask?.cancel()
        handoffDwellTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(EnrollHandoff.minDwell * 1_000_000_000))
            guard let self = self, !Task.isCancelled, self.isEnrolling else { return }
            let held = self.handoff.dwellDidElapse()
            self.syncHandoff()
            if let held = held { self.applyEnrollFrame(held) }
        }
    }

    private func endHandoff() {
        handoff.reset()
        syncHandoff()
    }

    /// 第一次采集之前「请放手指」的提示：过了门的录入要强调换成新手指。
    private var placeFingerStatus: String {
        (enrollViaGate && enrollmentProgress == 0
            ? "enroll.place.finger.new" : "enroll.place.finger").localized
    }

    private func applyEnrollFrame(_ payload: EnrollStatusPayload) {
        let (event, current, total) = (payload.event, payload.current, payload.total)

        if total > 0 {
            enrollmentTotal = total
        }

        switch event {
        case .waiting:
            enrollmentProgress = current
            enrollmentStatus = placeFingerStatus
        case .captured:
            enrollmentStatus = "enroll.captured".localized(current, total)
            enrollmentProgress = current
        case .liftFinger:
            enrollmentProgress = current
            // 过门后的第一次采集之前，这一帧是「旧手指已抬起」——该放新手指了。
            enrollmentStatus = enrollViaGate && current == 0
                ? placeFingerStatus : "enroll.lift.finger".localized
        case .processing:
            enrollmentStatus = "enroll.processing".localized
            enrollmentProgress = current
        case .overlap:
            // (mode 1) device rejected this capture for overlapping the
            // previous one too much. Don't advance progress — prompt the
            // user to shift position and bump the nudge so the sheet shakes.
            enrollmentStatus = "enroll.adjust.overlap".localized
            overlapNudge &+= 1
        case .complete:
            NSLog("FingerprintView: enrollment complete, old bitmap=0x%02X", fingerprintBitmap)
            isEnrolling = false
            enrollmentProgress = total
            // Update local cache (don't fetch from device)
            // Set bit for the enrolled slot
            if let slot = currentEnrollSlot {
                fingerprintBitmap |= (1 << slot)
                Self.cachedBitmap = fingerprintBitmap
                Self.isCacheValid = true
                NotificationCenter.default.post(name: .fingerprintCacheUpdated, object: nil)
            }
            currentEnrollSlot = nil
            NSLog("FingerprintView: new bitmap=0x%02X (cached)", fingerprintBitmap)
            showAlert(title: "enroll.success".localized, message: "enroll.success.message".localized)
        case .failed:
            isEnrolling = false
            currentEnrollSlot = nil
            // 失败帧的 current 是原因码（固件 1.8.9+，见 EnrollFailReason）。
            let reasonKey = current == EnrollFailReason.duplicate
                ? "enroll.failed.duplicate" : "enroll.failed.message"
            showAlert(title: "enroll.failed".localized, message: reasonKey.localized)
        }
    }

    /// completion 在位图就绪后回调（断连/缓存命中时同步调用）——调用方
    /// 想「刷新后立刻取 nextAvailableSlot」必须等它，否则 fetch 未回来时
    /// isLoading 还是 true，enrollFingerprint 的 guard 会静默吞掉点击。
    func refresh(forceRefresh: Bool = false, completion: (() -> Void)? = nil) {
        NSLog("FingerprintView: refresh called, force=%d", forceRefresh ? 1 : 0)

        // Check if connection state changed (invalidates cache if reconnected)
        checkConnectionStateChange()

        isDeviceConnected = bleManager.deviceState.isConnected
        refreshSwitchSlotSupport()

        guard isDeviceConnected else {
            NSLog("FingerprintView: device not connected")
            fingerprintBitmap = 0
            isLoading = false
            // 录入进行中断连：enroll 事件不会再来（BLE 断开只冲
            // responseCallback/gateCompletion），不在这里收尾的话
            // 录入 sheet 会永远停在「请将手指放在传感器上」。
            if isEnrolling {
                isEnrolling = false
                currentEnrollSlot = nil
                endHandoff()
                showAlert(title: "enroll.failed".localized,
                          message: "enroll.disconnected.message".localized)
            }
            completion?()
            return
        }

        // Use cached value if valid and not forcing refresh
        if Self.isCacheValid && !forceRefresh {
            NSLog("FingerprintView: using cached bitmap 0x%02X", Self.cachedBitmap)
            fingerprintBitmap = Self.cachedBitmap
            isLoading = false
            completion?()
            return
        }

        // Fetch from device
        isLoading = true
        bleManager.getFingerprintBitmap { [weak self] bitmap in
            NSLog("FingerprintView: getFingerprintBitmap returned 0x%02X", bitmap)
            DispatchQueue.main.async {
                guard let self = self else { return }
                NSLog("FingerprintView: setting fingerprintBitmap to 0x%02X", bitmap)
                self.fingerprintBitmap = bitmap
                Self.cachedBitmap = bitmap
                Self.isCacheValid = true
                // 固件版本与指纹位图来自同一个 GET_STATUS 响应，在这里
                // 一并刷新，两者才不会错位（版本晚到会让界面停在 5 槽）。
                self.refreshSwitchSlotSupport()
                self.isLoading = false
                self.objectWillChange.send()
                NotificationCenter.default.post(name: .fingerprintCacheUpdated, object: nil)
                completion?()
            }
        }
    }

    /// Force refresh from device (CMD+R)
    func forceRefresh() {
        refresh(forceRefresh: true)
    }

    func enrollFingerprint(slot: Int) {
        guard !isEnrolling, !isLoading, !gateController.isPresented else { return }

        NSLog("FingerprintView: enrollFingerprint called with slot=%d, bitmap=0x%02X, nextAvailable=%@",
              slot, fingerprintBitmap, nextAvailableSlot.map { String($0) } ?? "nil")

        // 已有指纹时固件会先要求用旧指纹验证，验证通过立即进入捕获——
        // 用户容易顺手用同一根手指继续按，把旧手指又录一遍。先弹确认框
        // 讲清楚「验证用旧手指、录入换新手指」再开始。
        if fingerprintCount > 0 {
            let alert = NSAlert()
            alert.messageText = "enroll.confirm.newfinger.title".localized
            alert.informativeText = "enroll.confirm.newfinger.message".localized
            alert.addButton(withTitle: "enroll.confirm.continue".localized)
            alert.addButton(withTitle: "alert.cancel".localized)
            guard alert.runModalOverSettings() == .alertFirstButtonReturn else { return }
        }

        isLoading = true  // Immediately block UI to prevent duplicate clicks
        currentEnrollSlot = slot
        enrollmentProgress = 0
        enrollViaGate = false
        endHandoff()

        // If fingerprints already enrolled, firmware requires FP verification first
        if fingerprintCount > 0 {
            gateController.present(title: "fingerprint.add".localized,
                                   hint: "enroll.verify.hint".localized,
                                   onCancel: { [weak self] in
                self?.currentEnrollSlot = nil
                self?.isLoading = false
            })
        }

        bleManager.startEnrollment(slotId: UInt8(slot)) { [weak self] success in
            Task { @MainActor in
                guard let self = self else { return }
                self.isLoading = false
                if success {
                    // Gate succeeded (or wasn't needed) — transition to enrollment sheet.
                    // resolveAndDismiss (NOT reset): firmware already cleared the
                    // pending gate on FP match, so sending GATE_CANCEL would just
                    // fire the firmware's red 1s flash over the enroll green-blink.
                    self.gateController.resolveAndDismiss()
                    // 真的过了门：旧手指还按在传感器上，先停在「验证通过，换成新手指」，
                    // 等用户抬手（且至少停够 minDwell）再摆采集引导。
                    self.enrollViaGate = self.handoff.begin()
                    self.syncHandoff()
                    self.isEnrolling = true
                    self.enrollmentStatus = self.placeFingerStatus
                    if self.enrollViaGate { self.startHandoffDwell() }
                } else {
                    self.endHandoff()
                    // 用户主动 cancel 时 controller.cancel() 的 onCancel 已经
                    // 把 currentEnrollSlot 清空; cancelGateAndRelease 会用
                    // false invoke 这个 completion. 不弹错误也不 reportFailed.
                    guard self.currentEnrollSlot != nil else { return }
                    if self.gateController.isPresented {
                        self.gateController.reportFailed()
                    } else {
                        self.showAlert(title: "enroll.failed".localized, message: "enroll.failed.start".localized)
                    }
                    self.currentEnrollSlot = nil
                }
            }
        }
    }

    func deleteFingerprint(slot: Int) {
        // 指纹门的「触摸传感器」是每天几十次的反射动作，替代不了删除确认；
        // 误点垃圾桶 + 顺手一摸 = 无挽回误删。先用文字讲清删哪根、什么后果。
        let name = fingerprintName(for: slot)
        let confirm = NSAlert()
        confirm.messageText = "fingerprint.delete.confirm.title".localized(name)
        confirm.informativeText = (slot == Self.switchSlotIndex
            ? "fingerprint.delete.confirm.switch.message"
            : "fingerprint.delete.confirm.message").localized
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "alert.delete".localized)
        confirm.addButton(withTitle: "alert.cancel".localized)
        // 不要设 hasDestructiveAction：macOS 27 深色模式的 sheet 里，
        // 破坏性按钮会被画成不可见，弹窗只剩「取消」。
        guard confirm.runModalOverSettings() == .alertFirstButtonReturn else { return }

        isLoading = true
        gateController.present(title: "fingerprint.delete.gate.title".localized(name),
                               onCancel: { [weak self] in
            self?.isLoading = false
        })

        bleManager.deleteFingerprint(slotId: UInt8(slot)) { [weak self] success in
            NSLog("FingerprintView: deleteFingerprint callback, success=%d", success ? 1 : 0)
            DispatchQueue.main.async {
                guard let self = self else { return }
                NSLog("FingerprintView: updating UI, old bitmap=0x%02X", self.fingerprintBitmap)
                self.isLoading = false
                if success {
                    self.gateController.reportSuccess()
                    self.fingerprintBitmap &= ~UInt8(1 << slot)
                    Self.cachedBitmap = self.fingerprintBitmap
                    Self.isCacheValid = true
                    self.fingerprintNames.removeValue(forKey: slot)
                    self.saveFingerprintNames()
                    NotificationCenter.default.post(name: .fingerprintCacheUpdated, object: nil)
                    NSLog("FingerprintView: new bitmap=0x%02X (cached)", self.fingerprintBitmap)
                } else {
                    self.gateController.reportFailed()
                }
            }
        }
    }

    func cancelEnrollment() {
        isEnrolling = false
        enrollmentStatus = ""
        enrollmentProgress = 0
        currentEnrollSlot = nil
        endHandoff()
        bleManager.cancelEnrollment()
    }

    func testFingerprint() {
        guard bleManager.deviceState.isConnected, !gateController.isPresented else { return }

        gateController.present(title: "fingerprint.test".localized)

        bleManager.requestUnlock(timeout: 30.0) { [weak self] success in
            Task { @MainActor in
                if success {
                    self?.gateController.reportSuccess()
                } else {
                    self?.gateController.reportFailed()
                }
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModalOverSettings()
    }
}
