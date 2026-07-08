import AppKit
import SwiftUI
import Combine

// MARK: - Key Entry Model

struct QuickFillEntry: Identifiable, Sendable {
    let index: Int
    let name: String
    let service: String  // OTP service name; empty for SSH/API
    let category: KeystoreCategory

    var id: String { "\(category.rawValue)-\(index)-\(name)" }

    var subtitle: String {
        if !service.isEmpty { return service }
        switch category {
        case .ssh: return "SSH"
        case .api: return "API"
        case .otp: return "OTP"
        }
    }

    var iconName: String {
        switch category {
        case .ssh: return "key"
        case .api: return "key.fill"
        case .otp: return "lock.rotation"
        }
    }

    var needsFingerprint: Bool {
        category != .ssh
    }
}

// MARK: - ViewModel

class QuickFillViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var entries: [QuickFillEntry] = []
    @Published var selectedIndex = 0
    @Published var isLoading = true

    // Fingerprint verification state (drives the right icon)
    @Published var isVerifying = false
    @Published var verifyProgress: CGFloat = 1.0   // 1.0 → 0.0 over 30s
    @Published var showRedFlash = false

    // Panel height
    @Published var visibleRowCount = 0

    var onDismiss: (() -> Void)?
    /// Fires the moment a fingerprint-gated read succeeds (OTP response back,
    /// AUTH_REQUEST FP matched). Used by AppDelegate to mark `lastAuthFlowAt`
    /// so the trailing 0x23 LOCK_REQUEST that the device sends 1s after touch
    /// — and which arrives milliseconds AFTER the OTP response — gets
    /// suppressed by the existing 3s lock-suppress window. Without this the
    /// race between "BLE main.async clears isVerifying" and "BLE main.async
    /// handles LOCK_REQUEST" lets the lock fire.
    var onAuthSuccess: (() -> Void)?
    var isConfirming = false

    static let maxVisible = 6
    static let searchBarHeight: CGFloat = 60
    static let rowHeight: CGFloat = 52
    static let dividerHeight: CGFloat = 1
    static let listPadding: CGFloat = 8

    private static let verifyDuration: TimeInterval = 30

    private var previousApp: NSRunningApplication?
    private var verifyTimer: Timer?
    private var verifyStartTime: Date?
    private var verifyEntry: QuickFillEntry?
    /// Saved BLEManager.onFingerprintAttemptFailed handler, restored when
    /// verification ends. While verifying we flash red on each wrong finger.
    private var previousAttemptFailed: ((Int) -> Void)?

    /// 分类前缀: "o " → OTP, "a " → API, "s " → SSH
    private static let categoryPrefixes: [(prefix: String, cat: KeystoreCategory)] = [
        ("o ", .otp), ("a ", .api), ("s ", .ssh),
    ]

    var filteredEntries: [QuickFillEntry] {
        if searchText.isEmpty { return entries }

        let text = searchText.lowercased()

        for (prefix, cat) in Self.categoryPrefixes {
            if text.hasPrefix(prefix) {
                let nameQuery = String(text.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                return entries.filter { entry in
                    entry.category == cat &&
                    (nameQuery.isEmpty || entry.name.lowercased().contains(nameQuery)
                     || entry.service.lowercased().contains(nameQuery))
                }
            }
        }

        return entries.filter {
            $0.name.lowercased().contains(text) || $0.service.lowercased().contains(text)
        }
    }

    /// 搜索结果下方要展示的行。
    /// 校验中只显示正在校验的条目 (verifyEntry)——绝不能用 selectedIndex 去下标
    /// `filteredEntries.prefix(maxVisible)` 后的数组：selectedIndex 是完整
    /// filteredEntries 的下标，当命中条目排在第 maxVisible(6) 位之后时会越界崩溃
    /// （例如 OTP 与 API/SSH 共用同一 service 时，按名字确认后过滤仍 >6 条）。
    /// 2026-07-03 修复 QuickFillPanel.swift:567 "Index out of range"。
    var displayRows: [QuickFillEntry] {
        if isVerifying {
            return verifyEntry.map { [$0] } ?? []
        }
        return Array(filteredEntries.prefix(Self.maxVisible))
    }

    func loadEntries() {
        previousApp = NSWorkspace.shared.frontmostApplication

        let cache = KeyNameCache.shared
        if cache.isSynced {
            applyCache()
            isLoading = false
        } else {
            isLoading = true
            cache.sync { [weak self] in
                DispatchQueue.main.async {
                    self?.applyCache()
                    self?.isLoading = false
                }
            }
        }
    }

    private func applyCache() {
        let cached = KeyNameCache.shared.entries
        entries = cached.map { QuickFillEntry(index: $0.index, name: $0.name, service: $0.service, category: $0.category) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        selectedIndex = 0
    }

    func updateVisibleCount() {
        let count: Int
        if isVerifying {
            count = 1
        } else {
            count = searchText.isEmpty ? 0 : min(filteredEntries.count, Self.maxVisible)
        }
        if visibleRowCount != count {
            visibleRowCount = count
        }
    }

    func moveSelection(_ delta: Int) {
        guard !isVerifying else { return }
        let count = filteredEntries.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    func confirmSelection() {
        guard !isVerifying else { return }
        let filtered = filteredEntries
        guard selectedIndex >= 0, selectedIndex < filtered.count else { return }
        let entry = filtered[selectedIndex]

        isConfirming = true
        searchText = entry.name

        // searchText 变更后 filteredEntries 重新计算，同步 selectedIndex
        if let newIdx = filteredEntries.firstIndex(where: { $0.id == entry.id }) {
            selectedIndex = newIdx
        } else {
            selectedIndex = 0
        }

        if entry.category == .otp {
            // OTP: single-step device-side TOTP (includes FP gate)
            startOTPVerification(entry: entry)
        } else if entry.needsFingerprint {
            startVerification(entry: entry)
        } else {
            Task { [weak self] in
                let value = await QuickFillBLEHelper.readSSH(entry: entry)
                DispatchQueue.main.async {
                    if let value = value {
                        self?.pasteAndClose(value)
                    } else {
                        self?.onDismiss?()
                    }
                }
            }
        }
    }

    // MARK: - OTP Verification (single-step, device-side TOTP)

    private func startOTPVerification(entry: QuickFillEntry) {
        beginVerification(entry: entry)

        Task { [weak self] in
            let code: String? = await withCheckedContinuation { cont in
                BLEManager.shared.requestOTP(idx: UInt8(entry.index)) { result in
                    cont.resume(returning: result)
                }
            }

            DispatchQueue.main.async {
                guard let self = self, self.isVerifying else { return }
                if code != nil {
                    // Mark auth flow active BEFORE stopVerification clears
                    // isVerifying, so the trailing 0x23 LOCK_REQUEST (sent
                    // by firmware at 1s after touch — typically arrives
                    // milliseconds after this OTP response) finds either
                    // isVerifying=true or lastAuthFlowAt fresh.
                    self.onAuthSuccess?()
                }
                self.stopVerification()
                if let code = code {
                    self.typeAndClose(code)
                } else {
                    // Device ended the gate (3 wrong fingers or its 25s timeout)
                    // — it has already stopped. Just close the UI. Per-attempt
                    // red flashes were shown via onFingerprintAttemptFailed.
                    self.flashRedAndDismiss()
                }
            }
        }
    }

    /// Shared verification setup for both OTP and fingerprint-gated reads:
    /// state, the per-attempt red-flash handler, and the countdown timer.
    private func beginVerification(entry: QuickFillEntry) {
        isVerifying = true
        verifyProgress = 1.0
        showRedFlash = false
        verifyEntry = entry
        verifyStartTime = Date()

        // The device sends 0x07 (wrong finger) for the first two attempts and
        // keeps its gate open; flash red so the user knows to try again.
        previousAttemptFailed = BLEManager.shared.onFingerprintAttemptFailed
        BLEManager.shared.onFingerprintAttemptFailed = { [weak self] _ in
            DispatchQueue.main.async { self?.triggerRedFlash() }
        }

        // Countdown timer. If our window expires before the device ends its own
        // gate, cancel the device gate so it stops blinking.
        verifyTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.verifyStartTime else { return }
            let remaining = max(0, 1.0 - Date().timeIntervalSince(start) / Self.verifyDuration)
            self.verifyProgress = remaining
            if remaining <= 0 {
                self.verifyTimer?.invalidate()
                self.verifyTimer = nil
                self.cancelDeviceGate()
                self.flashRedAndDismiss()
            }
        }
    }

    // MARK: - Fingerprint Verification

    private func startVerification(entry: QuickFillEntry) {
        beginVerification(entry: entry)
        attemptVerify(entry: entry)
    }

    private func attemptVerify(entry: QuickFillEntry) {
        guard isVerifying, let start = verifyStartTime else { return }
        let remaining = Self.verifyDuration - Date().timeIntervalSince(start)
        guard remaining > 1 else { return }

        Task { [weak self] in
            // A SINGLE requestUnlock spans all device-side attempts. The
            // firmware flashes 0x07 (shown as red via onFingerprintAttemptFailed)
            // for the first two wrong fingers while keeping its gate open, then
            // ends the gate on the third failure / its timeout → returns false.
            // Do NOT re-arm a new AUTH_REQUEST per failure (the old loop did,
            // desyncing the app's retry count from the device's and leaving the
            // UI counting down after the device had already given up).
            let approved: Bool = await withCheckedContinuation { cont in
                BLEManager.shared.requestUnlock(timeout: remaining) { success in
                    cont.resume(returning: success)
                }
            }

            DispatchQueue.main.async {
                guard let self = self, self.isVerifying else { return }

                if approved {
                    // Same race as OTP: trailing 0x23 LOCK_REQUEST may
                    // arrive after the readValue completes. Mark flow active
                    // now so handleLockRequest's lastAuthFlowAt window covers
                    // it regardless of where in the post-match path we are.
                    self.onAuthSuccess?()
                    // Fingerprint matched — read value and paste
                    Task {
                        let value = await QuickFillBLEHelper.readValue(entry: entry)
                        DispatchQueue.main.async {
                            self.stopVerification()
                            if let value = value {
                                self.pasteAndClose(value)
                            } else {
                                self.onDismiss?()
                            }
                        }
                    }
                } else {
                    // Device ended the gate (3 wrong fingers or its 25s timeout)
                    // — it has already stopped. Close the UI.
                    self.flashRedAndDismiss()
                }
            }
        }
    }

    /// Tell the device to stop a still-open FP gate when we close the panel
    /// from the app side (Esc, click-away, or our countdown expiring before the
    /// device's). On a device-side terminal failure the gate is already gone,
    /// so this is only called from app-initiated closes.
    private func cancelDeviceGate() {
        guard let entry = verifyEntry else { return }
        if entry.category == .otp {
            BLEManager.shared.cancelGateAndRelease()
        } else {
            BLEManager.shared.cancelUnlock()
        }
    }

    /// Called by the panel controller when the window closes while a
    /// verification is still in flight (Esc / click-away).
    func cancelDeviceGateOnClose() {
        guard isVerifying else { return }
        cancelDeviceGate()
        stopVerification()
    }

    private func triggerRedFlash() {
        showRedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.showRedFlash = false
        }
    }

    private func flashRedAndDismiss() {
        showRedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.stopVerification()
            self?.onDismiss?()
        }
    }

    private func stopVerification() {
        verifyTimer?.invalidate()
        verifyTimer = nil
        isVerifying = false
        verifyEntry = nil
        verifyStartTime = nil
        showRedFlash = false
        // Restore whatever attempt-failed handler was installed before us.
        BLEManager.shared.onFingerprintAttemptFailed = previousAttemptFailed
        previousAttemptFailed = nil
    }

    // MARK: - Paste

    private func pasteAndClose(_ value: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)

        onDismiss?()

        let prevApp = previousApp

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            prevApp?.activate()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let src = CGEventSource(stateID: .hidSystemState)
                let vDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
                vDown?.flags = .maskCommand
                vDown?.post(tap: .cghidEventTap)
                let vUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
                vUp?.flags = .maskCommand
                vUp?.post(tap: .cghidEventTap)

                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    if pb.string(forType: .string) == value {
                        pb.clearContents()
                    }
                }
            }
        }
    }

    /// Type OTP code via virtual keyboard (no clipboard, no Enter)
    private func typeAndClose(_ code: String) {
        onDismiss?()

        let prevApp = previousApp
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            prevApp?.activate()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let src = CGEventSource(stateID: .hidSystemState)
                for ch in code.utf16 {
                    let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
                    var c = ch
                    down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
                    down?.post(tap: .cghidEventTap)
                    let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
                    up?.post(tap: .cghidEventTap)
                }
            }
        }
    }
}

