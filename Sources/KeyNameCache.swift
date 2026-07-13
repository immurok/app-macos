import Foundation
import AuthInjectionKit

/// 密钥名称缓存。每个分类按 (count, checksum) 摘要标识 — 同步时先问固件
/// 拿摘要，与缓存对比相同就直接用缓存，不读列表；不同才走全量 BLE 读取。
/// 缓存持久化到 ~/.immurok/key_name_cache.json，App 重启后从盘恢复。
class KeyNameCache {

    static let shared = KeyNameCache()

    struct Entry: Codable {
        let index: Int
        let name: String
        let service: String  // OTP service name; empty for SSH/API
        let categoryRaw: UInt8  // KeystoreCategory.rawValue (Codable hop)

        var category: KeystoreCategory {
            KeystoreCategory(rawValue: categoryRaw) ?? .otp
        }

        init(index: Int, name: String, service: String, category: KeystoreCategory) {
            self.index = index
            self.name = name
            self.service = service
            self.categoryRaw = category.rawValue
        }
    }

    private struct CachedCategory: Codable {
        var entries: [Entry]
        var count: Int
        var checksum: UInt32
    }

    /// On-disk format: { "0": CachedCategory, "1": ..., "2": ... }
    /// Keyed by category rawValue as String (Dictionary<UInt8, _> isn't JSON-friendly).
    private var cache: [UInt8: CachedCategory] = [:]
    private let lock = NSLock()
    private let cacheURL: URL
    private(set) var isSynced = false

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".immurok")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appendingPathComponent("key_name_cache.json")
        loadFromDisk()
    }

    // MARK: - Public API

    /// All cached entries across categories (for QuickFill aggregate views).
    var entries: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return cache.values.flatMap { $0.entries }
    }

    /// Cached entries for a single category.
    func entries(for cat: KeystoreCategory) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return cache[cat.rawValue]?.entries ?? []
    }

    /// True when the cached entries for a category fully match the last
    /// observed device state (count and checksum). False if a previous
    /// fetch was incomplete (e.g. API KEY_READ rejected by FP gate during
    /// cold start) — UI can use this to gate a follow-up AUTH_REQUEST +
    /// retry sync.
    func isCacheComplete(for cat: KeystoreCategory) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let c = cache[cat.rawValue] else { return false }
        // count==0 is trivially complete (nothing to fetch).
        if c.count == 0 { return true }
        return c.entries.count == c.count && c.checksum != 0
    }

    /// Sync one category. First fetches (count, checksum) — fast 6-byte BLE
    /// round-trip — and skips the full list read when the digest matches cache.
    func syncCategory(_ cat: KeystoreCategory, completion: @escaping () -> Void) {
        let ble = BLEManager.shared
        guard ble.deviceState.isConnected else {
            completion()
            return
        }

        // A keystore maintenance op (batch delete / import) is mutating
        // entries right now: the digest is guaranteed to mismatch mid-batch
        // and a full refetch would interleave with the mutation commands and
        // corrupt the cache (which then gets digest-stamped as valid at
        // batch end). Serve current cache; the owner realigns the digest
        // when it finishes.
        if DeviceActivityCoordinator.shared.currentActivity == .keystoreMaintenance {
            NSLog("KeyNameCache[%d]: maintenance in flight, skip sync", cat.rawValue)
            completion()
            return
        }

        ble.getKeyCountAndChecksum(cat: cat) { [weak self] count, checksum in
            guard let self = self else { completion(); return }

            // Cache hit: device digest matches what we have on disk → no list read.
            // Skip only when checksum is non-zero AND matches AND count matches.
            // checksum == 0 from old firmware OR truly empty category (0 entries) →
            // require count match for confidence.
            self.lock.lock()
            let cached = self.cache[cat.rawValue]
            self.lock.unlock()

            if let cached = cached, cached.count == count {
                // For non-empty categories: require checksum match.
                // For empty (count=0): trivially matches (no data to compare).
                let bothEmpty = (count == 0)
                let bothNonEmpty = (count > 0 && checksum != 0 && cached.checksum == checksum)
                if bothEmpty || bothNonEmpty {
                    NSLog("KeyNameCache[%d]: cache hit (count=%d cs=0x%08x), skip read",
                          cat.rawValue, count, checksum)
                    completion()
                    return
                }
            }

            // Cache miss → full BLE list read
            NSLog("KeyNameCache[%d]: cache miss (count=%d cs=0x%08x), fetching",
                  cat.rawValue, count, checksum)
            self.fetchAndStore(cat: cat, count: count, checksum: checksum, completion: completion)
        }
    }

    /// Sync all non-SSH categories. SSH is handled by SSHKeyCache (similar logic).
    func syncNonSSH(completion: @escaping () -> Void) {
        syncCategories([.api, .otp], completion: completion)
    }

    /// Sync all three categories.
    func sync(completion: @escaping () -> Void) {
        syncCategories([.ssh, .api, .otp], completion: completion)
    }

    private func syncCategories(_ categories: [KeystoreCategory],
                                 completion: @escaping () -> Void) {
        func next(_ i: Int) {
            guard i < categories.count else {
                self.isSynced = true
                completion()
                return
            }
            syncCategory(categories[i]) { next(i + 1) }
        }
        next(0)
    }

    // MARK: - Mutations

    /// Update one entry's name/service in cache. Caller must follow with a
    /// setChecksum() call carrying the firmware's new digest after the BLE
    /// op completes. No effect if the index doesn't exist (use applyAdd).
    func applyUpdate(cat: KeystoreCategory, index: Int, name: String, service: String) {
        lock.lock()
        if var cached = cache[cat.rawValue],
           let i = cached.entries.firstIndex(where: { $0.index == index }) {
            cached.entries[i] = Entry(index: index, name: name, service: service, category: cat)
            cached.checksum = 0  // pending: caller calls setChecksum
            cache[cat.rawValue] = cached
        }
        lock.unlock()
        saveToDisk()
    }

    /// Append a newly-added entry (firmware allocates idx = old count and
    /// increments). Caller must follow with setChecksum after the BLE op
    /// reports the new firmware digest.
    func applyAdd(cat: KeystoreCategory, name: String, service: String) -> Int {
        lock.lock()
        var cached = cache[cat.rawValue] ?? CachedCategory(entries: [], count: 0, checksum: 0)
        let newIdx = cached.count
        cached.entries.append(Entry(index: newIdx, name: name, service: service, category: cat))
        cached.count = cached.entries.count
        cached.checksum = 0
        cache[cat.rawValue] = cached
        lock.unlock()
        saveToDisk()
        return newIdx
    }

    /// Legacy alias kept for SSHKeyCache replay path. Same as applyUpdate but
    /// inserts when index is missing — used when external code already knows
    /// the index assigned by firmware.
    func updateEntry(cat: KeystoreCategory, index: Int, name: String, service: String) {
        lock.lock()
        var cached = cache[cat.rawValue] ?? CachedCategory(entries: [], count: 0, checksum: 0)
        if let i = cached.entries.firstIndex(where: { $0.index == index }) {
            cached.entries[i] = Entry(index: index, name: name, service: service, category: cat)
        } else {
            cached.entries.append(Entry(index: index, name: name, service: service, category: cat))
            cached.count = cached.entries.count
        }
        cached.checksum = 0
        cache[cat.rawValue] = cached
        lock.unlock()
        saveToDisk()
    }

    func removeEntries(cat: KeystoreCategory, indices: Set<Int>) {
        lock.lock()
        if var cached = cache[cat.rawValue] {
            cached.entries.removeAll { indices.contains($0.index) }
            cached.count = cached.entries.count
            cached.checksum = 0
            cache[cat.rawValue] = cached
        }
        lock.unlock()
        saveToDisk()
    }

    /// Mirror the firmware's swap-delete in cache: remove the entry at
    /// `deletedIdx`, then re-label whichever cached entry held the previous
    /// max index (= count - 1) to occupy `deletedIdx`. After this the local
    /// state matches what the device wrote to flash. Caller MUST follow up
    /// with `setChecksum` carrying the firmware's new digest so the cache
    /// is valid on next sync.
    func applySwapDelete(cat: KeystoreCategory, deletedIdx: Int) {
        lock.lock()
        guard var cached = cache[cat.rawValue], !cached.entries.isEmpty else {
            lock.unlock()
            return
        }
        let oldMaxIdx = cached.count - 1  // firmware indices are always 0..count-1
        cached.entries.removeAll { $0.index == deletedIdx }
        if deletedIdx != oldMaxIdx {
            if let i = cached.entries.firstIndex(where: { $0.index == oldMaxIdx }) {
                let e = cached.entries[i]
                cached.entries[i] = Entry(index: deletedIdx, name: e.name,
                                          service: e.service, category: cat)
            }
        }
        cached.count = cached.entries.count
        cached.checksum = 0  // pending: caller must call setChecksum
        cache[cat.rawValue] = cached
        lock.unlock()
        saveToDisk()
    }

    /// Persist the firmware-reported checksum after a local mutation. If the
    /// reported count diverges from cached count the cache is marked stale
    /// (checksum=0) so the next sync will refetch.
    func setChecksum(cat: KeystoreCategory, count: Int, checksum: UInt32) {
        lock.lock()
        if var cached = cache[cat.rawValue] {
            if cached.count == count {
                cached.checksum = checksum
            } else {
                NSLog("KeyNameCache[%d]: count drift after mutation (cached=%d device=%d), invalidating",
                      cat.rawValue, cached.count, count)
                cached.checksum = 0
            }
            cache[cat.rawValue] = cached
        }
        lock.unlock()
        saveToDisk()
    }

    /// Replace cache for a category with externally-fetched data (used by SSH
    /// where SSHKeyCache already did the BLE work). Pass a non-zero checksum
    /// to keep the cache digest-valid; default 0 forces refetch on next sync.
    func replaceCategory(_ cat: KeystoreCategory, with newEntries: [Entry],
                         checksum: UInt32 = 0) {
        lock.lock()
        cache[cat.rawValue] = CachedCategory(
            entries: newEntries, count: newEntries.count, checksum: checksum
        )
        lock.unlock()
        saveToDisk()
    }

    func clear() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
        saveToDisk()
        isSynced = false
    }

    // MARK: - Internal: fetch & persist

    private func fetchAndStore(cat: KeystoreCategory, count: Int, checksum: UInt32,
                                completion: @escaping () -> Void) {
        let ble = BLEManager.shared

        let store: ([Entry]) -> Void = { [weak self] entries in
            guard let self = self else { completion(); return }

            // Sanity check: device says count=N but we got M < N entries.
            // Most common trigger: API KEY_READ returns WAIT_FP because no
            // FP gate cooldown is active (cold App start, never authed).
            // Without this check, fetchAndStore would persist {entries=[],
            // count=N, checksum=cs}, and the NEXT syncCategory hits the
            // checksum match → permanent empty list (the cache is poisoned
            // by an incomplete fetch).
            //
            // Mitigation: store whatever we managed to read but force
            // checksum=0 so the next sync re-fetches. Also fire the gate
            // notification — observers in *AddsState UI (KeystoreVM) will
            // pop the FP sheet, the user verifies, AUTH cooldown lights up,
            // and the subsequent sync succeeds. KeystoreVM's observer also
            // listens during isLoading so first-tab-open works.
            let incomplete = entries.count != count
            self.lock.lock()
            self.cache[cat.rawValue] = CachedCategory(
                entries: entries,
                count: count,
                checksum: incomplete ? 0 : checksum
            )
            self.lock.unlock()
            self.saveToDisk()

            if incomplete {
                NSLog("KeyNameCache[%d]: incomplete fetch (got=%d, dev=%d) — keeping cache invalid",
                      cat.rawValue, entries.count, count)
                if cat == .api {
                    // API reads are FP-gated; an incomplete fetch is almost
                    // certainly WAIT_FP fallout. Wake any active gate UI.
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: BLEManager.fingerprintGateRequiredNotification,
                            object: nil
                        )
                    }
                }
            }
            completion()
        }

        if cat == .otp {
            ble.getKeyEntryNamesAndService(cat: cat) { results in
                store(results.map {
                    Entry(index: $0.index, name: $0.name, service: $0.service, category: cat)
                })
            }
        } else {
            ble.getKeyEntryNames(cat: cat) { names in
                store(names.map {
                    Entry(index: $0.index, name: $0.name, service: "", category: cat)
                })
            }
        }
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        do {
            let data = try Data(contentsOf: cacheURL)
            // Stored as [String: CachedCategory] for JSON friendliness
            let raw = try JSONDecoder().decode([String: CachedCategory].self, from: data)
            lock.lock()
            cache = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in
                UInt8(k).map { ($0, v) }
            })
            lock.unlock()
            NSLog("KeyNameCache: loaded %d categories from disk", cache.count)
        } catch {
            NSLog("KeyNameCache: load failed: %@", error.localizedDescription)
        }
    }

    private func saveToDisk() {
        lock.lock()
        let snapshot = Dictionary(uniqueKeysWithValues: cache.map { (String($0.key), $0.value) })
        lock.unlock()
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            NSLog("KeyNameCache: save failed: %@", error.localizedDescription)
        }
    }
}
