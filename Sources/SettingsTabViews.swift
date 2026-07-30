import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import AppKit

// MARK: - andOTP backup JSON entry
//
// andOTP (https://github.com/andOTP/andOTP) 的 plain-JSON 备份格式. 数组,
// 每元素一条 OTP. 固件只支持 HMAC-SHA1 TOTP / 6 位 / 30 秒, 其他参数 (HOTP /
// STEAM / SHA256 / 7-8 位 / 非 30s period) 一律 skip + 在 import confirm
// dialog 里告知用户多少条被跳过.
fileprivate struct AndOTPEntry: Decodable {
    let secret: String
    let issuer: String?
    let label: String?
    let digits: Int?
    let type: String?
    let algorithm: String?
    let period: Int?
}

// MARK: - AppKit-backed Tooltip
//
// SwiftUI's `.help(_:)` doesn't reliably surface a tooltip on plain Image
// views (no Button wrapper) on macOS 13+. We attach an NSView with
// `toolTip` set via the standard AppKit mechanism, which always works.

private struct TooltipBacking: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.toolTip = text
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = text
    }
}

extension View {
    /// macOS-native tooltip on hover (~1s delay). Works on any view because
    /// it overlays a transparent NSView with `toolTip` set.
    func nsTooltip(_ text: String) -> some View {
        background(TooltipBacking(text: text))
    }
}

private func batteryIconName(level: Int) -> String {
    switch level {
    case 0...10:  return "battery.0percent"
    case 11...35: return "battery.25percent"
    case 36...65: return "battery.50percent"
    case 66...90: return "battery.75percent"
    default:      return "battery.100percent"
    }
}

/// Battery tooltip text. Shows raw voltage when firmware reports it (≥ 1.3.4),
/// useful for cross-checking the displayed percentage against the actual cell
/// voltage during curve calibration.
private func batteryTooltipText(level: Int, mv: Int?) -> String {
    let refresh = "battery.refresh.tooltip".localized
    if let mv = mv, mv > 0 {
        let volts = Double(mv) / 1000.0
        return String(format: "%d%% / %.3fV — %@", level, volts, refresh)
    }
    return "\(level)% — \(refresh)"
}

// MARK: - Device Tab

struct DeviceTabView: View {
    @ObservedObject var viewModel: AppViewModel
    @StateObject private var fpViewModel = FingerprintViewModel()
    @State private var isRefreshingBattery = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Bluetooth Warning (if needed)
                if viewModel.needsBluetoothAttention {
                    bluetoothWarningView
                }

                // Connection Status
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("device.connection.status".localized, systemImage: "antenna.radiowaves.left.and.right")
                            .font(.headline)

