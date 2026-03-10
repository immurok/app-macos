import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

private func batteryIconName(level: Int) -> String {
    switch level {
    case 0...10:  return "battery.0percent"
    case 11...35: return "battery.25percent"
    case 36...65: return "battery.50percent"
    case 66...90: return "battery.75percent"
    default:      return "battery.100percent"
    }
}

// MARK: - Device Tab

struct DeviceTabView: View {
    @ObservedObject var viewModel: AppViewModel
    @StateObject private var fpViewModel = FingerprintViewModel()

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

                            Text(viewModel.deviceStatusText)
                                .foregroundColor(.secondary)

                            Spacer()

                            if let level = viewModel.batteryLevel {
                                Image(systemName: batteryIconName(level: level))
                                    .foregroundColor(level <= 10 ? .red : .secondary)
                                Text("\(level)%")
                                    .font(.callout)
                                    .foregroundColor(level <= 10 ? .red : .secondary)
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

                        // Fingerprint gate message
                        if let gateMessage = fpViewModel.gateMessage {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.6)
                                Text(gateMessage)
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }

                        Divider()

                        // Test button
                        HStack {
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
                            .disabled(!fpViewModel.isDeviceConnected || fpViewModel.isTesting)

                            if let testResult = fpViewModel.testResult {
                                Text(testResult)
                                    .font(.caption)
                                    .foregroundColor(testResult.contains("fingerprint.test.success".localized) ? .green : .orange)
                            }
                        }
                    }
                    .padding(4)
                }

                // Pairing & Factory Reset
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("pairing.title".localized, systemImage: "lock.shield")
                            .font(.headline)

                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(viewModel.isDevicePaired ? "pairing.status.paired".localized : "pairing.status.unpaired".localized)
                                    .font(.callout)
                                    .foregroundColor(viewModel.isDevicePaired ? .green : .orange)
                            }

                            Spacer()

                            Button("pairing.start".localized) {
                                viewModel.startPairing()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!viewModel.isDeviceConnected || viewModel.isPairing)

                            Button("reset.confirm".localized) {
                                viewModel.factoryReset()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!viewModel.isDeviceConnected)
                        }

                        if viewModel.isPairing {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.6)
                                Text("pairing.in.progress".localized)
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                        }

                        if viewModel.isWaitingForFingerprintGate {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.6)
                                Text("fingerprint.verify.required".localized)
                                    .font(.caption)
                                    .foregroundColor(.orange)
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
    @State private var selectedCategory: KeyCategory = .system
    @State private var showingAddSheet = false
    @State private var copiedNotification: String?
    @State private var isManaging = false
    @State private var selectedEntries: Set<Int> = []
    @State private var hoveredEntry: Int? = nil
    @State private var editingEntry: KeystoreViewModel.Entry? = nil

    private enum KeyCategory: String, CaseIterable {
        case system, sshGit, api, otp

        var icon: String {
            switch self {
            case .system: return "key.fill"
            case .sshGit: return "terminal"
            case .api: return "network"
            case .otp: return "clock.badge"
            }
        }

        var localizedName: String {
            switch self {
            case .system: return "keys.system".localized
            case .sshGit: return "keys.ssh".localized
            case .api: return "keys.api".localized
            case .otp: return "keys.otp".localized
            }
        }

        /// Map to BLE keystore category (nil for system)
        var keystoreCat: KeystoreCategory? {
            switch self {
            case .system: return nil
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
                        if let cat = category.keystoreCat {
                            keystoreVM.loadEntries(cat: cat)
                        }
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
                if let cat = selectedCategory.keystoreCat {
                    HStack {
                        Text("\(keystoreVM.entries.count)/\(cat.maxEntries)")
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
                } else {
                    HStack {
                        Text("keys.name".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("keys.action".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 50)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

                Divider()

                // 条目列表
                ScrollView {
                    VStack(spacing: 0) {
                        switch selectedCategory {
                        case .system:
                            systemKeysContent
                        default:
                            keystoreListContent
                        }
                    }
                }

                // 底部工具栏（仅 keystore 分类）
                if selectedCategory != .system {
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
                            .disabled(!viewModel.isDeviceConnected || keystoreVM.isAdding)

                            Spacer()

                            if let note = copiedNotification {
                                Text(note)
                                    .font(.caption)
                                    .foregroundColor(.green)
                            } else if !keystoreVM.showGateOverlay {
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
                                .disabled(!viewModel.isDeviceConnected || keystoreVM.isAdding)
                            }

                            if selectedCategory == .otp {
                                Button(action: { importOTP() }) {
                                    HStack(spacing: 2) {
                                        Image(systemName: "square.and.arrow.down")
                                        Text("keys.import".localized)
                                    }
                                }
                                .buttonStyle(.borderless)
                                .disabled(!viewModel.isDeviceConnected || keystoreVM.isImporting)

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
        }
        .sheet(isPresented: $showingAddSheet) {
            if let cat = selectedCategory.keystoreCat {
                AddKeyEntrySheet(category: cat, keystoreVM: keystoreVM, isPresented: $showingAddSheet)
            }
        }
        .sheet(item: $editingEntry) { entry in
            if let cat = selectedCategory.keystoreCat {
                EditKeyEntrySheet(entry: entry, category: cat) { name, service in
                    keystoreVM.updateEntry(cat: cat, idx: UInt8(entry.index),
                                           name: name, service: service) { _ in }
                    editingEntry = nil
                } onCancel: {
                    editingEntry = nil
                }
            }
        }
        .overlay {
            if keystoreVM.showGateOverlay {
                FingerprintGateOverlay(
                    countdown: keystoreVM.gateCountdown,
                    total: KeystoreViewModel.gateTimeout,
                    onDismiss: { keystoreVM.dismissGate() }
                )
            } else if keystoreVM.isImporting {
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
                keystoreVM.loadEntries(cat: .ssh)
            }
        }
    }

    // MARK: - System Keys Content

    private var systemKeysContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("permission.unlock.password".localized)

                Spacer()

                if viewModel.isPasswordConfigured {
                    Text("permission.configured".localized)
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Text("permission.configure".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button(viewModel.isPasswordConfigured ? "permission.modify".localized : "permission.configure".localized) {
                    viewModel.configurePassword()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!viewModel.isDevicePaired)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if viewModel.isWaitingForFingerprintGate {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("fingerprint.verify.required".localized)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }
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
        guard let cat = selectedCategory.keystoreCat else { return }
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

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let name = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        // KEY_GENERATE already has its own FP gate — no need for separate requestAuth()
        keystoreVM.isAdding = true
        BLEManager.shared.sshGenerateKey(name: name) { [self] result in
            DispatchQueue.main.async {
                self.keystoreVM.isAdding = false
                self.keystoreVM.dismissGate()
                if let result = result {
                    NSLog("SSH key generated: idx=%d", result.idx)
                    let blob = SSHKeyCache.buildSSHPublicKeyBlob(publicKey: result.publicKey)
                    let fp = SSHKeyCache.computeFingerprint(blob: blob)
                    SSHKeyCache.shared.addEntry(SSHKeyCacheEntry(
                        index: result.idx, name: name, publicKeyBlob: blob, fingerprint: fp
                    ))
                    self.keystoreVM.loadEntries(cat: .ssh)
                }
                self.showCopiedNotification("ssh.generate.success".localized)
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
                guard panel.runModal() == .OK, let url = panel.url else { return }

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
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }

        let startIndex = lines.first?.lowercased().starts(with: "name") == true ? 1 : 0

        var parsed: [(name: String, service: String, secret: Data)] = []
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

        guard !parsed.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "keys.import.confirm".localized
        alert.informativeText = "keys.import.count".localized(parsed.count)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "alert.cancel".localized)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

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

// MARK: - Fingerprint Gate Overlay

struct FingerprintGateOverlay: View {
    let countdown: Int
    let total: Int
    let onDismiss: () -> Void

    private var progress: Double {
        total > 0 ? Double(countdown) / Double(total) : 0
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "touchid")
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)

                Text("fingerprint.verify.required".localized)
                    .font(.headline)

                // Countdown progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 2)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(progress > 0.17 ? Color.accentColor : Color.red)
                            .frame(width: geo.size.width * progress, height: 2)
                            .animation(.linear(duration: 1), value: countdown)
                    }
                }
                .frame(height: 2)
            }
            .frame(width: 220)
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.windowBackgroundColor))
                    .shadow(radius: 10)
            )
            .overlay(alignment: .topTrailing) {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(10)
            }
        }
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
    @AppStorage("immurok.sudoAuthEnabled") private var sudoAuthEnabled = false
    @AppStorage("immurok.authorizationEnabled") private var authorizationEnabled = false
    @AppStorage("immurok.sshAgentEnabled") private var sshAgentEnabled = true
    @AppStorage("immurok.cliEnabled") private var cliEnabled = true
    @AppStorage("immurok.quickFillEnabled") private var quickFillEnabled = true

    var body: some View {
        VStack(spacing: 16) {
            // 屏幕解锁
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    // Header with toggle
                    HStack {
                        Image(systemName: "lock.open")
                            .frame(width: 20)
                            .foregroundColor(.accentColor)
                        Text("permission.screen.unlock".localized)
                            .font(.headline)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { screenUnlockEnabled },
                            set: { tryEnableScreenUnlock($0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
                .padding(4)
            }

            // 终端 sudo 授权
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    // Header with toggle
                    HStack {
                        Image(systemName: "terminal")
                            .frame(width: 20)
                            .foregroundColor(.accentColor)
                        Text("permission.sudo".localized)
                            .font(.headline)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { sudoAuthEnabled },
                            set: { tryEnableSudoAuth($0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
                .padding(4)
            }

            // 界面认证授权（系统设置等）
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    // Header with toggle
                    HStack {
                        Image(systemName: "macwindow.badge.plus")
                            .frame(width: 20)
                            .foregroundColor(.accentColor)
                        Text("permission.authorization".localized)
                            .font(.headline)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { authorizationEnabled },
                            set: { tryEnableSystemAuth($0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
                .padding(4)
            }

            // SSH Agent
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "network")
                            .frame(width: 20)
                            .foregroundColor(.accentColor)
                        Text("permission.ssh.agent".localized)
                            .font(.headline)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { sshAgentEnabled },
                            set: { toggleSSHAgent($0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }

                    HStack(spacing: 4) {
                        Text("export SSH_AUTH_SOCK=\(SSHAgentServer.shared.socketPath)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("export SSH_AUTH_SOCK=\(SSHAgentServer.shared.socketPath)", forType: .string)
                        }) {
                            Image(systemName: "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(4)
            }

            // imk CLI
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "command")
                            .frame(width: 20)
                            .foregroundColor(.accentColor)
                        Text("permission.cli".localized)
                            .font(.headline)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { cliEnabled },
                            set: { toggleCLI($0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
                .padding(4)
            }

            // Quick Fill (Ctrl+\)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "command.square")
                            .frame(width: 20)
                            .foregroundColor(.accentColor)
                        Text("permission.quickfill".localized)
                            .font(.headline)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { quickFillEnabled },
                            set: { toggleQuickFill($0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }

                    HStack {
                        Text("permission.quickfill.hint".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        HotkeyRecorderButton()
                    }
                }
                .padding(4)
            }

            Spacer()
        }
        .padding(20)
    }

    // MARK: - Toggle Handlers

    private func tryEnableScreenUnlock(_ enable: Bool) {
        if enable && !setupManager.hasAccessibilityPermission {
            showPrerequisiteAlert(
                title: "alert.need.accessibility".localized,
                message: "alert.need.accessibility.message".localized,
                actionTitle: "alert.go.settings".localized
            ) {
                setupManager.openAccessibilitySettings()
            }
            return
        }
        screenUnlockEnabled = enable
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

    private func toggleSSHAgent(_ enable: Bool) {
        sshAgentEnabled = enable
        if enable {
            try? SSHAgentServer.shared.start()
        } else {
            SSHAgentServer.shared.stop()
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

        if alert.runModal() == .alertFirstButtonReturn {
            action()
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
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

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "4.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "v\(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            // App Icon and Info - compact
            VStack(spacing: 8) {
                Image(systemName: "touchid")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)

                Text("immurok")
                    .font(.title2)
                    .fontWeight(.bold)

                Text(versionText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if let fwVersion = viewModel.firmwareVersion {
                    Text("firmware.version".localized(fwVersion))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text("app.description".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 16)

            // Log view (selectable + copyable)
            LogTextView(entries: logManager.entries)

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

                    Link(destination: URL(string: "https://github.com")!) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(isHoveringGitHub ? .accentColor : .secondary)
                    .onHover { isHoveringGitHub = $0 }
                    .help("GitHub")
                }

                Spacer()

                // Right side: Clear log + Uninstall
                Button {
                    logManager.clear()
                } label: {
                    Image(systemName: "trash.slash")
                        .font(.system(size: 16))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("清除日志")

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
        alert.runModal()
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

        if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }
}