// MARK: - BLE Helper

enum QuickFillBLEHelper {
    /// Read key value (after fingerprint already verified)
    /// Note: OTP is handled separately via requestOTP (device-side TOTP)
    static func readValue(entry: QuickFillEntry) async -> String? {
        switch entry.category {
        case .ssh: return await readSSH(entry: entry)
        case .api: return await readAPI(entry: entry)
        case .otp: return nil  // OTP uses device-side computation via startOTPVerification
        }
    }

    static func readSSH(entry: QuickFillEntry) async -> String? {
        guard let sshEntry = SSHKeyCache.shared.entries.first(where: { $0.name == entry.name }) else {
            return nil
        }
        return SSHKeyCache.formatOpenSSHPublicKey(blob: sshEntry.publicKeyBlob, comment: sshEntry.name)
    }

    private static func readAPI(entry: QuickFillEntry) async -> String? {
        // First attempt — if KEYSTORE/AUTH cooldown still active from a prior
        // op (recent sudo / OTP_GET / etc.) the firmware lets the secret
        // chunk through without prompting. Otherwise the second chunk
        // (off=32, into key region) returns SEC_ERR_WAIT_FP → readKeyEntry
        // returns nil. In that case fall back to AUTH_REQUEST + retry.
        if let secret = await readAPIChunked(idx: UInt8(entry.index)) {
            return secret
        }

        // Trigger FP gate via AUTH_REQUEST (existing infrastructure pops the
        // gate sheet on fingerprintGateRequiredNotification).
        let authed: Bool = await withCheckedContinuation { cont in
            BLEManager.shared.requestUnlock(timeout: 30.0) { ok in
                cont.resume(returning: ok)
            }
        }
        guard authed else { return nil }

        // After AUTH success, AUTH cooldown is fresh — retry.
        return await readAPIChunked(idx: UInt8(entry.index))
    }

