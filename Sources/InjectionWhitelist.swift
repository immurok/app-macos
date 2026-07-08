import Foundation
import Security
import AuthInjectionKit

/// 决定"某进程的密码框可否被注入、注入哪种密码"。
/// 安全关键：只比 bundle id 会被冒充，必须叠加代码签名校验（anchor apple）。
enum InjectionWhitelist {
    private static let table: [String: SecretKind] = [
        "com.apple.AppStore": .appleIDPassword,
        "com.apple.Passwords": .loginPassword,
        // Safari "Sign in with Apple" 授权 sheet：属主是 AuthKitUI 的远程视图服务
        // （前台应用是 Safari，但密码框属于此进程）。要 Mac 登录密码。
        "com.apple.AuthKitUI.AKAuthorizationRemoteViewService": .loginPassword,
    ]

    static func secretKind(forPID pid: pid_t, bundleID: String?) -> SecretKind? {
        guard let bundleID, let kind = table[bundleID] else { return nil }
        guard isApplePlatformBinary(pid: pid, bundleID: bundleID) else {
            NSLog("InjectionWhitelist: reject %@ pid=%d — code signature check failed", bundleID, pid)
            return nil
        }
        return kind
    }

    /// SecCodeCheckValidity：要求 anchor apple（系统一方签名）+ identifier 与调用方匹配的 bundle id
    /// 一致（防御纵深：即使 identifier 校验被绕过，anchor apple 仍在；反之亦然）。
    /// bundleID 只应传入白名单命中的键（固定字面量），不接受任意外部输入。
    private static func isApplePlatformBinary(pid: pid_t, bundleID: String) -> Bool {
        var codeRef: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &codeRef) == errSecSuccess,
              let code = codeRef else { return false }

        var req: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple and identifier \"\(bundleID)\"" as CFString, [], &req) == errSecSuccess,
              let requirement = req else { return false }

        let status = SecCodeCheckValidity(code, [], requirement)
        return status == errSecSuccess
    }
}
