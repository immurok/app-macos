import Foundation
import Combine

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
    @Published var errorMessage: String?

    var gateController = FingerprintGateController()

    private let bleManager = BLEManager.shared
    private var currentCat: KeystoreCategory?
    private var gateObserver: Any?
    private var gateCancellable: AnyCancellable?
    private var loadingTimeoutTask: Task<Void, Never>?
    private var errorDismissTask: Task<Void, Never>?

    init() {
        gateCancellable = gateController.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        gateObserver = NotificationCenter.default.addObserver(
            forName: BLEManager.fingerprintGateRequiredNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self,
                      self.isAdding || self.isDeleting || self.isImporting || self.isExporting
                else { return }
                self.gateController.onGateRequired()
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

    func addEntry(cat: KeystoreCategory, data: Data, completion: @escaping (Bool) -> Void) {
        isAdding = true
        gateController.title = "keys.add".localized
        clearError()

        bleManager.writeKeyEntry(cat: cat, idx: 0xFF, data: data) { [weak self] success in
            Task { @MainActor in
                guard let self = self else { return }
                self.isAdding = false
                if self.gateController.isPresented {
                    success ? self.gateController.reportSuccess() : self.gateController.reportFailed()
                }
                if success {
                    self.loadEntries(cat: cat)
                } else if !self.gateController.isPresented {
                    self.showError("keys.add.failed".localized)
                }
                completion(success)
            }
        }
    }

    func updateEntry(cat: KeystoreCategory, idx: UInt8, name: String, service: String,
                     completion: @escaping (Bool) -> Void) {
        isAdding = true
        gateController.title = "keys.add".localized
        clearError()

        bleManager.readKeyEntry(cat: cat, idx: idx) { [weak self] data in
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
                    if self.gateController.isPresented {
                        success ? self.gateController.reportSuccess() : self.gateController.reportFailed()
                    }
                    if success {
                        if let i = self.entries.firstIndex(where: { $0.index == Int(idx) }) {
                            self.entries[i] = Entry(index: Int(idx), name: name, service: service)
                        }
                        KeyNameCache.shared.updateEntry(cat: cat, index: Int(idx), name: name, service: service)
                    } else if !self.gateController.isPresented {
                        self.showError("keys.edit.failed".localized)
                    }
                    completion(success)
                }
            }
        }
    }

    func deleteEntry(cat: KeystoreCategory, idx: UInt8) {
        isDeleting = true
        gateController.title = "keys.delete".localized
        clearError()

        bleManager.deleteKeyEntry(cat: cat, idx: idx) { [weak self] success in
            Task { @MainActor in
                guard let self = self else { return }
                self.isDeleting = false
                if self.gateController.isPresented {
                    success ? self.gateController.reportSuccess() : self.gateController.reportFailed()
                }
                if success {
                    self.entries.removeAll { $0.index == Int(idx) }
                    self.loadEntries(cat: cat)
                } else if !self.gateController.isPresented {
                    self.showError("keys.delete.failed".localized)
                }
            }
        }
    }

    func deleteEntries(cat: KeystoreCategory, indices: [UInt8], completion: @escaping () -> Void) {
        isDeleting = true
        deleteProgress = 0
        deleteTotal = indices.count
        gateController.title = "keys.delete".localized
        clearError()

        deleteEntriesSequentially(cat: cat, indices: indices, completion: completion)
    }

    private func deleteEntriesSequentially(cat: KeystoreCategory, indices: [UInt8], completion: @escaping () -> Void) {
        let sorted = indices.sorted(by: >)
        func deleteNext(i: Int) {
            guard i < sorted.count else {
                Task { @MainActor in
                    let deletedSet = Set(indices.map { Int($0) })
                    self.entries.removeAll { deletedSet.contains($0.index) }
                    KeyNameCache.shared.removeEntries(cat: cat, indices: deletedSet)
                    self.isDeleting = false
                    self.gateController.reset()
                    self.deleteProgress = 0
                    self.deleteTotal = 0
                }
                completion()
                return
            }
            Task { @MainActor in
                self.deleteProgress = i + 1
            }
            bleManager.deleteKeyEntry(cat: cat, idx: sorted[i]) { [weak self] success in
                Task { @MainActor in
                    if let self = self, self.gateController.isPresented {
                        success ? self.gateController.reportSuccess() : self.gateController.reportFailed()
                    }
                }
                deleteNext(i: i + 1)
            }
        }
        deleteNext(i: 0)
    }

    func refresh() {
        guard let cat = currentCat else { return }
        loadEntries(cat: cat)
    }

    /// Load SSH entries from SSHKeyCache (no BLE commands needed)
    func loadFromSSHKeyCache() {
        currentCat = .ssh
        entries = SSHKeyCache.shared.entries.map { Entry(index: $0.index, name: $0.name, service: "") }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        isLoading = false
    }

    // MARK: - OTP Import/Export

    /// Read all OTP entries with full 64B data (name + service + secret)
    /// Requires fingerprint verification first (sets device-side gate cooldown for batch reads)
    func readAllOTPEntries(completion: @escaping ([(name: String, service: String, secret: Data)]) -> Void) {
        isExporting = true
        gateController.present(title: "keys.export".localized)
        let ble = bleManager
        ble.requestUnlock(timeout: 30.0) { [weak self] success in
            Task { @MainActor in
                guard let self = self else { return }
                if success {
                    self.gateController.reportSuccess()
                } else {
                    self.gateController.reportFailed()
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

    /// Import OTP entries serially (KEY_COMMIT has its own FP gate; rolling cooldown covers batch)
    func importOTPEntries(_ entries: [(name: String, service: String, secret: Data)],
                          completion: @escaping (Int) -> Void) {
        isImporting = true
        importProgress = 0
        importTotal = entries.count
        gateController.title = "keys.import".localized

        writeOTPEntriesSequentially(entries, completion: completion)
    }

    private func writeOTPEntriesSequentially(_ entries: [(name: String, service: String, secret: Data)],
                                              completion: @escaping (Int) -> Void) {
        let ble = bleManager
        var successCount = 0
        func writeNext(index: Int) {
            guard index < entries.count else {
                Task { @MainActor in
                    self.isImporting = false
                    self.gateController.reset()
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

            ble.writeKeyEntry(cat: .otp, idx: 0xFF, data: entryData) { [weak self] success in
                Task { @MainActor in
                    if let self = self, self.gateController.isPresented {
                        success ? self.gateController.reportSuccess() : self.gateController.reportFailed()
                    }
                }
                if success { successCount += 1 }
                writeNext(index: index + 1)
            }
        }
        writeNext(index: 0)
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