    private static func readAPIChunked(idx: UInt8) async -> String? {
        let data: Data? = await withCheckedContinuation { cont in
            BLEManager.shared.readKeyEntry(cat: .api, idx: idx) { data in
                cont.resume(returning: data)
            }
        }
        // api_entry_t in firmware: name[32] + key[128] = 160 bytes
        guard let data = data, data.count > 32 else { return nil }
        let trimmed = data[32...].prefix(while: { $0 != 0 })
        return String(data: trimmed, encoding: .utf8)
    }
}

// MARK: - Fingerprint Countdown Icon

struct FingerprintCountdownIcon: View {
    let progress: CGFloat      // 1.0 (full) → 0.0 (empty)
    let showRedFlash: Bool

    @State private var flashOpacity: Double = 1.0

    private var iconColor: Color {
        showRedFlash ? .red : .accentColor
    }

    var body: some View {
        Image(systemName: "touchid")
            .font(.system(size: 28))
            .foregroundStyle(
                LinearGradient(
                    stops: gradientStops,
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .opacity(flashOpacity)
            .onChange(of: showRedFlash) { flashing in
                if flashing {
                    // Blink 3 times
                    withAnimation(.easeInOut(duration: 0.12).repeatCount(5, autoreverses: true)) {
                        flashOpacity = 0.15
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.1)) {
                        flashOpacity = 1.0
                    }
                }
            }
    }

    private var gradientStops: [Gradient.Stop] {
        let cutoff = 1.0 - progress  // 0.0 → 1.0 as time passes
        let bright = iconColor
        let dim = iconColor.opacity(0.12)
        return [
            .init(color: dim, location: 0),
            .init(color: dim, location: max(0, cutoff - 0.001)),
            .init(color: bright, location: min(1, cutoff + 0.001)),
            .init(color: bright, location: 1),
        ]
    }
}

// MARK: - SwiftUI View

struct QuickFillView: View {
    @ObservedObject var viewModel: QuickFillViewModel
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 0) {
                TextField(
                    viewModel.isLoading
                        ? "quickfill.syncing".localized
                        : "quickfill.search.placeholder".localized,
                    text: $viewModel.searchText
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 28, weight: .light))
                    .focused($isSearchFocused)
                    .disabled(viewModel.isVerifying || viewModel.isLoading)
                    .onSubmit {
                        viewModel.confirmSelection()
                    }