                        HStack {
                            Circle()
                                .fill(viewModel.isDeviceConnected ? Color.green : Color.red)
                                .frame(width: 10, height: 10)

                            Text(viewModel.deviceStatusTextWithFirmware)
                                .foregroundColor(.secondary)

                            Spacer()

                            if let level = viewModel.batteryLevel {
                                Button {
                                    guard !isRefreshingBattery else { return }
                                    isRefreshingBattery = true
                                    viewModel.refreshDeviceStatus {
                                        isRefreshingBattery = false
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        if isRefreshingBattery {
                                            ProgressView()
                                                .controlSize(.small)
                                                .scaleEffect(0.6)
                                                .frame(width: 14, height: 14)
                                        } else {
                                            Image(systemName: batteryIconName(level: level))
                                        }
                                        Text("\(level)%")
                                            .font(.callout)
                                    }
                                    .foregroundColor(level <= 10 ? .red : .secondary)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(batteryTooltipText(level: level, mv: viewModel.batteryVoltageMv))
                                .disabled(!viewModel.isDeviceConnected)
                            }
                        }
                    }
                    .padding(4)
                }

                // Fingerprint Management
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        // Header with refresh button
                        HStack {
                            Label("fingerprint.management".localized, systemImage: "touchid")
                                .font(.headline)

                            Spacer()

                            Button(action: {
                                fpViewModel.forceRefresh()
                            }) {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .disabled(!fpViewModel.isDeviceConnected)
                        }

                        Text("fingerprint.count".localized(fpViewModel.fingerprintCount))
                            .font(.callout)
                            .foregroundColor(.secondary)

                        // Fingerprint icons
                        HStack(spacing: 24) {
                            ForEach(fpViewModel.enrolledSlots, id: \.self) { slotIndex in
                                FingerprintIconView(
                                    index: slotIndex,
                                    name: fpViewModel.fingerprintName(for: slotIndex),
                                    onDelete: {
                                        fpViewModel.deleteFingerprint(slot: slotIndex)
                                    },
                                    onRename: { newName in
                                        fpViewModel.setFingerprintName(newName, for: slotIndex)
                                    }
                                )
                            }

                            if fpViewModel.fingerprintCount < 5 {
                                addFingerprintButton
                            }
                        }
                        .padding(.vertical, 4)

                        Divider()

                        // Test button
                        Button(action: {
                            fpViewModel.testFingerprint()
                        }) {
                            HStack {
                                Image(systemName: "checkmark.shield")
                                Text("fingerprint.test".localized)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!fpViewModel.isDeviceConnected || fpViewModel.gateController.isPresented)
                    }
                    .padding(4)
                }

                // Pairing & Unpair
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("pairing.title".localized, systemImage: "lock.shield")
                            .font(.headline)

                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(viewModel.isDevicePaired ? "pairing.status.paired".localized : "pairing.status.unpaired".localized)
                                    .font(.callout)
                                    .foregroundColor(viewModel.isDevicePaired ? .green : .orange)
                                if viewModel.isDeviceConnected && viewModel.isDevicePaired && !viewModel.isDeviceVerified {
                                    Text("device.not.verified".localized)
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                            }

                            Spacer()

                            // Both buttons must stay reachable when device-side and
                            // local pairing state diverge, or the UI dead-ends.
                            //
                            // The bad case: device reports paired but this Mac has no
                            // shared key (device paired elsewhere / local Keychain
                            // cleared). Verification then fails, and with Pair gated
                            // purely on isDevicePaired and Unpair purely on
                            // hasLocalPairing, BOTH were greyed out with no way back.
                            //
                            // Pair is only pointless when the pairing is actually
                            // usable — device-side AND locally present. Firmware still
                            // has final say: PAIR_INIT answers needsReset when
                            // fingerprints are enrolled, which we already surface.
                            Button("pairing.start".localized) {
                                viewModel.startPairing()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!viewModel.isDeviceConnected || viewModel.isPairing
                                      || (viewModel.isDevicePaired && viewModel.hasLocalPairing))

                            // Unpair is meaningful whenever there is state to clear on
                            // either side. (clearLocalPairing also resets
                            // isDevicePaired, so this is the escape hatch.)
                            Button("unpair.confirm".localized) {
                                viewModel.unpair()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!viewModel.hasLocalPairing && !viewModel.isDevicePaired)
                        }

                        if viewModel.isPairing {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.6)
                                Text(viewModel.pairingPrompt ?? "pairing.in.progress".localized)
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                        }

                    }
                    .padding(4)
                }
            }
            .padding(20)
        }
        .onAppear {
            fpViewModel.refresh()
        }
        .sheet(isPresented: $fpViewModel.isEnrolling) {
            EnrollmentSheet(viewModel: fpViewModel)
        }
        .sheet(isPresented: $fpViewModel.gateController.isPresented) {
            FingerprintGateSheet(controller: fpViewModel.gateController)
        }
        .sheet(isPresented: $viewModel.gateController.isPresented) {
            FingerprintGateSheet(controller: viewModel.gateController)
        }
    }

    // MARK: - Add Fingerprint Button

    private var addFingerprintButton: some View {
        VStack(spacing: 8) {
            Button(action: {
                if let slot = fpViewModel.nextAvailableSlot {
                    fpViewModel.enrollFingerprint(slot: slot)
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
            .disabled(!fpViewModel.isDeviceConnected || fpViewModel.isEnrolling || fpViewModel.nextAvailableSlot == nil)

            Text("fingerprint.add".localized)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Bluetooth Warning View

    private var bluetoothWarningView: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(viewModel.bluetoothStatus == .denied ? "bluetooth.denied.title".localized : "bluetooth.off".localized)
                        .font(.headline)
                        .foregroundColor(.orange)
                }

                Text(viewModel.bluetoothStatus == .denied ? "bluetooth.denied.message".localized : "bluetooth.off.message".localized)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: {
                    if viewModel.bluetoothStatus == .denied {
                        viewModel.openBluetoothSettings()
                    } else {
                        viewModel.openBluetoothPreferences()
                    }
                }) {
                    HStack {
                        Image(systemName: "gear")
                        Text("bluetooth.open.settings".localized)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(8)
        }
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Keys Tab

struct KeysTabView: View {
    @ObservedObject var viewModel: AppViewModel
    @StateObject private var keystoreVM = KeystoreViewModel()
    @State private var selectedCategory: KeyCategory = .sshGit
    @State private var showingAddSheet = false
    @State private var copiedNotification: String?
    @State private var isManaging = false
    @State private var selectedEntries: Set<Int> = []
    @State private var hoveredEntry: Int? = nil
    @State private var editingEntry: KeystoreViewModel.Entry? = nil

    private enum KeyCategory: String, CaseIterable {
        case sshGit, api, otp

        var icon: String {
            switch self {
            case .sshGit: return "terminal"
            case .api: return "network"
            case .otp: return "clock.badge"
            }
        }

        var localizedName: String {
            switch self {
            case .sshGit: return "keys.ssh".localized
            case .api: return "keys.api".localized
            case .otp: return "keys.otp".localized
            }
        }

        /// Map to BLE keystore category
        var keystoreCat: KeystoreCategory {
            switch self {
            case .sshGit: return .ssh
            case .api: return .api
            case .otp: return .otp
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // 左侧分类栏
            VStack(spacing: 2) {
                ForEach(KeyCategory.allCases, id: \.self) { category in
                    Button(action: {
                        selectedCategory = category
                        isManaging = false
                        selectedEntries.removeAll()
                        keystoreVM.loadEntries(cat: category.keystoreCat)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: category.icon)
                                .frame(width: 16)
                            Text(category.localizedName)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selectedCategory == category ? Color.accentColor.opacity(0.15) : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(selectedCategory == category ? .accentColor : .primary)
                    .disabled(keystoreVM.isLoading && selectedCategory != category)
                }
                Spacer()
            }
            .frame(width: 130)
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // 右侧内容区
            VStack(spacing: 0) {
                // 表头
                HStack {
                    Text("\(keystoreVM.entries.count)/\(selectedCategory.keystoreCat.maxEntries)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button(isManaging ? "keys.done".localized : "keys.manage".localized) {
                        isManaging.toggle()
                        if !isManaging { selectedEntries.removeAll() }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .disabled(keystoreVM.entries.isEmpty || keystoreVM.isDeleting)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()

                // 条目列表
                ScrollView {
                    VStack(spacing: 0) {
                        keystoreListContent
                    }
                }

                // 底部工具栏
                Divider()
                HStack {
                    if isManaging {
                            Button(selectedEntries.count == keystoreVM.entries.count
                                   ? "keys.deselectAll".localized
                                   : "keys.selectAll".localized) {
                                toggleSelectAll()
                            }
                            .buttonStyle(.borderless)

                            Spacer()

                            if keystoreVM.isDeleting {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .scaleEffect(0.5)
                                    Text("keys.deleting".localized)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                Button("keys.deleteSelected".localized(selectedEntries.count)) {
                                    deleteSelected()
                                }
                                .foregroundColor(.red)
                                .disabled(selectedEntries.isEmpty || keystoreVM.isDeleting)
                            }
                        } else {
                            Button(action: { showingAddSheet = true }) {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.borderless)
                            .disabled(!viewModel.isDeviceConnected || keystoreVM.isAdding || keystoreVM.isAtMaxCapacity)
                            .help(keystoreVM.isAtMaxCapacity ? "keys.full".localized : "")

                            Spacer()

                            if let note = copiedNotification {
                                Text(note)
                                    .font(.caption)
                                    .foregroundColor(.green)
                            } else if !keystoreVM.gateController.isPresented {
                                if let error = keystoreVM.errorMessage {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundColor(.red)
                                } else if keystoreVM.isImporting {
                                    HStack(spacing: 4) {
                                        ProgressView()
                                            .scaleEffect(0.5)
                                        Text("keys.importing.progress".localized(keystoreVM.importProgress, keystoreVM.importTotal))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .monospacedDigit()
                                    }
                                } else if keystoreVM.isExporting {
                                    HStack(spacing: 4) {
                                        ProgressView()
                                            .scaleEffect(0.5)
                                        Text("keys.exporting".localized)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                } else if keystoreVM.isAdding {
                                    HStack(spacing: 4) {
                                        ProgressView()
                                            .scaleEffect(0.5)
                                        Text("keys.adding".localized)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                } else if keystoreVM.isDeleting {
                                    HStack(spacing: 4) {
                                        ProgressView()
                                            .scaleEffect(0.5)
                                        Text("keys.deleting".localized)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }

                            if selectedCategory == .sshGit {
                                Button(action: { generateSSHKey() }) {
                                    HStack(spacing: 2) {
                                        Image(systemName: "wand.and.stars")
                                        Text("ssh.generate".localized)
                                    }
                                }
                                .buttonStyle(.borderless)
                                .disabled(!viewModel.isDeviceConnected || keystoreVM.isAdding || keystoreVM.isAtMaxCapacity)
                                .help(keystoreVM.isAtMaxCapacity ? "keys.full".localized : "")

                                Button(action: { importSSHKey() }) {
                                    HStack(spacing: 2) {
                                        Image(systemName: "square.and.arrow.down")
                                        Text("ssh.import".localized)
                                    }
                                }
                                .buttonStyle(.borderless)
                                .disabled(!viewModel.isDeviceConnected || keystoreVM.isAdding || keystoreVM.isAtMaxCapacity)
                                .help(keystoreVM.isAtMaxCapacity ? "keys.full".localized : "")
                            }

                            if selectedCategory == .otp {
                                Button(action: { importOTP() }) {
                                    HStack(spacing: 2) {
                                        Image(systemName: "square.and.arrow.down")
                                        Text("keys.import".localized)
                                    }
                                }
                                .buttonStyle(.borderless)
                                .disabled(!viewModel.isDeviceConnected || keystoreVM.isImporting || keystoreVM.isAtMaxCapacity)
                                .help(keystoreVM.isAtMaxCapacity ? "keys.full".localized : "")

                                Button(action: { exportOTP() }) {
                                    HStack(spacing: 2) {
                                        Image(systemName: "square.and.arrow.up")
                                        Text("keys.export".localized)
                                    }
                                }
                                .buttonStyle(.borderless)
                                .disabled(!viewModel.isDeviceConnected || keystoreVM.isExporting || keystoreVM.entries.isEmpty)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddKeyEntrySheet(category: selectedCategory.keystoreCat, keystoreVM: keystoreVM, isPresented: $showingAddSheet)
        }
        .sheet(item: $editingEntry) { entry in
            let cat = selectedCategory.keystoreCat
            EditKeyEntrySheet(entry: entry, category: cat) { name, service in
                keystoreVM.updateEntry(cat: cat, idx: UInt8(entry.index),
                                       name: name, service: service) { _ in }
                editingEntry = nil
            } onCancel: {
                editingEntry = nil
            }
        }
        .sheet(isPresented: $keystoreVM.gateController.isPresented) {
            FingerprintGateSheet(controller: keystoreVM.gateController)
        }
        .overlay {
            if keystoreVM.isImporting {
                BatchProgressOverlay(
                    icon: "square.and.arrow.down",
                    text: "keys.importing.progress".localized(keystoreVM.importProgress, keystoreVM.importTotal),
                    progress: keystoreVM.importTotal > 0
                        ? Double(keystoreVM.importProgress) / Double(keystoreVM.importTotal)
                        : 0
                )
            } else if keystoreVM.isDeleting && keystoreVM.deleteTotal > 0 {
                BatchProgressOverlay(
                    icon: "trash",
                    text: "keys.deleting.progress".localized(keystoreVM.deleteProgress, keystoreVM.deleteTotal),
                    progress: keystoreVM.deleteTotal > 0
                        ? Double(keystoreVM.deleteProgress) / Double(keystoreVM.deleteTotal)
                        : 0
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sshKeyCacheSynced)) { _ in
            if selectedCategory == .sshGit {
                let vm = keystoreVM
                vm.loadFromSSHKeyCache()
            }
        }
        .onAppear {
            // First entry into the Keys tab: the default category (SSH) is
            // highlighted but nothing ever called loadEntries — the list
            // stayed blank until the user clicked a category button.
            // Digest-cached, so re-appearing is a 6-byte round-trip at most.
            keystoreVM.loadEntries(cat: selectedCategory.keystoreCat)
        }
    }

    // MARK: - Keystore List Content

    private var keystoreListContent: some View {
        Group {
            if keystoreVM.isLoading && keystoreVM.entries.isEmpty {
                VStack {
                    Spacer()
                    ProgressView()
                    if keystoreVM.loadingTotal > 0 {
                        Text("keys.loading.progress".localized(keystoreVM.loadingProgress, keystoreVM.loadingTotal))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .padding(.top, 4)
                    } else {
                        Text("keys.loading".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else if !keystoreVM.isLoading && keystoreVM.entries.isEmpty {
                VStack {
                    Spacer()
                    Text("keys.empty".localized)
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ForEach(keystoreVM.entries) { entry in
                    keystoreRow(entry: entry)
                    Divider()
                }
            }
        }
    }

    private func keystoreRow(entry: KeystoreViewModel.Entry) -> some View {
        HStack {
            if isManaging {
                Image(systemName: selectedEntries.contains(entry.index) ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selectedEntries.contains(entry.index) ? .accentColor : .secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name.isEmpty ? "(\(entry.index))" : entry.name)
                    .lineLimit(1)

                // Show fingerprint for SSH keys
                if selectedCategory == .sshGit {
                    if let cacheEntry = SSHKeyCache.shared.entries.first(where: { $0.index == entry.index }) {
                        Text(cacheEntry.fingerprint)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                // Show service name for OTP keys
                if selectedCategory == .otp, !entry.service.isEmpty {
                    Text(entry.service)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Edit button (hidden in manage mode, shown on hover)
            if !isManaging && hoveredEntry == entry.index {
                Button(action: { editingEntry = entry }) {
                    Image(systemName: "pencil")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("keys.edit".localized)
            }

            // Copy public key button (SSH only, hidden in manage mode)
            if !isManaging && selectedCategory == .sshGit {
                Button(action: { copyPublicKey(entry: entry) }) {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("ssh.copy.pubkey".localized)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { isHovered in
            hoveredEntry = isHovered ? entry.index : nil
        }
        .onTapGesture {
            if isManaging { toggleSelection(entry.index) }
        }
    }

    // MARK: - Manage Mode Helpers

    private func toggleSelection(_ index: Int) {
        if selectedEntries.contains(index) {
            selectedEntries.remove(index)
        } else {
            selectedEntries.insert(index)
        }
    }

    private func toggleSelectAll() {
        if selectedEntries.count == keystoreVM.entries.count {
            selectedEntries.removeAll()
        } else {
            selectedEntries = Set(keystoreVM.entries.map { $0.index })
        }
    }

    private func deleteSelected() {
        let cat = selectedCategory.keystoreCat
        let indices = selectedEntries.map { UInt8($0) }
        keystoreVM.deleteEntries(cat: cat, indices: indices) {
            Task { @MainActor in
                selectedEntries.removeAll()
                isManaging = false
            }
        }
    }

    // MARK: - SSH Specific

    private func copyPublicKey(entry: KeystoreViewModel.Entry) {
        guard let cacheEntry = SSHKeyCache.shared.entries.first(where: { $0.index == entry.index }) else { return }
        let pubKeyStr = SSHKeyCache.formatOpenSSHPublicKey(blob: cacheEntry.publicKeyBlob, comment: cacheEntry.name)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pubKeyStr, forType: .string)
        showCopiedNotification("ssh.copied".localized)
    }

    private func importSSHKey() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择 SSH ECDSA P-256 私钥文件（OpenSSH 或 PEM 格式）"
        // Allow any file — SSH keys often have no extension
        panel.allowedContentTypes = []
        panel.showsHiddenFiles = true  // ~/.ssh is hidden by default
        guard panel.runModalOverSettings() == .OK, let url = panel.url else { return }

        let imported: SSHKeyImporter.ImportedKey
        do {
            imported = try SSHKeyImporter.parse(fileURL: url)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "ssh.import.failed".localized
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModalOverSettings()
            return
        }

        // Prompt for a name (default to filename without extension)
        let alert = NSAlert()
        alert.messageText = "ssh.import".localized
        alert.informativeText = "fingerprint: \(imported.openSSHFingerprint)\n\n请输入名称（最长 16 字节）："
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "alert.cancel".localized)
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.placeholderString = "imported-key"
        input.stringValue = url.deletingPathExtension().lastPathComponent
        alert.accessoryView = input
        guard alert.runModalOverSettings() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        // 16-byte UTF-8 cap (firmware SSH name field)
        guard name.utf8.count <= 16 else {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "ssh.import.failed".localized
            a.informativeText = "名称超过 16 字节（当前 \(name.utf8.count) 字节）"
            a.addButton(withTitle: "OK")
            a.runModalOverSettings()
            return
        }

        keystoreVM.gateController.successMessage = "ssh.generate.success".localized
        keystoreVM.importSSHKey(name: name, imported: imported) { success in
            if success {
                showCopiedNotification("ssh.import.success".localized)
            }
        }
    }

    private func generateSSHKey() {
        // Prompt for key name
        let alert = NSAlert()
        alert.messageText = "ssh.generate".localized
        alert.informativeText = "keys.name".localized
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "alert.cancel".localized)

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.placeholderString = "my-key"
        alert.accessoryView = input

        let response = alert.runModalOverSettings()
        guard response == .alertFirstButtonReturn else { return }

        let name = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        // KEY_GENERATE already has its own FP gate — no need for separate requestAuth()
        let vm = keystoreVM
        vm.isAdding = true
        vm.gateController.successMessage = "ssh.generate.success".localized
        BLEManager.shared.sshGenerateKey(name: name) { result in
            DispatchQueue.main.async {
                vm.isAdding = false
                if let result = result {
                    NSLog("SSH key generated: idx=%d", result.idx)
                    let blob = SSHKeyCache.buildSSHPublicKeyBlob(publicKey: result.publicKey)
                    let fp = SSHKeyCache.computeFingerprint(blob: blob)
                    SSHKeyCache.shared.addEntry(SSHKeyCacheEntry(
                        index: result.idx, name: name, publicKeyBlob: blob, fingerprint: fp
                    ))
                    vm.loadEntries(cat: .ssh)
                    vm.gateController.reportSuccess()
                } else {
                    NSLog("SSH key generation failed or timed out")
                    vm.gateController.reportFailed()
                }
            }
        }
    }

    private func showCopiedNotification(_ text: String) {
        copiedNotification = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            copiedNotification = nil
        }
    }

    // MARK: - OTP Import/Export

    private func exportOTP() {
        keystoreVM.readAllOTPEntries { entries in
            DispatchQueue.main.async {
                guard !entries.isEmpty else { return }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [UTType.commaSeparatedText]
                panel.nameFieldStringValue = "otp_export.csv"
                guard panel.runModalOverSettings() == .OK, let url = panel.url else { return }

                var csv = "name,url\n"
                for e in entries {
                    let b32 = base32Encode(e.secret)
                    let service = e.service.isEmpty ? e.name : e.service
                    let uri = "otpauth://totp/\(urlEncode(service)):\(urlEncode(e.name))?secret=\(b32)&issuer=\(urlEncode(service))"
                    csv += "\(csvEscape(e.name)),\(csvEscape(uri))\n"
                }
                try? csv.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private func importOTP() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.commaSeparatedText, UTType.json]
        panel.allowsMultipleSelection = false
        guard panel.runModalOverSettings() == .OK, let url = panel.url else { return }

        let isJSON = url.pathExtension.lowercased() == "json"

        var parsed: [(name: String, service: String, secret: Data)] = []
        var skippedCount = 0

        if isJSON {
            guard let data = try? Data(contentsOf: url) else { return }
            guard let entries = try? JSONDecoder().decode([AndOTPEntry].self, from: data) else {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "keys.import.failed".localized
                alert.informativeText = "keys.import.unknown.format".localized
                alert.addButton(withTitle: "OK")
                alert.runModalOverSettings()
                return
            }
            for entry in entries {
                // 固件仅支持标准 TOTP / HMAC-SHA1 / 6 位 / 30 秒, 其他 skip.
                let type = (entry.type ?? "TOTP").uppercased()
                let algo = (entry.algorithm ?? "SHA1").uppercased()
                guard type == "TOTP",
                      algo == "SHA1",
                      (entry.digits ?? 6) == 6,
                      (entry.period ?? 30) == 30 else {
                    skippedCount += 1
                    continue
                }
                // andOTP secret 有时带 base32 padding "=", 去掉再解码.
                let cleaned = entry.secret.replacingOccurrences(of: "=", with: "")
                guard let secretData = base32Decode(cleaned), !secretData.isEmpty else {
                    skippedCount += 1
                    continue
                }
                let label = (entry.label ?? "").trimmingCharacters(in: .whitespaces)
                let issuer = (entry.issuer ?? "").trimmingCharacters(in: .whitespaces)
                let name: String
                let service: String
                if !issuer.isEmpty {
                    service = issuer
                    name = label
                } else if let colonIdx = label.firstIndex(of: ":") {
                    // 没 issuer 时尝试从 label "Service:Account" 拆分,
                    // 跟 otpauth://path 的语义一致.
                    service = String(label[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                    name = String(label[label.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                } else {
                    service = ""
                    name = label
                }
                parsed.append((name: name, service: service, secret: secretData))
            }
        } else {
            // CSV with otpauth:// URI per line (existing format)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
            let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
            let startIndex = lines.first?.lowercased().starts(with: "name") == true ? 1 : 0

            for line in lines[startIndex...] {
                guard let range = line.range(of: "otpauth://") else { continue }
                let uri = String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
                guard let components = URLComponents(string: uri),
                      let secret = components.queryItems?.first(where: { $0.name == "secret" })?.value,
                      let secretData = base32Decode(secret) else { continue }

                let issuer = components.queryItems?.first(where: { $0.name == "issuer" })?.value ?? ""
                let path = (components.path as NSString).lastPathComponent
                let parts = path.split(separator: ":", maxSplits: 1)
                let name: String
                let service: String
                if parts.count == 2 {
                    service = issuer.isEmpty ? String(parts[0]).removingPercentEncoding ?? String(parts[0]) : issuer
                    name = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                } else {
                    name = path.removingPercentEncoding ?? path
                    service = issuer
                }

                parsed.append((name: name, service: service, secret: secretData))
            }
        }

        guard !parsed.isEmpty else {
            if skippedCount > 0 {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "keys.import.failed".localized
                alert.informativeText = "keys.import.all.skipped".localized(skippedCount)
                alert.addButton(withTitle: "OK")
                alert.runModalOverSettings()
            }
            return
        }

        // Pre-check: would this exceed the firmware cap (KEYSTORE_OTP_MAX = 128)?
        // Without this, writes past the cap silently fail (commit returns -1)
        // but the App still walks through "import" UI showing apparent success.
        let remaining = keystoreVM.remainingCapacity
        if parsed.count > remaining {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "keys.import.exceeds.title".localized
            alert.informativeText = "keys.import.exceeds.message".localized(parsed.count, remaining, KeystoreCategory.otp.maxEntries)
            alert.addButton(withTitle: "OK")
            alert.runModalOverSettings()
            return
        }

        let alert = NSAlert()
        alert.messageText = "keys.import.confirm".localized
        var info = "keys.import.count".localized(parsed.count)
        if skippedCount > 0 {
            info += " " + "keys.import.skipped".localized(skippedCount)
        }
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "alert.cancel".localized)
        guard alert.runModalOverSettings() == .alertFirstButtonReturn else { return }

        keystoreVM.importOTPEntries(parsed) { count in
            DispatchQueue.main.async {
                showCopiedNotification("keys.import.done".localized(count))
            }
        }
    }

    private func base32Encode(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0
        var value: UInt32 = 0
        var result = ""
        for byte in data {
            value = (value << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                result.append(alphabet[Int((value >> bits) & 0x1F)])
            }
        }
        if bits > 0 {
            result.append(alphabet[Int((value << (5 - bits)) & 0x1F)])
        }
        return result
    }

    private func base32Decode(_ input: String) -> Data? {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        let cleaned = input.uppercased().filter { $0 != "=" && $0 != " " }
        guard !cleaned.isEmpty else { return nil }

        var bits = 0
        var value: UInt32 = 0
        var data = Data()

        for char in cleaned {
            guard let idx = alphabet.firstIndex(of: char) else { return nil }
            value = (value << 5) | UInt32(alphabet.distance(from: alphabet.startIndex, to: idx))
            bits += 5
            if bits >= 8 {
                bits -= 8
                data.append(UInt8((value >> bits) & 0xFF))
            }
        }
        return data
    }

    private func urlEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    private func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}

// MARK: - Batch Progress Overlay

struct BatchProgressOverlay: View {
    let icon: String
    let text: String
    let progress: Double

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)

                Text(text)
                    .font(.headline)
                    .monospacedDigit()

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * min(progress, 1.0), height: 4)
                            .animation(.linear(duration: 0.3), value: progress)
                    }
                }
                .frame(height: 4)
            }
            .frame(width: 220)
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.windowBackgroundColor))
                    .shadow(radius: 10)
            )
        }
    }
}

// MARK: - Add Key Entry Sheet

struct AddKeyEntrySheet: View {
    let category: KeystoreCategory
    @ObservedObject var keystoreVM: KeystoreViewModel
    @Binding var isPresented: Bool

    @State private var name = ""
    @State private var keyField = ""
    @State private var serviceField = ""
    @State private var validationError: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("keys.add".localized)
                .font(.headline)

            // Name field (SSH: 16B, OTP: 30B, API: 32B UTF-8)
            HStack {
                let maxNameBytes = category == .ssh ? 16 : category == .otp ? 30 : 32
                Text("keys.add.name".localized)
                    .frame(width: 60, alignment: .trailing)
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _ in truncateUtf8(&name, maxBytes: maxNameBytes) }
                Text("\(maxNameBytes - Data(name.utf8).count)")
                    .font(.caption)
                    .foregroundColor(Data(name.utf8).count > maxNameBytes - 2 ? .orange : .secondary)
                    .frame(width: 20)
            }

            // Category-specific fields
            switch category {
            case .ssh:
                HStack(alignment: .top) {
                    Text("keys.add.key".localized)
                        .frame(width: 60, alignment: .trailing)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        TextEditor(text: $keyField)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 120)
                            .border(Color.secondary.opacity(0.3))
                        if let hint = sshKeyHint {
                            Text(hint)
                                .font(.caption)
                                .foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("-----BEGIN OPENSSH PRIVATE KEY----- (P-256)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

            case .otp:
                HStack {
                    Text("keys.add.service".localized)
                        .frame(width: 60, alignment: .trailing)
                    TextField("", text: $serviceField)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: serviceField) { _ in truncateUtf8(&serviceField, maxBytes: 30) }
                    Text("\(30 - Data(serviceField.utf8).count)")
                        .font(.caption)
                        .foregroundColor(Data(serviceField.utf8).count > 28 ? .orange : .secondary)
                        .frame(width: 20)
                }
                HStack {
                    Text("keys.add.secret".localized)
                        .frame(width: 60, alignment: .trailing)
                    TextField("Base32", text: $keyField)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: keyField) { _ in limitBase32Input(&keyField, maxBytes: 32) }
                    Text("\(base32DecodedCount(keyField))/32")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 36)
                }

            case .api:
                HStack(alignment: .top) {
                    Text("keys.add.key".localized)
                        .frame(width: 60, alignment: .trailing)
                        .padding(.top, 4)
                    VStack(alignment: .trailing, spacing: 2) {
                        TextEditor(text: $keyField)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 80)
                            .border(Color.secondary.opacity(0.3))
                            .onChange(of: keyField) { _ in truncateUtf8(&keyField, maxBytes: 128) }
                        Text("\(128 - Data(keyField.utf8).count)")
                            .font(.caption)
                            .foregroundColor(Data(keyField.utf8).count > 120 ? .orange : .secondary)
                    }
                }
            }

            if let error = validationError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Button("alert.cancel".localized) {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("keys.add".localized) {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || keyField.isEmpty || keystoreVM.isAdding || !isInputValid)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - Validation

    private var isInputValid: Bool {
        switch category {
        case .ssh:
            if case .success = parseOpenSSHPrivateKey(keyField) { return true }
            return false
        case .otp:
            let decoded = base32DecodedCount(keyField)
            return decoded > 0 && decoded <= 32
        case .api:
            let count = Data(keyField.utf8).count
            return count > 0 && count <= 128
        }
    }

    /// Strip optional "0x"/"0X" prefix, then count hex digits
    private func stripHexPrefix(_ hex: String) -> String {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            s = String(s.dropFirst(2))
        }
        return s.filter { $0.isHexDigit }
    }

    private func hexByteCount(_ hex: String) -> Int {
        return stripHexPrefix(hex).count / 2
    }

    private func base32DecodedCount(_ input: String) -> Int {
        let cleaned = input.uppercased().filter { $0 != "=" && $0 != " " }
        return (cleaned.count * 5) / 8
    }

    // MARK: - Input Limiters

    private func truncateUtf8(_ text: inout String, maxBytes: Int) {
        while Data(text.utf8).count > maxBytes {
            text.removeLast()
        }
    }

    private func limitHexInput(_ text: inout String, maxBytes: Int) {
        // Allow hex chars, spaces, and "0x"/"0X" prefix
        text = String(text.filter { $0.isHexDigit || $0 == " " || $0 == "x" || $0 == "X" })
        let cleaned = stripHexPrefix(text)
        if cleaned.count > maxBytes * 2 {
            // Keep prefix if present, then limit hex digits
            let hasPrefix = text.trimmingCharacters(in: .whitespaces).hasPrefix("0x")
                         || text.trimmingCharacters(in: .whitespaces).hasPrefix("0X")
            var result = ""
            var hexCount = 0
            var skippedPrefix = !hasPrefix
            for ch in text {
                if !skippedPrefix && (ch == "0" || ch == "x" || ch == "X") {
                    result.append(ch)
                    if ch == "x" || ch == "X" { skippedPrefix = true }
                    continue
                }
                if ch.isHexDigit {
                    if hexCount >= maxBytes * 2 { break }
                    hexCount += 1
                }
                result.append(ch)
            }
            text = result
        }
    }

    private func limitBase32Input(_ text: inout String, maxBytes: Int) {
        let validChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz234567= "
        text = String(text.filter { validChars.contains($0) })
        // 32 bytes = 52 base32 chars (ceil(32 * 8 / 5))
        let maxChars = (maxBytes * 8 + 4) / 5
        let cleaned = text.filter { $0 != "=" && $0 != " " }
        if cleaned.count > maxChars {
            var result = ""
            var b32Count = 0
            for ch in text {
                if ch != "=" && ch != " " {
                    if b32Count >= maxChars { break }
                    b32Count += 1
                }
                result.append(ch)
            }
            text = result
        }
    }

    // MARK: - Submit

    private func submit() {
        guard let entryData = buildEntryData() else {
            validationError = "keys.add.invalid".localized
            return
        }
        // Capture parsed SSH pubkey before dismissing (keyField will be gone)
        let sshParsed: (privateKey: Data, publicKey: Data)?
        if category == .ssh, case .success(let p) = parseOpenSSHPrivateKey(keyField) {
            sshParsed = p
        } else {
            sshParsed = nil
        }
        let entryName = name
        validationError = nil

        isPresented = false
        keystoreVM.addEntry(cat: category, data: entryData) { success in
            if success, let parsed = sshParsed {
                let blob = SSHKeyCache.buildSSHPublicKeyBlob(publicKey: parsed.publicKey)
                let fp = SSHKeyCache.computeFingerprint(blob: blob)
                // Index will be assigned by device; loadEntries triggers full sync
                // but also add to cache now so it shows immediately
                let idx = keystoreVM.entries.count  // approximate next index
                SSHKeyCache.shared.addEntry(SSHKeyCacheEntry(
                    index: idx, name: entryName, publicKeyBlob: blob, fingerprint: fp
                ))
            }
        }
    }

    private func buildEntryData() -> Data? {
        switch category {
        case .ssh:
            // SSH: name(16B) + pubkey_LE(64B) + privkey_LE(32B) = 112B
            let nameData = KeystoreViewModel.buildField(name, size: 16)
            guard case .success(let parsed) = parseOpenSSHPrivateKey(keyField) else { return nil }
            let pubkeyLE = BLEManager.shared.convertEndianness64(parsed.publicKey)
            let privkeyLE = Data(parsed.privateKey.reversed())
            return nameData + pubkeyLE + privkeyLE

        case .otp:
            // OTP: name(30B) + service(30B) + secret(32B) = 92B
            let nameData = KeystoreViewModel.buildField(name, size: 30)
            let serviceData = KeystoreViewModel.buildField(serviceField, size: 30)
            guard let secretBytes = base32Decode(keyField),
                  secretBytes.count > 0, secretBytes.count <= 32 else { return nil }
            var secret = Data(count: 32)
            secret.replaceSubrange(0..<secretBytes.count, with: secretBytes)
            return nameData + serviceData + secret

        case .api:
            // API: name(32B) + key(128B) = 160B
            let nameData = KeystoreViewModel.buildField(name, size: 32)
            let keyUtf8 = Data(keyField.utf8)
            guard keyUtf8.count > 0, keyUtf8.count <= 128 else { return nil }
            var keyData = Data(count: 128)
            keyData.replaceSubrange(0..<keyUtf8.count, with: keyUtf8)
            return nameData + keyData
        }
    }

    // MARK: - OpenSSH PEM Parser

    private enum SSHKeyError: Error, Equatable {
        case invalidFormat
        case encrypted
        case unsupportedType(String)  // e.g. "ssh-ed25519", "ssh-rsa"
        case corrupted
    }

    /// Parse an OpenSSH private key (PEM) for ecdsa-sha2-nistp256.
    /// Returns .success(privateKey: 32B BE, publicKey: 64B BE) or .failure with reason.
    private func parseOpenSSHPrivateKey(_ pem: String)
        -> Result<(privateKey: Data, publicKey: Data), SSHKeyError>
    {
        // Strip PEM header/footer and decode base64
        let lines = pem.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        guard let decoded = Data(base64Encoded: lines.joined()) else {
            return .failure(.invalidFormat)
        }

        var offset = 0

        func remaining() -> Int { decoded.count - offset }

        func readBytes(_ n: Int) -> Data? {
            guard remaining() >= n else { return nil }
            let d = decoded[offset..<(offset + n)]
            offset += n
            return Data(d)
        }

        func readUInt32() -> UInt32? {
            guard let b = readBytes(4) else { return nil }
            return b.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        }

        func readString() -> Data? {
            guard let len = readUInt32() else { return nil }
            return readBytes(Int(len))
        }

        func readStringAsUTF8() -> String? {
            guard let d = readString() else { return nil }
            return String(data: d, encoding: .utf8)
        }

        // 1. Magic: "openssh-key-v1\0" (15 bytes)
        let magic = "openssh-key-v1\0"
        guard let magicData = readBytes(magic.utf8.count),
              String(data: magicData, encoding: .utf8) == magic else {
            return .failure(.invalidFormat)
        }

        // 2. cipher name — must be "none" (unencrypted)
        guard let cipher = readStringAsUTF8() else { return .failure(.corrupted) }
        if cipher != "none" { return .failure(.encrypted) }

        // 3. kdf name — must be "none"
        guard let kdf = readStringAsUTF8() else { return .failure(.corrupted) }
        if kdf != "none" { return .failure(.encrypted) }

        // 4. kdf options (empty string for "none")
        guard readString() != nil else { return .failure(.corrupted) }

        // 5. number of keys
        guard let numKeys = readUInt32(), numKeys == 1 else { return .failure(.corrupted) }

        // 6. public key blob — read to detect key type for error message
        guard let pubBlob = readString() else { return .failure(.corrupted) }

        // 7. private section (encrypted/unencrypted blob)
        guard let privSection = readString() else { return .failure(.corrupted) }

        // Detect key type from public key blob for better error messages
        var tOff = 0
        func tReadString() -> Data? {
            guard pubBlob.count - tOff >= 4 else { return nil }
            let len = pubBlob[tOff..<(tOff+4)].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            guard pubBlob.count - tOff >= 4 + Int(len) else { return nil }
            let d = pubBlob[(tOff+4)..<(tOff+4+Int(len))]
            tOff += 4 + Int(len)
            return Data(d)
        }
        let detectedType = tReadString().flatMap { String(data: $0, encoding: .utf8) }

        // Parse private section
        var pOff = 0
        func pRemaining() -> Int { privSection.count - pOff }

        func pReadBytes(_ n: Int) -> Data? {
            guard pRemaining() >= n else { return nil }
            let d = privSection[pOff..<(pOff + n)]
            pOff += n
            return Data(d)
        }

        func pReadUInt32() -> UInt32? {
            guard let b = pReadBytes(4) else { return nil }
            return b.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        }

        func pReadString() -> Data? {
            guard let len = pReadUInt32() else { return nil }
            return pReadBytes(Int(len))
        }

        func pReadStringAsUTF8() -> String? {
            guard let d = pReadString() else { return nil }
            return String(data: d, encoding: .utf8)
        }

        // check1, check2 — must be equal
        guard let check1 = pReadUInt32(), let check2 = pReadUInt32(),
              check1 == check2 else { return .failure(.corrupted) }

        // key type
        guard let keyType = pReadStringAsUTF8() else { return .failure(.corrupted) }
        if keyType != "ecdsa-sha2-nistp256" {
            return .failure(.unsupportedType(detectedType ?? keyType))
        }

        // curve name
        guard pReadStringAsUTF8() == "nistp256" else {
            return .failure(.unsupportedType("ecdsa (non-P256)"))
        }

        // public key point: 0x04 || x(32) || y(32) = 65 bytes
        guard let pubPoint = pReadString(),
              pubPoint.count == 65,
              pubPoint[pubPoint.startIndex] == 0x04 else { return .failure(.corrupted) }
        let publicKey = pubPoint[pubPoint.startIndex + 1 ..< pubPoint.startIndex + 65]

        // private key scalar: 32 bytes (may have leading 0x00 padding to 33 bytes)
        guard let privKeyRaw = pReadString() else { return .failure(.corrupted) }
        let privKey: Data
        if privKeyRaw.count == 33 && privKeyRaw[privKeyRaw.startIndex] == 0x00 {
            privKey = Data(privKeyRaw[privKeyRaw.startIndex + 1 ..< privKeyRaw.startIndex + 33])
        } else if privKeyRaw.count == 32 {
            privKey = privKeyRaw
        } else {
            return .failure(.corrupted)
        }

        return .success((privateKey: privKey, publicKey: Data(publicKey)))
    }

    /// Human-readable SSH key validation hint (nil = valid or empty)
    private var sshKeyHint: String? {
        let trimmed = keyField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch parseOpenSSHPrivateKey(keyField) {
        case .success:
            return nil
        case .failure(.invalidFormat):
            return "OpenSSH 格式无效。请粘贴完整私钥（包含 BEGIN/END 行）"
        case .failure(.encrypted):
            return "不支持加密私钥。生成时请勿设置 passphrase，或用:\nssh-keygen -p -N '' -f ~/.ssh/id_ecdsa"
        case .failure(.unsupportedType(let t)):
            return "不支持 \(t)，仅支持 P-256。请用:\nssh-keygen -t ecdsa -b 256"
        case .failure(.corrupted):
            return "私钥数据损坏，无法解析"
        }
    }

    private func hexToData(_ hex: String) -> Data? {
        let cleaned = stripHexPrefix(hex)
        guard cleaned.count % 2 == 0 else { return nil }

        var data = Data()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
    }

    private func base32Decode(_ input: String) -> Data? {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        let cleaned = input.uppercased().filter { $0 != "=" && $0 != " " }
        guard !cleaned.isEmpty else { return nil }

        var bits = 0
        var value: UInt32 = 0
        var data = Data()

        for char in cleaned {
            guard let idx = alphabet.firstIndex(of: char) else { return nil }
            value = (value << 5) | UInt32(alphabet.distance(from: alphabet.startIndex, to: idx))
            bits += 5
            if bits >= 8 {
                bits -= 8
                data.append(UInt8((value >> bits) & 0xFF))
            }
        }
        return data
    }
}

// MARK: - Edit Key Entry Sheet

struct EditKeyEntrySheet: View {
    let entry: KeystoreViewModel.Entry
    let category: KeystoreCategory
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var service: String

    init(entry: KeystoreViewModel.Entry, category: KeystoreCategory,
         onSave: @escaping (String, String) -> Void, onCancel: @escaping () -> Void) {
        self.entry = entry
        self.category = category
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: entry.name)
        _service = State(initialValue: entry.service)
    }

    private var maxNameBytes: Int { category == .ssh ? 16 : category == .otp ? 30 : 32 }

    var body: some View {
        VStack(spacing: 16) {
            Text("keys.edit".localized)
                .font(.headline)

            HStack {
                Text("keys.add.name".localized)
                    .frame(width: 60, alignment: .trailing)
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _ in truncateUtf8(&name, maxBytes: maxNameBytes) }
                Text("\(maxNameBytes - Data(name.utf8).count)")
                    .font(.caption)
                    .foregroundColor(Data(name.utf8).count > maxNameBytes - 2 ? .orange : .secondary)
                    .frame(width: 20)
            }

            if category == .otp {
                HStack {
                    Text("keys.add.service".localized)
                        .frame(width: 60, alignment: .trailing)
                    TextField("", text: $service)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: service) { _ in truncateUtf8(&service, maxBytes: 30) }
                    Text("\(30 - Data(service.utf8).count)")
                        .font(.caption)
                        .foregroundColor(Data(service.utf8).count > 28 ? .orange : .secondary)
                        .frame(width: 20)
                }
            }

            HStack {
                Button("keys.cancel".localized) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("keys.save".localized) {
                    onSave(name.trimmingCharacters(in: .whitespaces),
                           service.trimmingCharacters(in: .whitespaces))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func truncateUtf8(_ text: inout String, maxBytes: Int) {
        while Data(text.utf8).count > maxBytes {
            text.removeLast()
        }
    }
}

// MARK: - Permissions Tab

struct PermissionsTabView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var setupManager: SetupManager

    // Feature toggles stored in UserDefaults
    @AppStorage("immurok.screenUnlockEnabled") private var screenUnlockEnabled = true
    @AppStorage("immurok.screenLockEnabled") private var screenLockEnabled = false
    @AppStorage("immurok.sudoAuthEnabled") private var sudoAuthEnabled = false
    @AppStorage("immurok.authorizationEnabled") private var authorizationEnabled = false
    @AppStorage("immurok.sshAgentEnabled") private var sshAgentEnabled = true
    @AppStorage("immurok.cliEnabled") private var cliEnabled = true
    @AppStorage("immurok.quickFillEnabled") private var quickFillEnabled = true
    @AppStorage("immurok.appStoreFillEnabled") private var appStoreFillEnabled = false
    @AppStorage("immurok.passwordsFillEnabled") private var passwordsFillEnabled = true
    @AppStorage("immurok.onePasswordUnlockEnabled") private var onePasswordUnlockEnabled = false
    @AppStorage("immurok.bitwardenUnlockEnabled") private var bitwardenUnlockEnabled = false
    // Empty string = silent. Read by AppDelegate.handleFingerprintMatch.
    @AppStorage("immurok.unlockSound") private var unlockSound = "Glass"
    // 长按锁屏确认音。Empty string = silent. Read by AppDelegate.handleLockRequest.
    @AppStorage("immurok.lockSound") private var lockSound = "Bottle"

    // macOS built-in system sounds (/System/Library/Sounds/*.aiff)
    private static let systemSounds = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]

    var body: some View {
        ScrollView {
        VStack(spacing: 16) {
            // ===== 系统 =====
            sectionLabel("permission.section.system")

            // 屏幕锁定（长按 ~2s）
            GroupBox {
                permissionRow(
                    icon: "lock",
                    titleKey: "permission.screen.lock",
                    hintKey: "permission.screen.lock.hint",
                    trailing: {
                        if screenLockEnabled {
                            soundPicker(selection: $lockSound,
                                        tipKey: "permission.screen.lock.sound.tip")
                        }
                    },
                    isOn: $screenLockEnabled
                )
            }

            // 界面认证授权（系统设置等）
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    permissionRow(
                        icon: "macwindow.badge.plus",
                        titleKey: "permission.authorization",
                        hintKey: "permission.authorization.hint",
                        isOn: Binding(
                            get: { authorizationEnabled },
                            set: { tryEnableSystemAuth($0) }
                        )
                    )
                    if setupManager.needsAuthorizationRepair {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("notify.authrepair.title".localized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("permission.authorization.repair".localized) {
                                repairAuthorizationAction()
                            }
                        }
                    }
                }
            }

            // ===== 密码自动填充 =====
            sectionLabel("permission.section.autofill")

            // 屏幕解锁
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    permissionRow(
                        icon: "lock.open",
                        titleKey: "permission.screen.unlock",
                        trailing: {
                            if screenUnlockEnabled {
                                soundPicker(selection: $unlockSound,
                                            tipKey: "permission.screen.unlock.sound.tip")
                            }
                        },
                        isOn: Binding(
                            get: { screenUnlockEnabled },
                            set: { tryEnableScreenUnlock($0) }
                        )
                    )
                    if screenUnlockEnabled && !viewModel.isPasswordConfigured {
                        loginPasswordMissingRow
                    }
                }
            }

            // App Store（新）
            GroupBox {
                appStoreRow
            }

            // Passwords（新）
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    permissionRow(
                        icon: "key.horizontal",
                        titleKey: "permission.passwords",
                        hintKey: "permission.passwords.hint",
                        isOn: Binding(
                            get: { passwordsFillEnabled },
                            set: { tryEnablePasswords($0) }
                        )
                    )
                    if passwordsFillEnabled && !viewModel.isPasswordConfigured {
                        loginPasswordMissingRow
                    }
                }
            }

            // 1Password 解锁（新）——用 1Password 自己的解锁密码，开启时按需索取。
            GroupBox {
                onePasswordRow
            }

            // Bitwarden 解锁（新）——浏览器扩展，用 Bitwarden 自己的解锁密码。
            GroupBox {
                bitwardenRow
            }

            // ===== 开发者工具 =====
            sectionLabel("permission.section.devtools")

            // 终端 sudo 授权
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    permissionRow(
                        icon: "terminal",
                        titleKey: "permission.sudo",
                        isOn: Binding(
                            get: { sudoAuthEnabled },
                            set: { tryEnableSudoAuth($0) }
                        )
                    )
                    // 仅 macOS 13.x:/etc/pam.d/sudo 被系统更新重置后提示修复
                    if setupManager.needsLegacySudoRepair {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("notify.authrepair.title".localized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("permission.authorization.repair".localized) {
                                repairAuthorizationAction()
                            }
                        }
                    }
                }
            }

            // SSH Agent — info icon shows export command + click copies it
            GroupBox {
                permissionRow(
                    icon: "network",
                    titleKey: "permission.ssh.agent",
                    hint: "export SSH_AUTH_SOCK=\(SSHAgentServer.shared.socketPath)",
                    onInfoClick: {
                        let cmd = "export SSH_AUTH_SOCK=\(SSHAgentServer.shared.socketPath)"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cmd, forType: .string)
                    },
                    isOn: Binding(
                        get: { sshAgentEnabled },
                        set: { toggleSSHAgent($0) }
                    )
                )
            }

            // imk CLI
            GroupBox {
                permissionRow(
                    icon: "command",
                    titleKey: "permission.cli",
                    isOn: Binding(
                        get: { cliEnabled },
                        set: { toggleCLI($0) }
                    )
                )
            }

            // Quick Fill (hotkey recorder sits left of the toggle)
            GroupBox {
                permissionRow(
                    icon: "command.square",
                    titleKey: "permission.quickfill",
                    hintKey: "permission.quickfill.hint",
                    trailing: { HotkeyRecorderButton() },
                    isOn: Binding(
                        get: { quickFillEnabled },
                        set: { toggleQuickFill($0) }
                    )
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 20)
        }
    }

    // MARK: - Section Header
    private func sectionLabel(_ key: String) -> some View {
        HStack {
            Text(key.localized)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
    }

    // MARK: - App Store Row
    private var appStoreRow: some View {
        permissionRow(
            icon: "bag",
            titleKey: "permission.appstore",
            hintKey: "permission.appstore.hint",
            isOn: Binding(
                get: { appStoreFillEnabled },
                set: { tryEnableAppStore($0) }
            )
        )
    }

    // MARK: - 1Password Row
    private var onePasswordRow: some View {
        permissionRow(
            icon: "lock.shield",
            titleKey: "permission.onepassword",
            hintKey: "permission.onepassword.hint",
            isOn: Binding(
                get: { onePasswordUnlockEnabled },
                set: { tryEnableOnePassword($0) }
            )
        )
    }

    // MARK: - Bitwarden Row
    private var bitwardenRow: some View {
        permissionRow(
            icon: "lock.shield",
            titleKey: "permission.bitwarden",
            hintKey: "permission.bitwarden.hint",
            isOn: Binding(
                get: { bitwardenUnlockEnabled },
                set: { tryEnableBitwarden($0) }
            )
        )
    }

    // MARK: - Sound Picker

    /// Inline sound picker shown next to a feature toggle. A speaker icon
    /// makes clear the dropdown selects a sound; selecting a non-silent
    /// option triggers an immediate preview play.
    private func soundPicker(selection: Binding<String>, tipKey: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: selection.wrappedValue.isEmpty ? "speaker.slash" : "speaker.wave.2")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Picker("", selection: selection) {
                Text("permission.screen.unlock.sound.silent".localized).tag("")
                Divider()
                ForEach(Self.systemSounds, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 130)
            .onChange(of: selection.wrappedValue) { newValue in
                if !newValue.isEmpty {
                    NSSound(named: newValue)?.play()
                }
            }
        }
        .help(tipKey.localized)
    }

    // MARK: - Row Layout

    /// Standard permission row: icon · title · info-tooltip · [trailing] · toggle
    /// - `hintKey`: localized hint shown as hover tooltip on the (i) icon
    /// - `hint`: raw hint string (overrides hintKey when both given; for
    ///           dynamic content like file paths)
    /// - `onInfoClick`: makes the (i) clickable; common use is "click to
    ///                  copy the hint to clipboard"
    /// - `trailing`: optional view rendered just before the toggle (e.g.
    ///               HotkeyRecorderButton for quick-fill)
    @ViewBuilder
    private func permissionRow<Trailing: View>(
        icon: String,
        titleKey: String,
        hintKey: String? = nil,
        hint: String? = nil,
        onInfoClick: (() -> Void)? = nil,
        @ViewBuilder trailing: () -> Trailing,
        isOn: Binding<Bool>
    ) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundColor(.accentColor)
            Text(titleKey.localized)
                .font(.headline)
            let resolvedHint = hint ?? hintKey?.localized
            if let resolvedHint = resolvedHint {
                // Use AppKit-backed tooltip (nsTooltip) — SwiftUI .help()
                // doesn't reliably show on plain Image views.
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .nsTooltip(resolvedHint)
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .onTapGesture {
                        onInfoClick?()
                    }
            }
            Spacer()
            trailing()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(4)
    }

    /// Convenience overload without trailing view.
    @ViewBuilder
    private func permissionRow(
        icon: String,
        titleKey: String,
        hintKey: String? = nil,
        hint: String? = nil,
        onInfoClick: (() -> Void)? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        permissionRow(
            icon: icon,
            titleKey: titleKey,
            hintKey: hintKey,
            hint: hint,
            onInfoClick: onInfoClick,
            trailing: { EmptyView() },
            isOn: isOn
        )
    }

    // MARK: - Toggle Handlers

    /// 开关显示"开"但 Keychain 还没有登录密码（首次安装默认开启时的状态）：
    /// 功能实际不生效，给出提示 + 一键补配。
    private var loginPasswordMissingRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text("permission.password.missing".localized)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("permission.configure".localized) {
                viewModel.setupLoginPasswordIfNeeded()
            }
        }
    }

    private func tryEnableScreenUnlock(_ enable: Bool) {
        if enable {
            if !setupManager.hasAccessibilityPermission {
                showPrerequisiteAlert(
                    title: "alert.need.accessibility".localized,
                    message: "alert.need.accessibility.message".localized,
                    actionTitle: "alert.go.settings".localized
                ) {
                    setupManager.openAccessibilitySettings()
                }
                return
            }
            // 开启前按需索取系统登录密码；取消则不开启。
            if viewModel.setupLoginPasswordIfNeeded() {
                screenUnlockEnabled = true
            }
        } else {
            screenUnlockEnabled = false
            // 解锁与 Passwords 都关了 → 清除登录密码（1Password 用独立密码，不参与）。
            if !passwordsFillEnabled {
                viewModel.clearLoginPassword()
            }
        }
    }

    private func tryEnablePasswords(_ enable: Bool) {
        if enable {
            // 开启前按需索取系统登录密码；取消则不开启。
            if viewModel.setupLoginPasswordIfNeeded() {
                passwordsFillEnabled = true
            }
        } else {
            passwordsFillEnabled = false
            // 解锁与 Passwords 都关了 → 清除登录密码（1Password 用独立密码，不参与）。
            if !screenUnlockEnabled {
                viewModel.clearLoginPassword()
            }
        }
    }

    private func tryEnableOnePassword(_ enable: Bool) {
        if enable {
            // 开启前按需索取 1Password 的解锁密码（可与系统密码不同）；取消则不开启。
            if viewModel.setupOnePasswordPasswordIfNeeded() {
                onePasswordUnlockEnabled = true
            }
        } else {
            onePasswordUnlockEnabled = false
            // 1Password 用独立密码，关闭即清除，不影响登录密码。
            viewModel.clearOnePasswordPassword()
        }
    }

    private func tryEnableBitwarden(_ enable: Bool) {
        if enable {
            // 开启前按需索取 Bitwarden 的解锁密码（独立密码）；取消则不开启。
            if viewModel.setupBitwardenPasswordIfNeeded() {
                bitwardenUnlockEnabled = true
            }
        } else {
            bitwardenUnlockEnabled = false
            // Bitwarden 用独立密码，关闭即清除。
            viewModel.clearBitwardenPassword()
        }
    }

    private func tryEnableAppStore(_ enable: Bool) {
        if enable {
            // 开启前按需索取 Apple ID 密码；取消则不开启。
            if viewModel.setupAppleIDPasswordIfNeeded() {
                appStoreFillEnabled = true
            }
        } else {
            appStoreFillEnabled = false
            viewModel.clearAppleIDPassword()
        }
    }

    private func tryEnableSudoAuth(_ enable: Bool) {
        if enable && !setupManager.isPAMModuleInstalled {
            showAlert(title: "alert.need.pam".localized, message: "alert.need.pam.reinstall".localized)
            return
        }
        setupManager.setSudoAuthEnabled(enable)
    }

    private func tryEnableSystemAuth(_ enable: Bool) {
        if enable && !setupManager.isPAMModuleInstalled {
            showAlert(title: "alert.need.pam".localized, message: "alert.need.pam.reinstall".localized)
            return
        }
        setupManager.setAuthorizationEnabled(enable)
    }

    private func repairAuthorizationAction() {
        setupManager.repairAuthorization { success, error in
            if !success, let error = error {
                let alert = NSAlert()
                alert.messageText = "notify.authrepair.title".localized
                alert.informativeText = error
                alert.runModal()
            }
        }
    }

    private func toggleSSHAgent(_ enable: Bool) {
        sshAgentEnabled = enable
        if enable {
            try? SSHAgentServer.shared.start()
            SSHAgentServer.shared.installAuthSockEnv()   // 开启即设 SSH_AUTH_SOCK
        } else {
            SSHAgentServer.shared.stop()
            SSHAgentServer.shared.restoreAuthSockEnv()   // 关闭恢复原值
        }
    }

    private func toggleCLI(_ enable: Bool) {
        cliEnabled = enable
        NotificationCenter.default.post(name: .cliToggleChanged, object: enable)
    }

    private func toggleQuickFill(_ enable: Bool) {
        quickFillEnabled = enable
        NotificationCenter.default.post(name: .quickFillToggleChanged, object: enable)
    }

    // MARK: - Alerts

    private func showPrerequisiteAlert(title: String, message: String, actionTitle: String, action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: actionTitle)
        alert.addButton(withTitle: "alert.cancel".localized)

        if alert.runModalOverSettings() == .alertFirstButtonReturn {
            action()
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModalOverSettings()
    }
}

// MARK: - Hotkey Recorder

struct HotkeyRecorderButton: View {
    @State private var isRecording = false
    @State private var displayText = GlobalHotKey.currentDisplayString
    @State private var localMonitor: Any?

    var body: some View {
        Button(action: { startRecording() }) {
            Text(isRecording ? "permission.hotkey.recording".localized : displayText)
                .font(.system(size: 12, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isRecording ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isRecording ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            let mods = event.modifierFlags.intersection([.control, .option, .command, .shift])
            // Require at least one modifier
            guard !mods.isEmpty else {
                if event.keyCode == 53 { // Esc — cancel
                    stopRecording()
                }
                return nil
            }

            // Save to UserDefaults
            UserDefaults.standard.set(Int(event.keyCode), forKey: GlobalHotKey.keyCodeKey)
            UserDefaults.standard.set(Int(mods.rawValue), forKey: GlobalHotKey.modifiersKey)

            displayText = GlobalHotKey.displayString(keyCode: event.keyCode, modifiers: mods)
            stopRecording()

            // Notify AppDelegate to re-register
            NotificationCenter.default.post(name: .quickFillHotkeyChanged, object: nil)
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }
}

// MARK: - Status Tab

struct StatusTabView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var setupManager: SetupManager
    @State private var isAutoStartEnabled = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Status List
                GroupBox {
                    VStack(spacing: 0) {
                        // 设备连接
                        statusRow(
                            title: "status.device.connection".localized,
                            isOK: viewModel.isDeviceConnected,
                            actionTitle: nil,
                            action: nil
                        )
                        Divider()

                        // 指纹数量
                        statusRow(
                            title: "status.fingerprint.count".localized,
                            value: "\(viewModel.fingerprintCount)/5",
                            isOK: viewModel.fingerprintCount > 0,
                            actionTitle: viewModel.fingerprintCount == 0 ? "fingerprint.add".localized : nil
                        ) {
                            NotificationCenter.default.post(name: .openSettingsTab, object: SettingsTab.device)
                        }
                        Divider()

                        // 解锁密码
                        statusRow(
                            title: "status.unlock.password".localized,
                            isOK: viewModel.isPasswordConfigured,
                            actionTitle: !viewModel.isPasswordConfigured ? "permission.configure".localized : nil
                        ) {
                            viewModel.configurePassword()
                        }
                        Divider()

                        // 辅助功能
                        statusRow(
                            title: "status.accessibility".localized,
                            isOK: setupManager.hasAccessibilityPermission,
                            actionTitle: !setupManager.hasAccessibilityPermission ? "alert.authorize".localized : nil
                        ) {
                            setupManager.openAccessibilitySettings()
                        }
                        Divider()

                        // PAM 模块
                        statusRow(
                            title: "status.pam.module".localized,
                            isOK: setupManager.isPAMModuleInstalled,
                            actionTitle: nil,
                            action: nil
                        )
                        Divider()

                        // sudo 授权
                        statusRow(
                            title: "status.sudo.auth".localized,
                            isOK: setupManager.isSudoAuthEnabled,
                            optional: true,
                            actionTitle: !setupManager.isSudoAuthEnabled && setupManager.isPAMModuleInstalled ? "alert.enable".localized : nil
                        ) {
                            setupManager.setSudoAuthEnabled(true)
                        }
                        Divider()

                        // 开机自启
                        statusRow(
                            title: "status.auto.start".localized,
                            isOK: isAutoStartEnabled,
                            actionTitle: !isAutoStartEnabled ? "alert.enable".localized : nil
                        ) {
                            enableAutoStart()
                        }
                    }
                }

                // Status Message
                statusMessage
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(20)
        }
        .onAppear {
            setupManager.refreshStatus()
            checkAutoStartStatus()
        }
    }

    // MARK: - Auto Start

    private func checkAutoStartStatus() {
        let service = SMAppService.mainApp
        isAutoStartEnabled = service.status == .enabled
    }

    private func enableAutoStart() {
        let service = SMAppService.mainApp
        do {
            try service.register()
            isAutoStartEnabled = true
        } catch {
            NSLog("Failed to enable auto start: %@", error.localizedDescription)
        }
    }

    // MARK: - Status Row

    private func statusRow(
        title: String,
        value: String? = nil,
        isOK: Bool,
        optional: Bool = false,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        HStack {
            Text(title)

            Spacer()

            if let value = value {
                Text(value)
                    .foregroundColor(.secondary)
            }

            if let actionTitle = actionTitle, let action = action, !isOK {
                Button(actionTitle) {
                    action()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Image(systemName: isOK ? "checkmark.circle.fill" : (optional ? "minus.circle" : "xmark.circle"))
                .foregroundColor(isOK ? .green : (optional ? .secondary : .orange))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusMessage: Text {
        if !viewModel.isDeviceConnected {
            return Text("status.waiting.device".localized)
        } else if viewModel.fingerprintCount == 0 {
            return Text("status.tap.enroll".localized)
        } else if !viewModel.isPasswordConfigured {
            return Text("status.tap.configure".localized)
        } else if !setupManager.hasAccessibilityPermission {
            return Text("status.tap.authorize".localized)
        } else {
            return Text("status.all.ready".localized)
        }
    }
}

// MARK: - About Tab

struct AboutTabView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var setupManager: SetupManager
    @ObservedObject var localization = LocalizationManager.shared
    @ObservedObject private var logManager = LogManager.shared
    @State private var showingUninstallConfirm = false
    @State private var isHoveringLanguage = false
    @State private var isHoveringGitHub = false
    @State private var isHoveringUninstall = false
    @State private var isHoveringStats = false
    // 匿名使用统计开关（笔记本图标，带笔=开、不带笔=关）
    @AppStorage("immurok.telemetry.enabled") private var telemetryEnabled = true
    @Environment(\.openWindow) private var openWindow
    // 诊断日志默认仅在 Debug 构建显示；正式版折叠，点左下角图标展开
    #if DEBUG
    @State private var showLogs = true
    #else
    @State private var showLogs = false
    #endif

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "4.0"
    }

    /// "App v1.4.0(410)"
    private var appVersionText: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "App v\(appVersion)(\(build))"
    }

    /// "FW v1.6.0(b2)"（设备版本可能带第 4 段 build，无设备时显示 —）
    private var fwVersionText: String {
        guard let fw = viewModel.firmwareVersion else { return "FW —" }
        let parts = fw.split(separator: ".")
        if parts.count >= 4 {
            return "FW v\(parts.prefix(3).joined(separator: "."))(\(parts[3]))"
        }
        return "FW v\(fw)"
    }

    private var logoImage: NSImage {
        if let url = Bundle.main.url(forResource: "icon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.isTemplate = true
            return img
        }
        return NSApplication.shared.applicationIconImage
    }

    var body: some View {
        VStack(spacing: 0) {
            // App Icon and Info - compact
            VStack(spacing: 8) {
                Image(nsImage: logoImage)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
                    .foregroundColor(.accentColor)

                HStack(spacing: 10) {
                    Text("\(appVersionText) / \(fwVersionText)")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Button("fwupdate.check".localized) {
                        openWindow(id: "software-update")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .controlSize(.small)
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 16)

            // Log view (selectable + copyable) — 正式版默认隐藏
            if showLogs {
                LogTextView(entries: logManager.entries)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("about.logs.hidden".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
                .padding(.horizontal, 16)

            // Bottom bar
            HStack(alignment: .center) {
                // Left side: Language picker + GitHub
                HStack(spacing: 12) {
                    Menu {
                        ForEach(LocalizationManager.supportedLanguages, id: \.code) { lang in
                            Button(action: {
                                localization.setLanguage(lang.code)
                            }) {
                                HStack {
                                    Text(lang.name)
                                    if localization.currentLanguage == lang.code {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "globe")
                            .font(.system(size: 20))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(isHoveringLanguage ? .accentColor : .secondary)
                    .onHover { isHoveringLanguage = $0 }
                    .help("settings.language".localized)

                    Link(destination: URL(string: "https://github.com/immurok/")!) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(isHoveringGitHub ? .accentColor : .secondary)
                    .onHover { isHoveringGitHub = $0 }
                    .help("GitHub")

                    // 匿名使用统计开关：笔记本带笔=开，不带笔=关
                    Button {
                        telemetryEnabled.toggle()
                    } label: {
                        Image(systemName: telemetryEnabled ? "square.and.pencil" : "note.text")
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(isHoveringStats ? .accentColor : (telemetryEnabled ? .secondary : Color.secondary.opacity(0.4)))
                    .onHover { isHoveringStats = $0 }
                    .help("fwupdate.telemetry.tip".localized)
                }

                Spacer()

                // Right side: Show/hide logs + Clear log + Uninstall
                Button {
                    showLogs.toggle()
                } label: {
                    Image(systemName: showLogs ? "doc.text.fill" : "doc.text")
                        .font(.system(size: 16))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("about.logs.toggle".localized)

                if showLogs {
                    Button {
                        logManager.clear()
                    } label: {
                        Image(systemName: "trash.slash")
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("about.logs.clear".localized)
                }

                Button(role: .destructive) {
                    showingUninstallConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 18))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundColor(isHoveringUninstall ? .red : .secondary)
                .onHover { isHoveringUninstall = $0 }
                .help("about.uninstall".localized)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .padding(.top, 8)
        }
        .alert("about.uninstall.confirm".localized, isPresented: $showingUninstallConfirm) {
            Button("alert.cancel".localized, role: .cancel) { }
            Button("alert.delete".localized, role: .destructive) {
                performUninstall()
            }
        } message: {
            Text("about.uninstall.message".localized)
        }
    }

    private func performUninstall() {
        setupManager.uninstall { success, error in
            if success {
                showAlert(title: "about.uninstall.done".localized, message: "about.uninstall.done.message".localized)
            } else {
                showAlert(title: "about.uninstall.failed".localized, message: error ?? "error.unknown".localized)
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

// MARK: - LogTextView (NSTextView wrapper for selectable/copyable log)

struct LogTextView: NSViewRepresentable {
    var entries: [LogManager.LogEntry]

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false

        return scrollView
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var didInitialScroll = false
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let wasAtBottom: Bool = {
            let visibleRect = scrollView.contentView.bounds
            let contentHeight = textView.frame.height
            return visibleRect.maxY >= contentHeight - 20
        }()

        let text = entries.map { entry in
            "\(Self.timeFormatter.string(from: entry.timestamp))  \(entry.message)"
        }.joined(separator: "\n")

        textView.string = text

        // 首次显示总是定位到最新一条（布局尚未完成时同步 scroll 会失效，
        // 延后到下一个 runloop）；此后仅当用户本就停在底部才跟随滚动。
        if !context.coordinator.didInitialScroll {
            context.coordinator.didInitialScroll = true
            DispatchQueue.main.async { [weak textView] in
                textView?.scrollToEndOfDocument(nil)
            }
        } else if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }
}
