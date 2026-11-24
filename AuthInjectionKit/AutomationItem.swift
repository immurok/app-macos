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
        case "passwords", Self.touchIDBuiltinKey:  return "com.immurok.password"
        case "1password":  return "com.immurok.onepassword-password"
        case "bitwarden":  return "com.immurok.bitwarden-password"
        default:           return "com.immurok.automation.\(id.uuidString)"
        }
    }

    /// 该条目注入的是 Mac 登录密码（与屏幕解锁共用同一 Keychain 条目）。
    /// 这类条目的密码设置/修改必须走带校验的登录密码入口，不能在 Automation 里随手存。
    public var usesLoginPassword: Bool { builtinKey == "passwords" || isTouchIDAutoFill }

    /// LocalAuthentication 的系统认证框（coreautha）：Touch ID 页 +「使用密码…」后的密码页。
    /// 它直接向钥匙包校验密码，不经过 PAM，所以"提交空密码 + authorization 预授权"对它无效，
    /// 只会白记一次密码错误；正确做法是按「使用密码…」再注入登录密码。
    /// 对应内置条目「Touch ID auto-fill」（`touchIDBuiltinKey`），开关在 Automation 里；
    /// 识别与注入走 AuthContextDetector.localAuthDialog() 专用路径，不走通用 detect()。
    public static let localAuthUIAgentBundleID = "com.apple.LocalAuthentication.UIAgent"
    public static let touchIDBuiltinKey = "touchid"

    /// 「Touch ID auto-fill」内置条目。复用登录密码且**不提供**任何密码设置/修改入口
    ///（修改在「功能 > 屏幕解锁」）。
    public var isTouchIDAutoFill: Bool { builtinKey == Self.touchIDBuiltinKey }

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
        // 存盘里 builtinKey 已不在当前内置表的条目（旧版本的内置项）直接丢弃：
        // 它既不可删又没有身份来源，留着只会变成删不掉的僵尸条目。
        var result: [AutomationItem] = stored.filter { $0.builtinKey == nil || defaults[$0.builtinKey!] != nil }.map { item in
            guard let key = item.builtinKey, let fresh = defaults[key] else { return item }
            seen.insert(key)
            var m = fresh
            m.id = item.id
            m.enabled = item.enabled
            return m
        }
        // 缺失的内置项按 builtinDefaults 的顺序插到"前一个内置项"后面（如 Touch ID auto-fill
        // 紧跟 Passwords），找不到前驱才追加到末尾。
        let order = builtinDefaults()
        for (i, item) in order.enumerated() where !seen.contains(item.builtinKey!) {
            let prevKey = i > 0 ? order[i - 1].builtinKey : nil
            if let prevKey, let at = result.firstIndex(where: { $0.builtinKey == prevKey }) {
                result.insert(item, at: at + 1)
            } else {
                result.append(item)
            }
        }
        return result
    }

    /// 空白自定义条目（供"添加"入口预填）。
    public static func newCustom() -> AutomationItem {
        AutomationItem(id: UUID(), name: "", enabled: true, builtinKey: nil,
            targetKind: .app, bundleIDs: [], signing: .applePlatform,
            extensionOrigin: nil, urlFragment: nil, fieldAXIdentifier: nil, submitStrategy: .generic)
    }

    /// 内置条目（enabled 默认 false，迁移时按旧开关覆盖）。
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
                // com.apple.AuthenticationServices.Helper：第三方浏览器（Chrome 等）用 Apple Passwords 里的
                // 通行密钥登录时，「输入电脑账户密码」那个 sheet 的密码框属主。sheet 本身挂在浏览器窗口上
                //（AX 上归浏览器进程），只有密码框归这个 Helper。
                bundleIDs: ["com.apple.Passwords", "com.apple.AuthKitUI.AKAuthorizationRemoteViewService",
                            "com.apple.AuthenticationServices.Helper", "com.apple.Safari"],
                signing: .applePlatform, extensionOrigin: nil, urlFragment: nil,
                fieldAXIdentifier: nil, submitStrategy: .generic),
            // 系统 Touch ID 认证框（coreautha）：按「使用密码…」→ 注入登录密码 → 提交。
            AutomationItem(id: UUID(), name: "Touch ID auto-fill", enabled: false, builtinKey: touchIDBuiltinKey,
                targetKind: .app, bundleIDs: [localAuthUIAgentBundleID],
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