                Spacer(minLength: 8)

                // Right icon: fingerprint countdown during verification, key icon otherwise
                if viewModel.isVerifying {
                    FingerprintCountdownIcon(
                        progress: viewModel.verifyProgress,
                        showRedFlash: viewModel.showRedFlash
                    )
                } else {
                    Image(systemName: "key.viewfinder")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary.opacity(0.5))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: QuickFillViewModel.searchBarHeight)

            // Results
            if !viewModel.searchText.isEmpty && !viewModel.displayRows.isEmpty {
                Divider().padding(.horizontal, 8)
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.displayRows.enumerated()), id: \.element.id) { idx, entry in
                        QuickFillRow(
                            entry: entry,
                            isSelected: viewModel.isVerifying || idx == viewModel.selectedIndex,
                            shortcutIndex: viewModel.isVerifying ? nil : (idx < 9 ? idx + 1 : nil)
                        )
                        .onTapGesture {
                            if !viewModel.isVerifying {
                                viewModel.selectedIndex = idx
                                viewModel.confirmSelection()
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 520)
        .background(VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .onAppear {
            isSearchFocused = true
            viewModel.updateVisibleCount()
        }
        .onChange(of: viewModel.searchText) { _ in
            if viewModel.isConfirming {
                viewModel.isConfirming = false
            } else {
                viewModel.selectedIndex = 0
            }
            viewModel.updateVisibleCount()
        }
        .onChange(of: viewModel.isVerifying) { _ in
            viewModel.updateVisibleCount()
        }
        .onChange(of: viewModel.isLoading) { loading in
            if !loading {
                isSearchFocused = true
            }
        }
    }
}

// MARK: - Visual Effect Background

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Row

struct QuickFillRow: View {
    let entry: QuickFillEntry
    let isSelected: Bool
    let shortcutIndex: Int?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if entry.category == .otp {
                    OTPCountdownIcon()
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(iconBackground)
                        .frame(width: 36, height: 36)
                }
                Image(systemName: entry.iconName)
                    .font(.system(size: 16))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: 15))
                    .lineLimit(1)
                Text(entry.subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "return")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.5))
            } else if let idx = shortcutIndex {
                Text("\u{2318}\(idx)")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
        .frame(height: QuickFillViewModel.rowHeight)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .foregroundColor(isSelected ? .white : .primary)
        .padding(.horizontal, 6)
    }

    private var iconBackground: Color {
        switch entry.category {
        case .ssh: return .blue
        case .api: return .orange
        case .otp: return .green
        }
    }
}

