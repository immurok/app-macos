import SwiftUI
import Combine

extension Notification.Name {
    static let fingerprintCacheUpdated = Notification.Name("fingerprintCacheUpdated")
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

            Divider()

            // Settings toggles
            settingsSection

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

                    // Show add button if less than 5 fingerprints
                    if viewModel.fingerprintCount < 5 {
                        addFingerprintButton
                    }

                    Spacer()
                }
                .padding(.vertical, 16)
                .id(viewModel.fingerprintBitmap)  // Force refresh when bitmap changes
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

    // MARK: - Settings Section

    private var settingsSection: some View {
        VStack(spacing: 0) {
            settingRow(
                title: "feature.unlock.mac".localized,
                isOn: $viewModel.unlockEnabled
            )

            Divider().padding(.leading, 16)

            settingRow(
                title: "feature.sudo".localized,
                isOn: $viewModel.sudoEnabled
            )

            Divider().padding(.leading, 16)

            settingRow(
                title: "feature.system.auth".localized,
                isOn: $viewModel.systemPrefsEnabled
            )
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }

    private func settingRow(title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.body)

            Spacer()

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// Separate view for hover state
struct FingerprintIconView: View {
    let index: Int
    let name: String
    let onDelete: () -> Void
    let onRename: (String) -> Void
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

            if isEditing {
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
                        editText = name
                        isEditing = true
                    }
            }
        }
    }
}

// MARK: - Enrollment Step Helpers

/// 12-step guided enrollment offset map (椭圆偏移量，px).
/// progress 1..4: 正中 / 5..7: 左偏 / 8..10: 右偏 / 11: 上偏 / 12: 下偏
/// Out-of-range progress (0 pre-start, >12 post-complete) returns .zero.
fileprivate func enrollOffsetForStep(_ progress: Int) -> CGSize {
    switch progress {
    case 1...4:  return .zero
    case 5...7:  return CGSize(width: -16, height: 0)
    case 8...10: return CGSize(width: 16, height: 0)
    case 11:     return CGSize(width: 0, height: -16)
    case 12:     return CGSize(width: 0, height: 16)
    default:     return .zero
    }
}

/// SF Symbol name for direction arrow at given step.
fileprivate func enrollArrowSymbolForStep(_ progress: Int) -> String {
    switch progress {
    case 1...4:  return "arrow.up"
    case 5...7:  return "arrow.left"
    case 8...10: return "arrow.right"
    case 11:     return "arrow.up"
    case 12:     return "arrow.down"
    default:     return "arrow.up"
    }
}

/// Arrow position offset relative to the 60×80 ellipse (椭圆外侧).
/// Direction-aware: arrow sits outside the ellipse in the same direction
/// the user should tilt toward.
fileprivate func enrollArrowOffsetForStep(_ progress: Int) -> CGSize {
    switch progress {
    case 1...4:  return CGSize(width: 0, height: -55)   // 顶部居中
    case 5...7:  return CGSize(width: -55, height: 0)   // 左侧
    case 8...10: return CGSize(width: 55, height: 0)    // 右侧
    case 11:     return CGSize(width: 0, height: -55)   // 顶部
    case 12:     return CGSize(width: 0, height: 55)    // 底部
    default:     return CGSize(width: 0, height: -55)
    }
}

/// Localization key for the step's primary title text.
fileprivate func enrollTitleKeyForStep(_ progress: Int) -> String {
    switch progress {
    case 1:      return "enroll.step.center.first"
    case 2...4:  return "enroll.step.center.keep"
    case 5:      return "enroll.step.left.first"
    case 6...7:  return "enroll.step.left.keep"
    case 8:      return "enroll.step.right.first"
    case 9...10: return "enroll.step.right.keep"
    case 11:     return "enroll.step.up"
    case 12:     return "enroll.step.down"
    default:     return "enroll.step.center.first"
    }
}

/// True for the 4 steps where the angle category changes (用于颜色闪烁触发).
/// Step 5: 正中→左, Step 8: 左→右, Step 11: 右→上, Step 12: 上→下.
fileprivate func enrollIsTransitionStep(_ progress: Int) -> Bool {
    progress == 5 || progress == 8 || progress == 11 || progress == 12
}

// MARK: - Enrollment Sheet

struct EnrollmentSheet: View {
    @ObservedObject var viewModel: FingerprintViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var pulseScale: CGFloat = 1.0
    @State private var arrowOpacity: Double = 1.0
    @State private var transitionFlash: Bool = false

