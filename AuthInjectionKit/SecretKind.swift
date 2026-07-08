import Foundation

/// 注入哪一种密码。由 InjectionWhitelist 按白名单 App 决定。
public enum SecretKind: Equatable {
    case loginPassword     // Mac 登录密码（已在 Keychain：com.immurok.password）
    case appleIDPassword   // Apple ID 密码（com.immurok.appleid-password）
}