// MARK: - OTP Countdown Icon

private struct OTPCountdownIcon: View {
    @State private var progress: Double = 1
    @State private var isUrgent: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(fillColor.opacity(0.3))
                .frame(width: 36, height: 36)
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: 36 * (1 - progress))
                fillColor
                    .frame(height: 36 * progress)
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .onAppear { scheduleNext() }
    }

    private var fillColor: Color { isUrgent ? .red : .green }

    private func scheduleNext() {
        let now = Date().timeIntervalSince1970
        let elapsed = now.truncatingRemainder(dividingBy: 30)
        let rem = 30 - elapsed
        isUrgent = rem <= 5
        progress = rem / 30

        // Animate to zero over remaining seconds
        withAnimation(.linear(duration: rem)) {
            progress = 0
        }

        // Schedule color change to red at the 5s mark
        if rem > 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + (rem - 5)) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isUrgent = true
                }
            }
        }

        // Reset at period boundary
        DispatchQueue.main.asyncAfter(deadline: .now() + rem) {
            isUrgent = false
            progress = 1
            scheduleNext()
        }
    }
}

// MARK: - NSPanel Wrapper

class QuickFillPanel {
    private var panel: NSPanel?
    private var viewModel: QuickFillViewModel?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var panelTopY: CGFloat?
    private var cancellable: AnyCancellable?