    /// Step the user should perform NEXT (1..12).
    /// `enrollmentProgress` 是已完成捕获帧数; UI 要提示下一帧姿势, 所以 +1.
    /// progress=0 (init) → 1; progress=12 (完成) → 12.
    private var animProgress: Int {
        min(max(viewModel.enrollmentProgress + 1, 1), 12)
    }

    private var isTransitionStep: Bool {
        enrollIsTransitionStep(animProgress)
    }

    /// 正中阶段 (1..4) 不显示方向箭头, 避免被误读为"向上偏移".
    private var showArrow: Bool {
        animProgress >= 5
    }

    var body: some View {
        VStack(spacing: 20) {
            // sensor 圆 + 偏移椭圆 + 方向箭头
            ZStack {
                // 背景圆（不变）
                Circle()
                    .fill(Color(NSColor.controlBackgroundColor))
                    .frame(width: 120, height: 120)

                // pulse 圆（不变，等待手指视觉提示）
                Circle()
                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 2)
                    .frame(width: 60, height: 60)
                    .scaleEffect(pulseScale)
                    .opacity(2.0 - Double(pulseScale))

                // 手指椭圆（按 progress 偏移）
                RoundedRectangle(cornerRadius: 30)
                    .fill(transitionFlash ? Color.orange : Color.accentColor)
                    .frame(width: 60, height: 80)
                    .offset(enrollOffsetForStep(animProgress))
                    .opacity(viewModel.enrollmentProgress > 0 ? 1.0 : 0.5)
                    .animation(.easeInOut(duration: 0.3), value: animProgress)

                // 方向箭头（位置 + symbol 都按 progress 切换, 正中阶段隐藏）
                Image(systemName: enrollArrowSymbolForStep(animProgress))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.accentColor)
                    .offset(enrollArrowOffsetForStep(animProgress))
                    .opacity(showArrow ? arrowOpacity : 0)
                    .animation(.easeInOut(duration: 0.3), value: animProgress)
            }

            // 主步骤标题（切换步加粗）
            Text(enrollTitleKeyForStep(animProgress).localized)
                .font(.headline)
                .fontWeight(isTransitionStep ? .semibold : .regular)
                .multilineTextAlignment(.center)

            // 现有 status text（waiting / captured / lift_finger 等动态文案）
            Text(viewModel.enrollmentStatus)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            ProgressView(value: Double(viewModel.enrollmentProgress), total: Double(viewModel.enrollmentTotal))
                .frame(width: 200)

