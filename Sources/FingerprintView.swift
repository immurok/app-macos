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
            .disabled(!viewModel.isDeviceConnected || viewModel.isEnrolling || viewModel.nextAvailableSlot == nil)

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

// MARK: - Enrollment Sheet

struct EnrollmentSheet: View {
    @ObservedObject var viewModel: FingerprintViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            // Fingerprint animation area
            ZStack {
                Circle()
                    .fill(Color(NSColor.controlBackgroundColor))
                    .frame(width: 120, height: 120)

                Image(systemName: "touchid")
                    .font(.system(size: 56))
                    .foregroundColor(viewModel.enrollmentProgress > 0 ? .accentColor : .secondary)
                    .opacity(viewModel.isEnrolling ? 1.0 : 0.5)
            }

            Text(viewModel.enrollmentStatus)
                .font(.headline)
                .multilineTextAlignment(.center)

            ProgressView(value: Double(viewModel.enrollmentProgress), total: Double(viewModel.enrollmentTotal))
                .frame(width: 200)

            Text("\(viewModel.enrollmentProgress)/\(viewModel.enrollmentTotal)")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 16) {
                Button("alert.cancel".localized) {
                    viewModel.cancelEnrollment()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(32)
        .frame(width: 300, height: 320)
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
    @Published var enrollmentTotal = 6  // Match firmware ENROLL_CAPTURE_COUNT

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
                    NSLog("FingerprintView: new bitmap=0x%02X (cached)", self.fingerprintBitmap)
                    self.showAlert(title: "enroll.success".localized, message: "enroll.success.message".localized)
                case .failed:
                    self.isEnrolling = false
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
        guard !isEnrolling, !gateController.isPresented else { return }

        NSLog("FingerprintView: enrollFingerprint called with slot=%d, bitmap=0x%02X, nextAvailable=%@",
              slot, fingerprintBitmap, nextAvailableSlot.map { String($0) } ?? "nil")

        currentEnrollSlot = slot
        enrollmentProgress = 0

        // If fingerprints already enrolled, firmware requires FP verification first
        if fingerprintCount > 0 {
            gateController.present(title: "fingerprint.add".localized, onCancel: { [weak self] in
                self?.currentEnrollSlot = nil
            })
        }

        bleManager.startEnrollment(slotId: UInt8(slot)) { [weak self] success in
            Task { @MainActor in
                guard let self = self else { return }
                if success {
                    // Gate succeeded (or wasn't needed) — transition to enrollment sheet
                    self.gateController.reset()
                    self.isEnrolling = true
                    self.enrollmentStatus = "enroll.place.finger".localized
                } else {
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
        alert.runModal()
    }
}