    /// Forwarded to the underlying QuickFillViewModel on `show()`. AppDelegate
    /// sets this so `lastAuthFlowAt` updates when a fingerprint-gated read
    /// returns — see the comment on QuickFillViewModel.onAuthSuccess for why
    /// timing-wise this matters versus the existing isVerifying guard.
    var onAuthSuccess: (() -> Void)?

    private static let panelWidth: CGFloat = 520

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    /// True between selection (AUTH_REQUEST sent) and verification completion.
    /// Used by AppDelegate.handleLockRequest to suppress the long-press lock
    /// while the user is in the middle of fingerprint-gated password access:
    /// the firmware clears pending_auth at match (~600ms) so its own
    /// LOCK_HOLD suppression doesn't fire, and there's no `lastAuthFlowAt`
    /// set until pasteAndClose runs much later.
    @MainActor
    var isVerifying: Bool {
        viewModel?.isVerifying ?? false
    }

    func show() {
        close()

        let vm = QuickFillViewModel()
        vm.onDismiss = { [weak self] in
            self?.close()
        }
        vm.onAuthSuccess = onAuthSuccess
        self.viewModel = vm

        let hostingView = NSHostingView(rootView: QuickFillView(viewModel: vm))

        let initialHeight = QuickFillViewModel.searchBarHeight
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: initialHeight),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = hostingView

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - Self.panelWidth / 2
            let topY = screenFrame.maxY - 200
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: topY))
        }

        self.panelTopY = panel.frame.maxY
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        cancellable = vm.$visibleRowCount
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] count in
                self?.resizePanel(visibleRows: count)
            }

        // The panel stays on top and is NOT dismissed by clicking outside it —
        // it closes only via Esc, picking an entry, or completing a fill. (We
        // previously closed on any outside click, which made it vanish while
        // the user was reaching for the sensor or interacting elsewhere.)

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.panel?.isVisible == true else { return event }

            switch event.keyCode {
            case 53: // ESC
                self.close()
                return nil
            case 126: // Up arrow
                self.viewModel?.moveSelection(-1)
                return nil
            case 125: // Down arrow
                self.viewModel?.moveSelection(1)
                return nil
            default:
                // ⌘1~⌘9 快速选择
                if event.modifierFlags.contains(.command),
                   let chars = event.charactersIgnoringModifiers,
                   let digit = chars.first?.wholeNumberValue,
                   digit >= 1 && digit <= 9 {
                    let idx = digit - 1
                    if let vm = self.viewModel, !vm.isVerifying,
                       idx < vm.filteredEntries.count {
                        vm.selectedIndex = idx
                        vm.confirmSelection()
                    }
                    return nil
                }
                return event
            }
        }

        vm.loadEntries()
    }

    private func resizePanel(visibleRows: Int) {
        guard let panel = panel, let topY = panelTopY else { return }

        let listHeight: CGFloat
        if visibleRows > 0 {
            listHeight = QuickFillViewModel.dividerHeight
                       + QuickFillViewModel.listPadding
                       + CGFloat(visibleRows) * QuickFillViewModel.rowHeight
        } else {
            listHeight = 0
        }

        let newHeight = QuickFillViewModel.searchBarHeight + listHeight

        var frame = panel.frame
        frame.size.height = newHeight
        frame.origin.y = topY - newHeight
        panel.setFrame(frame, display: true)
    }

    func close() {
        // If we're tearing down mid-verification (Esc / click-away), tell the
        // device to stop its still-open FP gate so it doesn't keep blinking.
        viewModel?.cancelDeviceGateOnClose()
        cancellable?.cancel()
        cancellable = nil
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        panel?.close()
        panel = nil
        viewModel = nil
        panelTopY = nil
    }
}
