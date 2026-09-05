import Foundation

public enum TargetKind: String, Codable { case app, browserExtension }

public enum SubmitStrategy: String, Codable {
    case generic        // Apple 原生框：AXDefaultButton / 几何主按钮 / Return
    case rightArrow     // 1Password：密码框右侧同行箭头，合成鼠标点击
    case belowButton    // Bitwarden：密码框正下方整宽按钮，合成鼠标点击
    case appStoreWizard // App Store：Install→等密码页→注入→提交
}

/// 一条用户可配置（或内置）的密码注入条目。密码不在此结构内，单独存 Keychain（见 secretService）。
public struct AutomationItem: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    /// 内置预设标识；nil = 用户自定义。内置项不可删除、可禁用、身份只读。
    public var builtinKey: String?
    public var targetKind: TargetKind
    public var bundleIDs: [String]
    public var signing: SigningRequirement
    public var extensionOrigin: String?
    public var urlFragment: String?
    public var fieldAXIdentifier: String?
    public var submitStrategy: SubmitStrategy

    public init(id: UUID, name: String, enabled: Bool, builtinKey: String?,
                targetKind: TargetKind, bundleIDs: [String], signing: SigningRequirement,
                extensionOrigin: String?, urlFragment: String?,
                fieldAXIdentifier: String?, submitStrategy: SubmitStrategy) {
        self.id = id; self.name = name; self.enabled = enabled; self.builtinKey = builtinKey
        self.targetKind = targetKind; self.bundleIDs = bundleIDs; self.signing = signing
        self.extensionOrigin = extensionOrigin; self.urlFragment = urlFragment
        self.fieldAXIdentifier = fieldAXIdentifier; self.submitStrategy = submitStrategy
    }

    /// 密码所在 Keychain service：内置沿用旧 service（不丢已配置密码），自定义按 uuid。
    public var secretService: String {
        switch builtinKey {
        case "appstore":   return "com.immurok.appleid-password"
        case "passwords":  return "com.immurok.password"
        case "1password":  return "com.immurok.onepassword-password"
        case "bitwarden":  return "com.immurok.bitwarden-password"
        default:           return "com.immurok.automation.\(id.uuidString)"
        }
    }

    public func matches(bundleID: String) -> Bool { bundleIDs.contains(bundleID) }

    /// bundleIDs 非空且每个都能通过身份校验（防 requirement 串注入）。
    public var isValid: Bool {
        guard !bundleIDs.isEmpty else { return false }
        return bundleIDs.allSatisfy { signing.validatedRequirementString(bundleID: $0) != nil }
    }

    /// 用 builtinDefaults 刷新存盘条目里内置项的身份字段（bundleIDs/signing/策略等），
    /// 保留用户态（id、enabled）；自定义项原样保留；存盘缺失的内置项补上（enabled=false）。
    /// 内置项身份本就只读，这保证升级后新覆盖面（如 Passwords 加 Safari）对老安装生效。
    public static func refreshingBuiltinIdentity(_ stored: [AutomationItem]) -> [AutomationItem] {
        let defaults = Dictionary(uniqueKeysWithValues: builtinDefaults().map { ($0.builtinKey!, $0) })
        var seen = Set<String>()
        var result: [AutomationItem] = stored.map { item in
            guard let key = item.builtinKey, let fresh = defaults[key] else { return item }
            seen.insert(key)
            var m = fresh
            m.id = item.id
            m.enabled = item.enabled
            return m
        }
        for item in builtinDefaults() where !seen.contains(item.builtinKey!) {
            result.append(item)
        }
        return result
    }

    /// 空白自定义条目（供"添加"入口预填）。
    public static func newCustom() -> AutomationItem {
        AutomationItem(id: UUID(), name: "", enabled: true, builtinKey: nil,
            targetKind: .app, bundleIDs: [], signing: .applePlatform,
            extensionOrigin: nil, urlFragment: nil, fieldAXIdentifier: nil, submitStrategy: .generic)
    }

    /// 4 个内置条目（enabled 默认 false，迁移时按旧开关覆盖）。
    public static func builtinDefaults() -> [AutomationItem] {
        [
            AutomationItem(id: UUID(), name: "App Store", enabled: false, builtinKey: "appstore",
                targetKind: .app, bundleIDs: ["com.apple.AppStore"],
                signing: .applePlatform, extensionOrigin: nil, urlFragment: nil,
                fieldAXIdentifier: nil, submitStrategy: .appStoreWizard),
            // com.apple.Safari：Safari 内的 Passwords 解锁 sheet（设置 → 密码等）密码框属主是
            // Safari 进程本身。网页密码框同属 Safari，靠 AuthContextDetector 的
            // "原生 sheet 且不在 AXWebArea 内"硬化判据区分，绝不注入网页字段。
            AutomationItem(id: UUID(), name: "Passwords", enabled: false, builtinKey: "passwords",
                targetKind: .app,
                bundleIDs: ["com.apple.Passwords", "com.apple.AuthKitUI.AKAuthorizationRemoteViewService",
                            "com.apple.Safari"],
                signing: .applePlatform, extensionOrigin: nil, urlFragment: nil,
                fieldAXIdentifier: nil, submitStrategy: .generic),
            AutomationItem(id: UUID(), name: "1Password", enabled: false, builtinKey: "1password",
                targetKind: .app, bundleIDs: ["com.1password.1password"],
                signing: .developerID(teamID: "2BUA8C4S2C"), extensionOrigin: nil, urlFragment: nil,
                fieldAXIdentifier: nil, submitStrategy: .rightArrow),
            // Bitwarden 浏览器扩展类：宿主浏览器逐个各自 TeamID 由 BrowserExtensionDetector 持有，
            // 这里 signing 字段占位 .applePlatform（浏览器扩展路径不读它，isValid 仍成立）。
            AutomationItem(id: UUID(), name: "Bitwarden", enabled: false, builtinKey: "bitwarden",
                targetKind: .browserExtension,
                bundleIDs: ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser"],
                signing: .applePlatform,
                extensionOrigin: "chrome-extension://nngceckbapebfimnlniiiahkandclblb/",
                urlFragment: "#/lock", fieldAXIdentifier: nil, submitStrategy: .belowButton),
        ]
    }
}
