import Foundation
import Combine
import AuthInjectionKit

/// Automation 条目的单例存储。元数据落 ~/.immurok/automation.json（明文），
/// 密码落 Keychain（per-item service）。首次运行从旧 UserDefaults 开关迁移内置项。
final class AutomationStore: ObservableObject {
    static let shared = AutomationStore()
    @Published private(set) var items: [AutomationItem] = []
    private let lock = NSLock()
    private let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".immurok")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("automation.json")
    }()

    private init() { load() }

    // MARK: 加载 / 迁移
    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([AutomationItem].self, from: data),
           !decoded.isEmpty {
            // 内置项身份只读：每次加载用 builtinDefaults 刷新（bundleIDs 等随版本更新），
            // 只保留用户态（id/enabled）。有变化才回写。
            items = AutomationItem.refreshingBuiltinIdentity(decoded)
            if items != decoded { persist() }
            return
        }
        items = migrateFromLegacyDefaults()
        persist()
    }

    /// 首次运行：内置项 enabled 取旧 UserDefaults 开关值；密码沿用旧 Keychain service（无需搬动）。
    private func migrateFromLegacyDefaults() -> [AutomationItem] {
        let d = UserDefaults.standard
        let map: [String: String] = [
            "appstore": "immurok.appStoreFillEnabled",
            "passwords": "immurok.passwordsFillEnabled",
            "1password": "immurok.onePasswordUnlockEnabled",
            "bitwarden": "immurok.bitwardenUnlockEnabled",
        ]
        return AutomationItem.builtinDefaults().map { item in
            var m = item
            if let key = item.builtinKey, let flag = map[key] { m.enabled = d.bool(forKey: flag) }
            return m
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder.pretty.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: CRUD
    func add(_ item: AutomationItem) {
        lock.lock(); items.append(item); persist(); lock.unlock()
    }
    func update(_ item: AutomationItem) {
        lock.lock()
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item; persist() }
        lock.unlock()
    }
    func remove(id: UUID) {
        lock.lock()
        var removedService: String?
        if let i = items.firstIndex(where: { $0.id == id }), items[i].builtinKey == nil {
            removedService = items[i].secretService
            items.remove(at: i); persist()
        }
        lock.unlock()
        if let svc = removedService { ImmurokSecurity.shared.deleteSecret(service: svc) }
    }
    func setEnabled(_ enabled: Bool, id: UUID) {
        lock.lock()
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].enabled = enabled; persist() }
        lock.unlock()
    }
    func enabledItems() -> [AutomationItem] {
        lock.lock(); defer { lock.unlock() }
        return items.filter { $0.enabled }
    }

    // MARK: 密码（Keychain）
    func setPassword(_ pw: String, for item: AutomationItem) {
        ImmurokSecurity.shared.saveSecret(pw, service: item.secretService)
    }
    func hasPassword(_ item: AutomationItem) -> Bool {
        ImmurokSecurity.shared.hasSecret(service: item.secretService)
    }
    func clearPassword(_ item: AutomationItem) {
        ImmurokSecurity.shared.deleteSecret(service: item.secretService)
    }

    // MARK: 导入导出
    func exportPayload() -> AutomationExportPayload {
        lock.lock(); let snapshot = items; lock.unlock()
        var secrets: [String: String] = [:]
        for item in snapshot {
            if let pw = ImmurokSecurity.shared.loadSecret(service: item.secretService) {
                secrets[item.secretService] = pw
            }
        }
        return AutomationExportPayload(items: snapshot, secrets: secrets)
    }

    /// 合并：内置项按 builtinKey 覆盖 enabled；自定义项按 id upsert。仅收 isValid 的自定义项。
    func importPayload(_ payload: AutomationExportPayload) {
        lock.lock()
        for incoming in payload.items {
            if let key = incoming.builtinKey {
                if let i = items.firstIndex(where: { $0.builtinKey == key }) { items[i].enabled = incoming.enabled }
            } else {
                guard incoming.isValid else { continue }
                if let i = items.firstIndex(where: { $0.id == incoming.id }) { items[i] = incoming }
                else { items.append(incoming) }
            }
        }
        persist()
        let all = items
        lock.unlock()
        // 写密码（在锁外，Keychain 调用可能较慢）
        for item in all {
            if let pw = payload.secrets[item.secretService] {
                ImmurokSecurity.shared.saveSecret(pw, service: item.secretService)
            }
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
}
