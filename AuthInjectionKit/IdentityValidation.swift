import Foundation

/// 用户可配置身份后的字符白名单校验：防止把恶意字符拼进
/// SecRequirementCreateWithString 的要求串（避免 requirement 语法注入）。
public enum IdentityValidation {
    /// bundle id：只允许字母数字、点、连字符；非空。
    public static func isValidBundleID(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Team ID：恰好 10 位大写字母 + 数字。
    public static func isValidTeamID(_ s: String) -> Bool {
        guard s.count == 10 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
