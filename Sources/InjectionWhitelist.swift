import Foundation
import Security
import AuthInjectionKit

/// 决定"某进程的密码框可否被注入、注入哪种密码"。
/// 安全关键：只比 bundle id 会被冒充，必须叠加代码签名校验。
/// 白名单表与签名要求见 AuthInjectionKit.InjectionPolicy（可单测）；
/// 此处只负责用系统 API 做实际的 SecCodeCheckValidity 校验（有副作用、需活进程）。
enum InjectionWhitelist {
    static func secretKind(forPID pid: pid_t, bundleID: String?) -> SecretKind? {
        guard let bundleID, let entry = InjectionPolicy.entry(forBundleID: bundleID) else { return nil }
        guard satisfiesSigning(pid: pid, bundleID: bundleID, requirement: entry.signing) else {
            NSLog("InjectionWhitelist: reject %@ pid=%d — code signature check failed", bundleID, pid)
            return nil
        }
        return entry.kind
    }

    /// 通用签名校验（供 Bitwarden 浏览器宿主校验用）：目标进程是否满足给定签名要求。
    /// Bitwarden 的密码框归浏览器进程，须先确认该进程确是正牌浏览器（防 bundle id 冒充），
    /// 再叠加"WebArea URL 属于 Bitwarden 扩展"判据。bundleID 只应传固定字面量。
    static func processSatisfies(pid: pid_t, bundleID: String, signing: SigningRequirement) -> Bool {
        satisfiesSigning(pid: pid, bundleID: bundleID, requirement: signing)
    }

    /// SecCodeCheckValidity：用 InjectionPolicy 给出的要求串校验目标进程签名。
    /// - `.applePlatform` → anchor apple + identifier
    /// - `.developerID`   → anchor apple generic + identifier + Team ID(OU)
    /// bundleID 只应传入白名单命中的键（固定字面量），不接受任意外部输入。
    private static func satisfiesSigning(pid: pid_t, bundleID: String, requirement: SigningRequirement) -> Bool {
        var codeRef: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &codeRef) == errSecSuccess,
              let code = codeRef else { return false }

        let reqString = requirement.securityRequirementString(bundleID: bundleID)
        var req: SecRequirement?
        guard SecRequirementCreateWithString(reqString as CFString, [], &req) == errSecSuccess,
              let requirement = req else { return false }

        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