            Text("\(viewModel.enrollmentProgress)/\(viewModel.enrollmentTotal)")
                .font(.caption)
                .foregroundColor(.secondary)

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
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulseScale = 1.6
            }
            // 箭头脉动节奏（0.8s 周期）
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                arrowOpacity = 0.4
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
    @Published var enrollmentTotal = 12  // Single-slot: 12 captures per enrollment

    var gateController = FingerprintGateController()

    // Track current enrollment slot
    private var currentEnrollSlot: Int?

    // Computed properties for bitmap
    var fingerprintCount: Int {
        (0..<5).filter { fingerprintBitmap & (1 << $0) != 0 }.count
    }

    /// List of enrolled slot indices
    var enrolledSlots: [Int] {
        (0..<5).filter { fingerprintBitmap & (1 << $0) != 0 }
    }

    /// Find first available slot for enrollment (returns nil if all slots full)
    var nextAvailableSlot: Int? {
        (0..<5).first { fingerprintBitmap & (1 << $0) == 0 }
    }

    // Settings (stored in UserDefaults)
    @Published var unlockEnabled: Bool {
        didSet { UserDefaults.standard.set(unlockEnabled, forKey: "immurok.unlockEnabled") }
    }
    @Published var sudoEnabled: Bool {
        didSet { UserDefaults.standard.set(sudoEnabled, forKey: "immurok.sudoEnabled") }
    }
    @Published var systemPrefsEnabled: Bool {
        didSet { UserDefaults.standard.set(systemPrefsEnabled, forKey: "immurok.systemPrefsEnabled") }
    }

    // Fingerprint names (stored in UserDefaults, not synced to firmware)
    @Published var fingerprintNames: [Int: String] = [:]

    func fingerprintName(for slot: Int) -> String {
        fingerprintNames[slot] ?? "fingerprint.finger".localized(slot + 1)
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
        unlockEnabled = UserDefaults.standard.bool(forKey: "immurok.unlockEnabled")
        sudoEnabled = UserDefaults.standard.bool(forKey: "immurok.sudoEnabled")
        systemPrefsEnabled = UserDefaults.standard.bool(forKey: "immurok.systemPrefsEnabled")

        // Default to enabled if not set
        if !UserDefaults.standard.bool(forKey: "immurok.settingsInitialized") {
            unlockEnabled = true
            sudoEnabled = true
            systemPrefsEnabled = true
            UserDefaults.standard.set(true, forKey: "immurok.settingsInitialized")
        }

        // Forward gate controller changes so SwiftUI sheet binding updates
        gateCancellable = gateController.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        loadFingerprintNames()
        setupEnrollmentCallback()
    }

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
            }
        }

        bleManager.onEnrollStatus = { [weak self] event, current, total in
            Task { @MainActor in
                guard let self = self, self.isEnrolling else { return }

                if total > 0 {
                    self.enrollmentTotal = total
                }

                switch event {
                case .waiting:
                    self.enrollmentStatus = "enroll.place.finger".localized
                    self.enrollmentProgress = current
                case .captured:
                    self.enrollmentStatus = "enroll.captured".localized(current, total)
                    self.enrollmentProgress = current
                case .liftFinger:
                    self.enrollmentStatus = "enroll.lift.finger".localized
                    self.enrollmentProgress = current
                case .processing:
                    self.enrollmentStatus = "enroll.processing".localized
                    self.enrollmentProgress = current
                case .complete:
                    NSLog("FingerprintView: enrollment complete, old bitmap=0x%02X", self.fingerprintBitmap)
                    self.isEnrolling = false
                    self.enrollmentProgress = total
                    // Update local cache (don't fetch from device)
                    // Set bit for the enrolled slot
                    if let slot = self.currentEnrollSlot {
                        self.fingerprintBitmap |= (1 << slot)
                        Self.cachedBitmap = self.fingerprintBitmap
                        Self.isCacheValid = true
                        NotificationCenter.default.post(name: .fingerprintCacheUpdated, object: nil)
                    }
                    self.currentEnrollSlot = nil
                    NSLog("FingerprintView: new bitmap=0x%02X (cached)", self.fingerprintBitmap)
                    self.showAlert(title: "enroll.success".localized, message: "enroll.success.message".localized)
                case .failed:
                    self.isEnrolling = false
                    self.currentEnrollSlot = nil
                    self.showAlert(title: "enroll.failed".localized, message: "enroll.failed.message".localized)
                }
            }
        }
    }

    func refresh(forceRefresh: Bool = false) {
        NSLog("FingerprintView: refresh called, force=%d", forceRefresh ? 1 : 0)

        // Check if connection state changed (invalidates cache if reconnected)
        checkConnectionStateChange()

        isDeviceConnected = bleManager.deviceState.isConnected

        guard isDeviceConnected else {
            NSLog("FingerprintView: device not connected")
            fingerprintBitmap = 0
            isLoading = false
            return
        }

        // Use cached value if valid and not forcing refresh
        if Self.isCacheValid && !forceRefresh {
            NSLog("FingerprintView: using cached bitmap 0x%02X", Self.cachedBitmap)
            fingerprintBitmap = Self.cachedBitmap
            isLoading = false
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
                self.isLoading = false
                self.objectWillChange.send()
                NotificationCenter.default.post(name: .fingerprintCacheUpdated, object: nil)
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

        isLoading = true  // Immediately block UI to prevent duplicate clicks
        currentEnrollSlot = slot
        enrollmentProgress = 0

        // If fingerprints already enrolled, firmware requires FP verification first
        if fingerprintCount > 0 {
            gateController.present(title: "fingerprint.add".localized, onCancel: { [weak self] in
                self?.currentEnrollSlot = nil
                self?.isLoading = false
            })
        }

        bleManager.startEnrollment(slotId: UInt8(slot)) { [weak self] success in
            Task { @MainActor in
                guard let self = self else { return }
                self.isLoading = false
                if success {
                    // Gate succeeded (or wasn't needed) — transition to enrollment sheet
                    self.gateController.reset()
                    self.isEnrolling = true
                    self.enrollmentStatus = "enroll.place.finger".localized
                } else {
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
        isLoading = true
        gateController.present(title: "fingerprint.delete".localized, onCancel: { [weak self] in
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
