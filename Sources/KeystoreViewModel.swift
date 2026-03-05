import Foundation

@MainActor
class KeystoreViewModel: ObservableObject {

    struct Entry: Identifiable, Hashable {
        let index: Int
        let name: String
        let service: String  // OTP service name; empty for SSH/API
        var id: Int { index }
    }

    @Published var entries: [Entry] = []
    @Published var isLoading = false
    @Published var loadingProgress: Int = 0
    @Published var loadingTotal: Int = 0
    @Published var isAdding = false
    @Published var isDeleting = false
    @Published var deleteProgress: Int = 0
    @Published var deleteTotal: Int = 0
    @Published var isExporting = false
    @Published var isImporting = false
    @Published var importProgress: Int = 0
    @Published var importTotal: Int = 0
    @Published var showGateOverlay = false
    @Published var gateCountdown: Int = 0
    @Published var errorMessage: String?

    private let bleManager = BLEManager.shared
    private var currentCat: KeystoreCategory?
    private var gateObserver: Any?
    private var loadingTimeoutTask: Task<Void, Never>?
    private var errorDismissTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?

    static let gateTimeout = 30

    init() {
        gateObserver = NotificationCenter.default.addObserver(
            forName: BLEManager.fingerprintGateRequiredNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Only show gate overlay when a keystore operation is in progress;
                // ignore notifications from non-keystore operations (e.g. setPassword)
                guard let self = self,
                      self.isAdding || self.isDeleting || self.isImporting || self.isExporting
                else { return }
                self.startGateCountdown()
            }
        }
    }

    deinit {
        if let obs = gateObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Public

    func loadEntries(cat: KeystoreCategory) {
        if isLoading { return }

        let categoryChanged = currentCat != cat
        currentCat = cat
        isLoading = true
        loadingProgress = 0
        loadingTotal = 0
        if categoryChanged { entries = [] }
        clearError()

        // Safety timeout scales with expected entry count (min 10s)
        loadingTimeoutTask?.cancel()
        loadingTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard let self = self, self.isLoading else { return }
            self.isLoading = false
        }

        let progressCallback: (Int, Int) -> Void = { [weak self] current, total in
            Task { @MainActor in
                guard let self = self, self.currentCat == cat else { return }
                self.loadingProgress = current
                self.loadingTotal = total
            }
        }

        // KEY_COUNT + KEY_READ chain runs entirely on BLE queue (no MainActor hops between commands)
        if cat == .otp {
            // OTP: read name + service in one pass
            bleManager.getKeyEntryNamesAndService(cat: cat, progress: progressCallback) { [weak self] result in
                // Update KeyNameCache directly with the data we already have
                KeyNameCache.shared.replaceCategory(cat, with: result.map {
                    KeyNameCache.Entry(index: $0.index, name: $0.name, service: $0.service, category: cat)
                })
                Task { @MainActor in
                    guard let self = self, self.currentCat == cat else { return }
                    self.loadingTimeoutTask?.cancel()
                    self.entries = result.map { Entry(index: $0.index, name: $0.name, service: $0.service) }
                        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
                    self.isLoading = false
                }
            }
        } else {
            bleManager.getKeyEntryNames(cat: cat, progress: progressCallback) { [weak self] result in
                // Update KeyNameCache directly with the data we already have
                KeyNameCache.shared.replaceCategory(cat, with: result.map {
                    KeyNameCache.Entry(index: $0.index, name: $0.name, service: "", category: cat)
                })
                Task { @MainActor in
                    guard let self = self, self.currentCat == cat else { return }
                    self.loadingTimeoutTask?.cancel()
                    self.entries = result.map { Entry(index: $0.index, name: $0.name, service: "") }
                        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
                    self.isLoading = false
                }
            }
        }
    }

    /// Show fingerprint gate overlay, request unlock, dismiss gate, then call completion
    func requestAuth(completion: @escaping (Bool) -> Void) {
        startGateCountdown()
        bleManager.requestUnlock(timeout: 30.0) { [weak self] success in
            Task { @MainActor in
                guard let self = self else {
                    completion(false)
                    return
                }
                self.showGateOverlay = false
                self.countdownTask?.cancel()
                completion(success)
            }
        }
    }

    func addEntry(cat: KeystoreCategory, data: Data, completion: @escaping (Bool) -> Void) {
        isAdding = true
        clearError()

        requestAuth { [weak self] success in
            guard let self = self, success else {
                Task { @MainActor in self?.isAdding = false }
                completion(false)
                return
            }
            self.bleManager.writeKeyEntry(cat: cat, idx: 0xFF, data: data) { [weak self] success in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.isAdding = false
                    if success {
                        self.loadEntries(cat: cat)
                    } else {
                        self.showError("keys.add.failed".localized)
                    }
                    completion(success)
                }
            }
        }
    }

    func updateEntry(cat: KeystoreCategory, idx: UInt8, name: String, service: String,
                     completion: @escaping (Bool) -> Void) {
        isAdding = true
        clearError()

        requestAuth { [weak self] success in
            guard let self = self, success else {
                Task { @MainActor in self?.isAdding = false }
                completion(false)
                return
            }
            self.bleManager.readKeyEntry(cat: cat, idx: idx) { [weak self] data in
                guard let self = self, var entryData = data else {
                    Task { @MainActor in
                        self?.isAdding = false
                        self?.showError("keys.edit.failed".localized)
                    }
                    completion(false)
                    return
                }
                switch cat {
                case .ssh:
                    let nameData = Self.buildField(name, size: 16)
                    entryData.replaceSubrange(0..<16, with: nameData)
                case .otp:
                    let nameData = Self.buildField(name, size: 30)
                    let serviceData = Self.buildField(service, size: 30)
                    entryData.replaceSubrange(0..<30, with: nameData)
                    entryData.replaceSubrange(30..<60, with: serviceData)
                case .api:
                    let nameData = Self.buildField(name, size: 32)
                    entryData.replaceSubrange(0..<32, with: nameData)
                }
                self.bleManager.writeKeyEntry(cat: cat, idx: idx, data: entryData) { [weak self] success in
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.isAdding = false
                        if success {
                            // Update locally — no need to re-read all entries
                            if let i = self.entries.firstIndex(where: { $0.index == Int(idx) }) {
                                self.entries[i] = Entry(index: Int(idx), name: name, service: service)
                            }
                            KeyNameCache.shared.updateEntry(cat: cat, index: Int(idx), name: name, service: service)
                        } else {
                            self.showError("keys.edit.failed".localized)
                        }
                        completion(success)
                    }
                }
            }
        }
    }

    func deleteEntry(cat: KeystoreCategory, idx: UInt8) {
        isDeleting = true
        dismissGate()
        clearError()

        bleManager.deleteKeyEntry(cat: cat, idx: idx) { [weak self] success in
            Task { @MainActor in
                guard let self = self else { return }
                self.isDeleting = false
                self.dismissGate()
                if success {
                    // Remove locally first for immediate feedback
                    self.entries.removeAll { $0.index == Int(idx) }
                    // Refresh from device to get correct indices
                    self.loadEntries(cat: cat)
                } else {
                    self.showError("keys.delete.failed".localized)
                }
            }
        }
    }

    func deleteEntries(cat: KeystoreCategory, indices: [UInt8], completion: @escaping () -> Void) {
        isDeleting = true
        deleteProgress = 0
        deleteTotal = indices.count
        clearError()
        startGateCountdown()

        let ble = bleManager
        ble.requestUnlock(timeout: 30.0) { [weak self] success in
            Task { @MainActor in
                guard let self = self else { return }
                // Dismiss gate but keep isDeleting true
                self.showGateOverlay = false
                self.countdownTask?.cancel()
                guard success else {
                    self.isDeleting = false
                    self.deleteProgress = 0
                    self.deleteTotal = 0
                    completion()
                    return
                }
                self.deleteEntriesAfterAuth(cat: cat, indices: indices, completion: completion)
            }
        }
    }

    private func deleteEntriesAfterAuth(cat: KeystoreCategory, indices: [UInt8], completion: @escaping () -> Void) {
        // Delete from largest index first to avoid swap-delete index shifting
        let sorted = indices.sorted(by: >)
        func deleteNext(i: Int) {
            guard i < sorted.count else {
                Task { @MainActor in
                    // Remove deleted entries locally
                    let deletedSet = Set(indices.map { Int($0) })
                    self.entries.removeAll { deletedSet.contains($0.index) }
                    KeyNameCache.shared.removeEntries(cat: cat, indices: deletedSet)
                    self.isDeleting = false
                    self.deleteProgress = 0
                    self.deleteTotal = 0
                }
                completion()
                return
            }
            Task { @MainActor in
                self.deleteProgress = i + 1
            }
            bleManager.deleteKeyEntry(cat: cat, idx: sorted[i]) { _ in
                deleteNext(i: i + 1)
            }
        }
        deleteNext(i: 0)
    }

    func refresh() {
        guard let cat = currentCat else { return }
        loadEntries(cat: cat)
    }

    // MARK: - OTP Import/Export

    /// Read all OTP entries with full 64B data (name + service + secret)
    /// Requires fingerprint verification first (sets device-side gate cooldown for batch reads)
    func readAllOTPEntries(completion: @escaping ([(name: String, service: String, secret: Data)]) -> Void) {
        isExporting = true
        startGateCountdown()
        let ble = bleManager
        // Verify fingerprint first (also sets device-side gate cooldown)
        ble.requestUnlock(timeout: 30.0) { [weak self] success in
            Task { @MainActor in
                guard let self = self else { return }
                self.dismissGate()
                guard success else {
                    self.isExporting = false
                    completion([])
                    return
                }
                self.readAllOTPEntriesAfterAuth(ble: ble, completion: completion)
            }
        }
    }

    private func readAllOTPEntriesAfterAuth(ble: BLEManager,
                                            completion: @escaping ([(name: String, service: String, secret: Data)]) -> Void) {
        ble.getKeyCount(cat: .otp) { [weak self] count in
            guard let self = self, count > 0 else {
                Task { @MainActor in self?.isExporting = false }
                completion([])
                return
            }
            var results: [(name: String, service: String, secret: Data)] = []
            func readNext(index: Int) {
                guard index < count else {
                    Task { @MainActor in self.isExporting = false }
                    completion(results)
                    return
                }
                ble.readKeyEntry(cat: .otp, idx: UInt8(index)) { data in
                    if let data = data, data.count >= 92 {
                        let name = String(data: data[0..<30], encoding: .utf8)?
                            .trimmingCharacters(in: .controlCharacters)
                            .replacingOccurrences(of: "\0", with: "") ?? ""
                        let service = String(data: data[30..<60], encoding: .utf8)?
                            .trimmingCharacters(in: .controlCharacters)
                            .replacingOccurrences(of: "\0", with: "") ?? ""
                        let secret = data[60..<92]
                        let lastNonZero = secret.lastIndex(where: { $0 != 0 }) ?? secret.startIndex
                        let secretTrimmed = Data(secret[secret.startIndex...lastNonZero])
                        results.append((name: name, service: service, secret: secretTrimmed))
                    }
                    readNext(index: index + 1)
                }
            }
            readNext(index: 0)
        }
    }

    /// Import OTP entries serially (fingerprint auth first, then batch write)
    func importOTPEntries(_ entries: [(name: String, service: String, secret: Data)],
                          completion: @escaping (Int) -> Void) {
        isImporting = true
        importProgress = 0
        importTotal = entries.count
        startGateCountdown()
        let ble = bleManager
        // Verify fingerprint first (sets device-side gate cooldown for batch writes)
        ble.requestUnlock(timeout: 30.0) { [weak self] success in
            Task { @MainActor in
                guard let self = self else { return }
                self.dismissGate()
                guard success else {
                    self.isImporting = false
                    completion(0)
                    return
                }
                self.writeOTPEntriesAfterAuth(entries, ble: ble, completion: completion)
            }
        }
    }

    private func writeOTPEntriesAfterAuth(_ entries: [(name: String, service: String, secret: Data)],
                                           ble: BLEManager,
                                           completion: @escaping (Int) -> Void) {
        var successCount = 0
        func writeNext(index: Int) {
            guard index < entries.count else {
                Task { @MainActor in
                    self.isImporting = false
                    self.loadEntries(cat: .otp)
                }
                completion(successCount)
                return
            }
            Task { @MainActor in
                self.importProgress = index + 1
            }
            let e = entries[index]
            let nameData = Self.buildField(e.name, size: 30)
            let serviceData = Self.buildField(e.service, size: 30)
            var secretData = Data(count: 32)
            let len = min(e.secret.count, 32)
            secretData.replaceSubrange(0..<len, with: e.secret.prefix(len))
            let entryData = nameData + serviceData + secretData

            ble.writeKeyEntry(cat: .otp, idx: 0xFF, data: entryData) { success in
                if success { successCount += 1 }
                writeNext(index: index + 1)
            }
        }
        writeNext(index: 0)
    }

    // MARK: - Gate

    private func startGateCountdown() {
        gateCountdown = Self.gateTimeout
        showGateOverlay = true
        countdownTask?.cancel()
        countdownTask = Task { @MainActor [weak self] in
            while let self = self, self.gateCountdown > 0, self.showGateOverlay {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard self.showGateOverlay else { return }
                self.gateCountdown -= 1
            }
        }
    }

    func dismissGate() {
        showGateOverlay = false
        countdownTask?.cancel()
        isAdding = false
        isDeleting = false
    }

    // MARK: - Helpers

    private func clearError() {
        errorMessage = nil
        errorDismissTask?.cancel()
    }

    private func showError(_ message: String) {
        errorMessage = message
        errorDismissTask?.cancel()
        errorDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self = self else { return }
            self.errorMessage = nil
        }
    }

    /// Build zero-padded field data
    static func buildField(_ value: String, size: Int = 16) -> Data {
        var data = Data(count: size)
        let utf8 = Data(value.utf8).prefix(size)
        data.replaceSubrange(0..<utf8.count, with: utf8)
        return data
    }
}
