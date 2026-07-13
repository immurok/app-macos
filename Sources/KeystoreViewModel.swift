import Foundation
import Combine
import AuthInjectionKit

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
    private(set) var currentCat: KeystoreCategory?

    /// True when the currently displayed category has reached its firmware
    /// max entry count. UI should disable add / import in this state — the
    /// firmware silently rejects writes past the cap (commit returns -1).
    var isAtMaxCapacity: Bool {
        guard let cat = currentCat else { return false }
        return entries.count >= cat.maxEntries
    }

    /// Number of additional entries that can still be added to the current
    /// category. Returns 0 when at max.
    var remainingCapacity: Int {
        guard let cat = currentCat else { return 0 }
        return max(0, cat.maxEntries - entries.count)
    }
    private var gateObserver: Any?
    private var gateCancellable: AnyCancellable?
    private var loadingTimeoutTask: Task<Void, Never>?
    private var errorDismissTask: Task<Void, Never>?
    /// Exclusive device ownership while a storage-mutating / batch operation
    /// runs. Blocks PAM/CLI/SSH/QuickFill auth flows whose index-addressed
    /// reads would hit wrong entries mid swap-delete (and whose AUTH_REQUEST
    /// would stomp the keystore FP-gate state).
    private var maintenanceToken: DeviceActivityCoordinator.Token?

    init() {
        gateCancellable = gateController.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        gateObserver = NotificationCenter.default.addObserver(
            forName: BLEManager.fingerprintGateRequiredNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self,
                      // isLoading included so a cold-start API list fetch
                      // (which returns WAIT_FP per entry) can pop the FP
                      // sheet and let the user authorize the read.
                      self.isAdding || self.isDeleting || self.isImporting
                          || self.isExporting || self.isLoading
                else { return }
                self.gateController.onGateRequired()
            }
        }
    }

    deinit {
        if let obs = gateObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        // Backstop: never leak device ownership if the view model is torn
        // down mid-operation (e.g. settings window closed during a batch).
        if let token = maintenanceToken {
            DeviceActivityCoordinator.shared.end(token)
        }
    }

    // MARK: - Device ownership

    /// Take the exclusive device slot for a maintenance op. Returns false
    /// (with a user-visible error) when an auth flow — or another maintenance
    /// op — is already in flight.
    private func beginMaintenance() -> Bool {
        guard maintenanceToken == nil,
              let token = DeviceActivityCoordinator.shared.tryBegin(.keystoreMaintenance)
        else {
            showError("keys.busy.auth".localized)
            return false
        }
        maintenanceToken = token
        return true
    }

    private func endMaintenance() {
        if let token = maintenanceToken {
            DeviceActivityCoordinator.shared.end(token)
            maintenanceToken = nil
        }
    }

    // MARK: - Public

    func loadEntries(cat: KeystoreCategory) {
        if isLoading { return }

        let categoryChanged = currentCat != cat
        currentCat = cat
        clearError()

        // Phase 1: paint from cache immediately (if any). Switching tabs
        // becomes instant when a previous sync populated the cache.
        let cached = KeyNameCache.shared.entries(for: cat)
        if !cached.isEmpty {
            entries = cached.map { Entry(index: $0.index, name: $0.name, service: $0.service) }
                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        } else if categoryChanged {
            entries = []
        }

        // Phase 2: digest verify in the background. KeyNameCache.syncCategory
        // first does a 6-byte KEY_COUNT — if the firmware checksum matches the
        // cached digest, it returns without any KEY_READ. Only on miss does
        // it kick off the full N×KEY_READ chain.
        isLoading = true
        loadingProgress = 0
        loadingTotal = 0

        loadingTimeoutTask?.cancel()
        loadingTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard let self = self, self.isLoading else { return }
            self.isLoading = false
        }

        KeyNameCache.shared.syncCategory(cat) { [weak self] in
            Task { @MainActor in
                guard let self = self, self.currentCat == cat else { return }
                self.loadingTimeoutTask?.cancel()
                self.entries = KeyNameCache.shared.entries(for: cat)
                    .map { Entry(index: $0.index, name: $0.name, service: $0.service) }
                    .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

                // API names require FP gate (firmware refuses KEY_READ with
                // SEC_ERR_WAIT_FP unless AUTH or KEYSTORE cooldown is active).
                // Cold-start sync silently returns nil for every name, so the
                // cache stays incomplete (KeyNameCache.isCacheComplete=false).
                // Run AUTH_REQUEST to refresh AUTH cooldown then resync. The
                // existing FP-gate sheet pops via fingerprintGateRequiredNotification.
                if cat == .api && !KeyNameCache.shared.isCacheComplete(for: .api) {
                    self.unlockAndResyncAPI()
                    return  // isLoading stays true until retry completes
                }

                self.isLoading = false
            }
        }
    }

    /// Trigger AUTH_REQUEST to satisfy API KEY_READ FP gate, then resync.
    /// Called when the cold-start API list fetch came back incomplete.
    private func unlockAndResyncAPI() {
        bleManager.requestUnlock(timeout: 30.0) { [weak self] success in
            Task { @MainActor in
                guard let self = self, self.currentCat == .api else {
                    self?.isLoading = false
                    return
                }
                guard success else {
                    // User cancelled or FP gate timed out — leave list empty,
                    // user can re-trigger by switching tabs or refresh action.
                    self.isLoading = false
                    return
                }
                // AUTH cooldown is now active; fetch will succeed.
                KeyNameCache.shared.syncCategory(.api) {
                    Task { @MainActor in
                        guard self.currentCat == .api else {
                            self.isLoading = false
                            return
                        }
                        self.entries = KeyNameCache.shared.entries(for: .api)
                            .map { Entry(index: $0.index, name: $0.name, service: $0.service) }
                            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
                        self.isLoading = false
                    }
                }
            }
        }
    }

    /// Import an SSH ECDSA P-256 private key from a parsed SSHKeyImporter result.
    /// Builds the 112B SSH entry layout (name[16] + pubkey_LE[64] + privkey[32]),
    /// writes via writeKeyEntry idx=0xFF, then aligns SSHKeyCache + KeyNameCache
    /// digests with the firmware's new checksum. No full re-sync required.
    func importSSHKey(name: String, imported: SSHKeyImporter.ImportedKey,
                      completion: @escaping (Bool) -> Void) {
        guard beginMaintenance() else {
            completion(false)
            return
        }
        isAdding = true
        gateController.title = "keys.add".localized
        clearError()

        // uECC on the device is built with NATIVE_LITTLE_ENDIAN=1 — it expects
        // both the public key (x || y) and private scalar in little-endian
        // byte order. CryptoKit returns big-endian, so reverse both before
        // sending. (Earlier version of this method only reversed pubkey,
        // which produced a key pair the device couldn't sign with — pubkey
        // looked right to ssh-keygen but the privkey scalar was 32-bytes
        // backwards in flash, yielding signatures that didn't validate.)
        let pubkeyLE = bleManager.convertEndianness64(imported.publicKeyRaw)
        let privkeyLE = Data(imported.privateKeyRaw.reversed())

        // Build 112B entry: name[16] + pubkey_LE[64] + privkey_LE[32]
        var entryData = Data(count: 16)
        let nameBytes = Array(name.utf8.prefix(16))
        for (i, b) in nameBytes.enumerated() { entryData[i] = b }
        entryData.append(pubkeyLE)
        entryData.append(privkeyLE)

        // Diagnostic: log fingerprint of the parsed pair so user can verify
        // the entry that ends up on flash matches the source file. Also dumps
        // first/last 4B of pubkey/privkey for byte-order spot check.
        NSLog("SSH import: name=%@ fp=%@ pub_be_first=%@ priv_be_first=%@",
              name, imported.openSSHFingerprint,
              imported.publicKeyRaw.prefix(4).map { String(format: "%02x", $0) }.joined(),
              imported.privateKeyRaw.prefix(4).map { String(format: "%02x", $0) }.joined())

        bleManager.writeKeyEntry(cat: .ssh, idx: 0xFF, data: entryData) { [weak self] success in
            guard let self = self else { return }
            if !success {
                Task { @MainActor in
                    self.isAdding = false
                    self.endMaintenance()
                    if self.gateController.isPresented {
                        self.gateController.reportFailed()
                    } else {
                        self.showError("keys.add.failed".localized)
                    }
                    completion(false)
                }
                return
            }

            // Compute SSH pubkey blob + fingerprint for cache (BE pubkey from CryptoKit)
            let blob = SSHKeyCache.buildSSHPublicKeyBlob(publicKey: imported.publicKeyRaw)
            let fp = SSHKeyCache.computeFingerprint(blob: blob)

            // Align both caches with firmware's new digest
            self.bleManager.getKeyCountAndChecksum(cat: .ssh) { count, checksum in
                let newIdx = max(0, count - 1)
                SSHKeyCache.shared.applyAdd(SSHKeyCacheEntry(
                    index: newIdx, name: name, publicKeyBlob: blob, fingerprint: fp
                ))
                SSHKeyCache.shared.setChecksum(count: count, checksum: checksum)
                _ = KeyNameCache.shared.applyAdd(cat: .ssh, name: name, service: "")
                KeyNameCache.shared.setChecksum(cat: .ssh, count: count, checksum: checksum)
                Task { @MainActor in
                    self.isAdding = false
                    self.endMaintenance()
                    if self.gateController.isPresented {
                        self.gateController.reportSuccess()
                    }
                    self.entries = KeyNameCache.shared.entries(for: .ssh)
                        .map { Entry(index: $0.index, name: $0.name, service: $0.service) }
                        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
                    completion(true)
                }
            }
        }
    }

    func addEntry(cat: KeystoreCategory, data: Data, completion: @escaping (Bool) -> Void) {
        guard beginMaintenance() else {
            completion(false)
            return
        }
        isAdding = true
        gateController.title = "keys.add".localized
        clearError()

        // Parse name/service from the entry data (matches firmware layout).
        // For SSH we'd need to also derive pubkey blob — the existing
        // KEY_GENERATE flow handles that separately, so here we only cover
        // the cache-level name field. SSH "add via writeKeyEntry" is unusual
        // (manual import), full re-sync via SSHKeyCache.sync remains the
        // safe path for SSH content beyond name.
        let (parsedName, parsedService) = Self.parseNameAndService(cat: cat, data: data)

        bleManager.writeKeyEntry(cat: cat, idx: 0xFF, data: data) { [weak self] success in
            guard let self = self else { return }
            if success {
                // Append locally + fetch new firmware checksum to align cache.
                // Skips the previous loadEntries(cat:) full refetch.
                let newIdx = KeyNameCache.shared.applyAdd(cat: cat, name: parsedName,
                                                          service: parsedService)
                self.bleManager.getKeyCountAndChecksum(cat: cat) { count, checksum in
                    KeyNameCache.shared.setChecksum(cat: cat, count: count, checksum: checksum)
                    if cat == .ssh {
                        // SSH cache stores pubkey blobs; can't reconstruct without
                        // re-reading the entry. Fall back to full sync for SSH.
                        SSHKeyCache.shared.sync {
                            Task { @MainActor in self.finishAddUI(cat: cat, success: true, completion: completion) }
                        }
                    } else {
                        Task { @MainActor in self.finishAddUI(cat: cat, success: true, completion: completion) }
                    }
                }
                _ = newIdx  // currently unused; kept for future "select newly-added"
                return
            }
            // Failure
            Task { @MainActor in self.finishAddUI(cat: cat, success: false, completion: completion) }
        }
    }

    @MainActor
    private func finishAddUI(cat: KeystoreCategory, success: Bool, completion: @escaping (Bool) -> Void) {
        self.isAdding = false
        self.endMaintenance()
        if self.gateController.isPresented {
            success ? self.gateController.reportSuccess() : self.gateController.reportFailed()
        }
        if success {
            // Repaint from cache (already updated)
            self.entries = KeyNameCache.shared.entries(for: cat)
                .map { Entry(index: $0.index, name: $0.name, service: $0.service) }
                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        } else if !self.gateController.isPresented {
            self.showError("keys.add.failed".localized)
        }
        completion(success)
    }

    /// Parse name and service fields from a writeKeyEntry data blob, matching
    /// firmware's struct layout (immurok_keystore.h):
    ///   SSH: name[16] + pubkey[64] + privkey[32]
    ///   OTP: name[30] + service[30] + secret[32]
    ///   API: name[32] + key[128]
    private static func parseNameAndService(cat: KeystoreCategory, data: Data) -> (name: String, service: String) {
        let nameLen: Int
        let serviceRange: Range<Int>?
        switch cat {
        case .ssh: nameLen = 16; serviceRange = nil
        case .otp: nameLen = 30; serviceRange = 30..<60
        case .api: nameLen = 32; serviceRange = nil
        }
        guard data.count >= nameLen else { return ("", "") }
        let nameRaw = data.prefix(nameLen).prefix(while: { $0 != 0 })
        let name = String(data: nameRaw, encoding: .utf8) ?? ""
        var service = ""
        if let r = serviceRange, data.count >= r.upperBound {
            let serviceRaw = data.subdata(in: r).prefix(while: { $0 != 0 })
            service = String(data: serviceRaw, encoding: .utf8) ?? ""
        }
        return (name, service)
    }

    func updateEntry(cat: KeystoreCategory, idx: UInt8, name: String, service: String,
                     completion: @escaping (Bool) -> Void) {
        guard beginMaintenance() else {
            completion(false)
            return
        }
        isAdding = true
        gateController.title = "keys.add".localized
        clearError()

        // Build a minimal write payload that contains ONLY the editable
        // fields (name [+ service for OTP]). Firmware staging (1.2.8+)
        // preloads the existing entry into s_stage_buf before applying
        // chunked writes, so any bytes we don't send are preserved from
        // flash — this lets us rename API entries WITHOUT first reading
        // the full entry. The previous "read full → modify → write full"
        // flow was broken on FW 1.2.13+ for API: KEY_READ off>=32 requires
        // FP gate (secret region), so the read step would fail without a
        // recent AUTH cooldown.
        let payload: Data
        switch cat {
        case .ssh:
            payload = Self.buildField(name, size: 16)
        case .otp:
            payload = Self.buildField(name, size: 30) + Self.buildField(service, size: 30)
        case .api:
            payload = Self.buildField(name, size: 32)
        }

        bleManager.writeKeyEntry(cat: cat, idx: idx, data: payload) { [weak self] success in
            guard let self = self else { return }
            if success {
                // Local rename + fetch new checksum to align (skip refetch).
                KeyNameCache.shared.applyUpdate(cat: cat, index: Int(idx),
                                                name: name, service: service)
                self.bleManager.getKeyCountAndChecksum(cat: cat) { count, checksum in
                    KeyNameCache.shared.setChecksum(cat: cat, count: count, checksum: checksum)
                    Task { @MainActor in
                        self.isAdding = false
                        self.endMaintenance()
                        if self.gateController.isPresented {
                            self.gateController.reportSuccess()
                        }
                        if let i = self.entries.firstIndex(where: { $0.index == Int(idx) }) {
                            self.entries[i] = Entry(index: Int(idx), name: name, service: service)
                        }
                        completion(true)
                    }
                }
                return
            }
            Task { @MainActor in
                self.isAdding = false
                self.endMaintenance()
                if self.gateController.isPresented {
                    self.gateController.reportFailed()
                } else {
                    self.showError("keys.edit.failed".localized)
                }
                completion(false)
            }
        }
    }

    func deleteEntry(cat: KeystoreCategory, idx: UInt8) {
        guard beginMaintenance() else { return }
        isDeleting = true
        gateController.title = "keys.delete".localized
        clearError()

        bleManager.deleteKeyEntry(cat: cat, idx: idx) { [weak self] success in
            guard let self = self else { return }
            if success {
                // Mirror firmware's swap-delete locally + fetch new checksum.
                // Saves N-1 KEY_READs vs the old loadEntries(cat:) refetch.
                KeyNameCache.shared.applySwapDelete(cat: cat, deletedIdx: Int(idx))
                if cat == .ssh { SSHKeyCache.shared.applySwapDelete(deletedIdx: Int(idx)) }
                self.bleManager.getKeyCountAndChecksum(cat: cat) { count, checksum in
                    KeyNameCache.shared.setChecksum(cat: cat, count: count, checksum: checksum)
                    if cat == .ssh { SSHKeyCache.shared.setChecksum(count: count, checksum: checksum) }
                    Task { @MainActor in
                        self.isDeleting = false
                        self.endMaintenance()
                        if self.gateController.isPresented {
                            self.gateController.reportSuccess()
                        }
                        // Repaint local entries from the just-updated cache
                        self.entries = KeyNameCache.shared.entries(for: cat)
                            .map { Entry(index: $0.index, name: $0.name, service: $0.service) }
                            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
                    }
                }
                return
            }
            // Failure path
            Task { @MainActor in
                self.isDeleting = false
                self.endMaintenance()
                if self.gateController.isPresented {
                    self.gateController.reportFailed()
                } else {
                    self.showError("keys.delete.failed".localized)
                }
            }
        }
    }

    func deleteEntries(cat: KeystoreCategory, indices: [UInt8], completion: @escaping () -> Void) {
        guard beginMaintenance() else {
            completion()
            return
        }
        isDeleting = true
        deleteProgress = 0
        deleteTotal = indices.count
        gateController.title = "keys.delete".localized
        clearError()

        deleteEntriesSequentially(cat: cat, indices: indices, completion: completion)
    }

    private func deleteEntriesSequentially(cat: KeystoreCategory, indices: [UInt8], completion: @escaping () -> Void) {
        // Descending order so each delete is either "delete last" (no swap) or
        // a swap from the current max — both cases are correctly mirrored by
        // applySwapDelete since it always uses the latest cached count.
        let sorted = indices.sorted(by: >)
        func deleteNext(i: Int) {
            guard i < sorted.count else {
                // Batch done: apply final checksum once (firmware reports new
                // digest after all deletes). Avoids N KEY_READ chain vs the
                // old loadEntries(cat:) approach.
                self.bleManager.getKeyCountAndChecksum(cat: cat) { count, checksum in
                    KeyNameCache.shared.setChecksum(cat: cat, count: count, checksum: checksum)
                    if cat == .ssh { SSHKeyCache.shared.setChecksum(count: count, checksum: checksum) }
                    Task { @MainActor in
                        self.isDeleting = false
                        self.gateController.reset()
                        self.deleteProgress = 0
                        self.deleteTotal = 0
                        // Repaint from cache (already swap-updated entry-by-entry)
                        self.entries = KeyNameCache.shared.entries(for: cat)
                            .map { Entry(index: $0.index, name: $0.name, service: $0.service) }
                            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
                        // Release device ownership before completion so a
                        // follow-up operation can immediately re-acquire.
                        self.endMaintenance()
                        completion()
                    }
                }
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
                if success {
                    KeyNameCache.shared.applySwapDelete(cat: cat, deletedIdx: Int(sorted[i]))
                    if cat == .ssh {
                        SSHKeyCache.shared.applySwapDelete(deletedIdx: Int(sorted[i]))
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
        guard beginMaintenance() else {
            completion([])
            return
        }
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
                    self.endMaintenance()
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
                Task { @MainActor in
                    self?.isExporting = false
                    self?.endMaintenance()
                    completion([])
                }
                return
            }
            var results: [(name: String, service: String, secret: Data)] = []
            func readNext(index: Int) {
                guard index < count else {
                    Task { @MainActor in
                        self.isExporting = false
                        self.endMaintenance()
                        completion(results)
                    }
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
        guard beginMaintenance() else {
            completion(0)
            return
        }
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
                // SwiftUI render race guard: ensure final 128/128 paints
                // before isImporting=false hides the progress bar.
                Task { @MainActor in
                    self.importProgress = self.importTotal
                }
                // Batch done — fetch new firmware checksum once to align cache
                // (each entry has been applyAdd'd locally below).
                ble.getKeyCountAndChecksum(cat: .otp) { count, checksum in
                    KeyNameCache.shared.setChecksum(cat: .otp, count: count, checksum: checksum)
                    // Device work is done — release ownership now, before the
                    // 0.3s UI-repaint delay below.
                    Task { @MainActor [weak self] in
                        self?.endMaintenance()
                        completion(successCount)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        Task { @MainActor in
                            guard let self = self else { return }
                            self.isImporting = false
                            self.gateController.reset()
                            // Repaint from cache (already populated by applyAdd)
                            self.entries = KeyNameCache.shared.entries(for: .otp)
                                .map { Entry(index: $0.index, name: $0.name, service: $0.service) }
                                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
                        }
                    }
                }
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
                if success {
                    successCount += 1
                    // Append to cache locally — saves one full refetch at end.
                    _ = KeyNameCache.shared.applyAdd(cat: .otp, name: e.name,
                                                     service: e.service)
                }
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
