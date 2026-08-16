import Foundation
import Security
import AuthInjectionKit

/// 决定"某进程的密码框可否被注入、注入哪种密码"。
/// 安全关键：只比 bundle id 会被冒充，必须叠加代码签名校验。
/// 白名单表与签名要求见 AuthInjectionKit.InjectionPolicy（可单测）；
/// 此处只负责用系统 API 做实际的 SecCodeCheckValidity 校验（有副作用、需活进程）。
enum InjectionWhitelist {
    /// 用户可配置条目的签名校验：bundleID 必须是条目声明的、且字符合法（防 requirement 串注入），
    /// 再用条目自带的 signing 要求做 SecCodeCheckValidity。通过返回 true。
    static func passesSigning(for item: AutomationItem, pid: pid_t, bundleID: String) -> Bool {
        guard item.matches(bundleID: bundleID), IdentityValidation.isValidBundleID(bundleID) else { return false }
        guard satisfiesSigning(pid: pid, bundleID: bundleID, requirement: item.signing) else {
            NSLog("InjectionWhitelist: reject %@ pid=%d — code signature check failed", bundleID, pid)
            return false
        }
        return true
    }

    /// 通用签名校验（供 Bitwarden 浏览器宿主校验用）：目标进程是否满足给定签名要求。
    /// Bitwarden 的密码框归浏览器进程，须先确认该进程确是正牌浏览器（防 bundle id 冒充），
    /// 再叠加"WebArea URL 属于 Bitwarden 扩展"判据。bundleID 只应传固定字面量。
    static func processSatisfies(pid: pid_t, bundleID: String, signing: SigningRequirement) -> Bool {
        satisfiesSigning(pid: pid, bundleID: bundleID, requirement: signing)
    }

    /// 校验目标进程签名。
    /// - `.applePlatform` → `anchor apple and identifier`（SecCodeCheckValidity）
    /// - `.developerID`   → `anchor apple generic and identifier`（确认 Apple 签名链 + bundle id）
    ///   再单独读进程实际 Team Identifier 比对。**不再用 `certificate leaf[subject.OU]`**——
    ///   那对 Mac App Store 分发的 app（叶证书是 Apple Mac OS Application Signing，OU 非 Team ID）
    ///   不成立，会误拒（如从 App Store 装的 Bitwarden）。读 TeamIdentifier 对 App Store 与
    ///   Developer ID 两种分发都成立，且仍钉住 Team ID 防 bundle id 冒充。
    /// bundleID/teamID 已在上游做字符白名单校验；此处再校一次防御。
    private static func satisfiesSigning(pid: pid_t, bundleID: String, requirement: SigningRequirement) -> Bool {
        guard IdentityValidation.isValidBundleID(bundleID) else { return false }
        var codeRef: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &codeRef) == errSecSuccess,
              let code = codeRef else { return false }

        switch requirement {
        case .applePlatform:
            guard let reqString = requirement.validatedRequirementString(bundleID: bundleID) else { return false }
            var req: SecRequirement?
            guard SecRequirementCreateWithString(reqString as CFString, [], &req) == errSecSuccess,
                  let r = req else { return false }
            return SecCodeCheckValidity(code, [], r) == errSecSuccess

        case .developerID(let teamID):
            guard IdentityValidation.isValidTeamID(teamID) else { return false }
            let reqString = "anchor apple generic and identifier \"\(bundleID)\""
            var req: SecRequirement?
            guard SecRequirementCreateWithString(reqString as CFString, [], &req) == errSecSuccess,
                  let r = req, SecCodeCheckValidity(code, [], r) == errSecSuccess else { return false }
            return teamIdentifier(of: code) == teamID
        }
    }

    /// 读运行进程的 Team Identifier（kSecCodeInfoTeamIdentifier）。
    private static func teamIdentifier(of code: SecCode) -> String? {
        var stat: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &stat) == errSecSuccess, let stat else { return nil }
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(stat, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
