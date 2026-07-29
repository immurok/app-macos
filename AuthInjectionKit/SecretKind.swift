import Foundation

/// 注入哪一种密码。由 InjectionWhitelist 按白名单 App 决定。
public enum SecretKind: Equatable {
    case loginPassword       // Mac 登录密码（已在 Keychain：com.immurok.password）
    case appleIDPassword     // Apple ID 密码（com.immurok.appleid-password）
    case onePasswordPassword // 1Password 解锁密码（com.immurok.onepassword-password）——可与系统密码不同
    case bitwardenPassword   // Bitwarden 解锁密码（com.immurok.bitwarden-password）——浏览器扩展，独立密码
}
