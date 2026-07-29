import Foundation

/// 某白名单 App 的代码签名要求。
public enum SigningRequirement: Equatable {
    /// Apple 系统一方签名（anchor apple）。
    case applePlatform
    /// 第三方 Developer ID 签名 + 指定 Team ID。
    case developerID(teamID: String)

    /// 生成传给 SecRequirementCreateWithString 的要求串。
    /// bundleID 只应传入白名单固定字面量键，不接受任意外部输入。
    public func securityRequirementString(bundleID: String) -> String {
        switch self {
        case .applePlatform:
            return "anchor apple and identifier \"\(bundleID)\""
        case .developerID(let teamID):
            return "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
        }
    }
}

/// 决定"某 bundle id 的密码框可否被注入、注入哪种密码、用哪种签名要求校验"。
public enum InjectionPolicy {
    private static let table: [String: (kind: SecretKind, signing: SigningRequirement)] = [
        "com.apple.AppStore":  (.appleIDPassword, .applePlatform),
        "com.apple.Passwords": (.loginPassword,   .applePlatform),
        // Safari "Sign in with Apple" 授权 sheet 的属主进程
        "com.apple.AuthKitUI.AKAuthorizationRemoteViewService": (.loginPassword, .applePlatform),
        // 1Password 桌面进程：整屏锁定窗 + 浏览器扩展解锁浮层都归它。
        // 注入 1Password 自己的解锁密码（可与系统密码不同），非登录密码。
        "com.1password.1password": (.onePasswordPassword, .developerID(teamID: "2BUA8C4S2C")),
    ]

    public static func entry(forBundleID bundleID: String) -> (kind: SecretKind, signing: SigningRequirement)? {
        table[bundleID]
    }
}
