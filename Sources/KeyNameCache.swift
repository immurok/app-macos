import Foundation

/// 密钥名称缓存，设备连接时同步，QuickFill 直接读取
class KeyNameCache {

    static let shared = KeyNameCache()

    struct Entry {
        let index: Int
        let name: String
        let service: String  // OTP service name; empty for SSH/API
        let category: KeystoreCategory
    }

    private var _entries: [Entry] = []
    private let lock = NSLock()
    private(set) var isSynced = false

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return _entries
    }

    /// 同步单个分类（替换该分类的缓存，保留其他分类）
    func syncCategory(_ cat: KeystoreCategory, completion: @escaping () -> Void) {
        let ble = BLEManager.shared
        guard ble.deviceState.isConnected else {
            completion()
            return
        }

        if cat == .otp {
            ble.getKeyEntryNamesAndService(cat: cat) { [self] results in
                let catEntries = results.map {
                    Entry(index: $0.index, name: $0.name, service: $0.service, category: cat)
                }
                self.replaceCategory(cat, with: catEntries)
                completion()
            }
        } else {
            ble.getKeyEntryNames(cat: cat) { [self] names in
                let catEntries = names.map {
                    Entry(index: $0.index, name: $0.name, service: "", category: cat)
                }
                self.replaceCategory(cat, with: catEntries)
                completion()
            }
        }
    }

    /// 同步所有分类（设备连接后调用）
    func sync(completion: @escaping () -> Void) {
        let categories: [KeystoreCategory] = [.ssh, .api, .otp]
        syncCategories(categories, completion: completion)
    }

    /// 同步非 SSH 分类（SSH 由 SSHKeyCache 填充，避免重复 BLE 读取）
    func syncNonSSH(completion: @escaping () -> Void) {
        syncCategories([.api, .otp], completion: completion)
    }

    private func syncCategories(_ categories: [KeystoreCategory], completion: @escaping () -> Void) {
        func syncNext(index: Int) {
            guard index < categories.count else {
                self.isSynced = true
                completion()
                return
            }
            syncCategory(categories[index]) {
                syncNext(index: index + 1)
            }
        }
        syncNext(index: 0)
    }

    func updateEntry(cat: KeystoreCategory, index: Int, name: String, service: String) {
        lock.lock()
        if let i = _entries.firstIndex(where: { $0.category == cat && $0.index == index }) {
            _entries[i] = Entry(index: index, name: name, service: service, category: cat)
        }
        lock.unlock()
    }

    func removeEntries(cat: KeystoreCategory, indices: Set<Int>) {
        lock.lock()
        _entries.removeAll { $0.category == cat && indices.contains($0.index) }
        lock.unlock()
    }

    func clear() {
        lock.lock()
        _entries = []
        lock.unlock()
        isSynced = false
    }

    /// 直接替换某分类的缓存（用已读到的数据，无需再走 BLE）
    func replaceCategory(_ cat: KeystoreCategory, with newEntries: [Entry]) {
        lock.lock()
        _entries.removeAll { $0.category == cat }
        _entries.append(contentsOf: newEntries)
        lock.unlock()
    }
}
