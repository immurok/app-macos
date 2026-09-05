/*
 * ImmurokSecurity.swift - ECDH pairing, HMAC verification, Keychain storage
 */

import CryptoKit
import Foundation
import OpenDirectory
import Security

class ImmurokSecurity {
    static let shared = ImmurokSecurity()

    // MARK: - Constants

    private let keychainServiceSharedKey = "com.immurok.shared-key"
    private let keychainServicePassword = "com.immurok.password"
    private let keychainServiceAppleIDPassword = "com.immurok.appleid-password"
    private let keychainServiceOnePasswordPassword = "com.immurok.onepassword-password"
    private let keychainServiceBitwardenPassword = "com.immurok.bitwarden-password"
    private let keychainServiceVerifiedDevice = "com.immurok.verified-device"
    private let keychainServicePamKey = "com.immurok.pam-key"
    private let keychainAccount = "immurok"

    private static let hkdfSalt = "immurok-pairing-salt".data(using: .utf8)!
    private static let hkdfInfo = "immurok-shared-key".data(using: .utf8)!

    // MARK: - State

    private var ephemeralPrivateKey: P256.KeyAgreement.PrivateKey?

    // MARK: - ECDH Pairing

    /// Generate ephemeral key pair, return compressed public key (33 bytes) to send to device
    func startPairing() -> Data {
        let privateKey = P256.KeyAgreement.PrivateKey()
        ephemeralPrivateKey = privateKey
        return privateKey.publicKey.compressedRepresentation
    }

    /// Complete pairing with device's compressed public key (33 bytes)
    /// Returns true on success (shared_key saved to Keychain)
    func completePairing(deviceCompressedPubKey: Data) -> Bool {
        guard let privateKey = ephemeralPrivateKey else {
            NSLog("ImmurokSecurity: No ephemeral key for pairing")
            return false
        }

        do {
            let devicePubKey = try P256.KeyAgreement.PublicKey(
                compressedRepresentation: deviceCompressedPubKey
            )
            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: devicePubKey)

            // HKDF derive shared key
            let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Self.hkdfSalt,
                sharedInfo: Self.hkdfInfo,
                outputByteCount: 32
            )

            // Extract raw key bytes
            let keyData = symmetricKey.withUnsafeBytes { Data($0) }

            // Save to Keychain
            saveToKeychain(service: keychainServiceSharedKey, data: keyData)

            // Clear ephemeral key
            ephemeralPrivateKey = nil

            NSLog("ImmurokSecurity: Pairing complete, shared_key saved")
            return true
        } catch {
            NSLog("ImmurokSecurity: Pairing failed: %@", error.localizedDescription)
            ephemeralPrivateKey = nil
            return false
        }
    }

    // MARK: - HMAC Verification (for 0x21 notification)

    /// Verify signed fingerprint match notification
    /// Format: [0x21][page_id:2B LE][hmac:8B] = 11 bytes
    /// Returns (pageId, true) if valid, (0, false) if invalid
    func verifyFingerprintMatch(data: Data) -> (pageId: UInt16, valid: Bool) {
        guard data.count == 11, data[0] == 0x21 else {
            NSLog("ImmurokSecurity: Invalid 0x21 notification size: %d", data.count)
            return (0, false)
        }

        guard let sharedKey = loadFromKeychain(service: keychainServiceSharedKey) else {
            NSLog("ImmurokSecurity: No shared_key in Keychain")
            return (0, false)
        }

        let pageId = UInt16(data[1]) | (UInt16(data[2]) << 8)
        let receivedHmac = data[3..<11]

        // Compute expected HMAC
        let message = data[0..<3]  // 0x21 + page_id
        let symmetricKey = SymmetricKey(data: sharedKey)
        let expectedHmac = HMAC<SHA256>.authenticationCode(for: message, using: symmetricKey)
        let expectedPrefix = Data(expectedHmac.prefix(8))

        guard receivedHmac.elementsEqual(expectedPrefix) else {
            NSLog("ImmurokSecurity: HMAC mismatch")
            return (0, false)
        }

        return (pageId, true)
    }

    // MARK: - Challenge-Response Verification

    /// Generate 8-byte random nonce for challenge
    func generateChallenge() -> Data {
        var nonce = Data(count: 8)
        nonce.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }
        return nonce
    }

    /// Verify device's challenge response: HMAC-SHA256(shared_key, nonce)[0:8]
    func verifyChallengeResponse(nonce: Data, response: Data) -> Bool {
        guard let sharedKey = loadFromKeychain(service: keychainServiceSharedKey) else {
            NSLog("ImmurokSecurity: No shared_key for challenge verification")
            return false
        }

        let symmetricKey = SymmetricKey(data: sharedKey)
        let expectedHmac = HMAC<SHA256>.authenticationCode(for: nonce, using: symmetricKey)
        let expectedPrefix = Data(expectedHmac.prefix(8))

        return response.elementsEqual(expectedPrefix)
    }

    // MARK: - PAM 信道 MAC（spec 2026-09-03-pam-channel-mac-design.md）
    //
    // pam_key 与设备无关，每台电脑一把随机密钥。PAM 模块用 root 目录里的副本验证
    // 我们对其 nonce 的 HMAC；副本由 `imk pam-key install` 以 root 身份从
    // CLISocketServer 取走。换设备、重配对都不影响这把密钥。

    static let pamMacPrefix = "immurok-pam-v1"

    static func pamKeyId(key: Data) -> String {
        SHA256.hash(data: key).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func pamMac(key: Data, nonce: Data, user: String, service: String) -> String {
        var msg = Data(pamMacPrefix.utf8)
        msg.append(nonce)
        msg.append(Data(user.utf8)); msg.append(0)
        msg.append(Data(service.utf8)); msg.append(0)
        let full = HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key))
        return full.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func loadPamKey() -> Data? {
        guard let d = loadFromKeychain(service: keychainServicePamKey), d.count == 32 else { return nil }
        return d
    }

    func loadOrCreatePamKey() -> Data? {
        if let k = loadPamKey() { return k }
        var k = Data(count: 32)
        let rc = k.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard rc == errSecSuccess else {
            NSLog("ImmurokSecurity: SecRandomCopyBytes failed: %d", rc)
            return nil
        }
        saveToKeychain(service: keychainServicePamKey, data: k)
        NSLog("ImmurokSecurity: pam_key generated")
        return loadPamKey()
    }

    func pamKeyId() -> String? {
        loadPamKey().map { Self.pamKeyId(key: $0) }
    }

    func deletePamKey() {
        deleteFromKeychain(service: keychainServicePamKey)
    }

    // MARK: - Verified Device Cache

    /// Save device UUID after successful challenge verification
    func saveVerifiedDevice(uuid: String) {
        guard let data = uuid.data(using: .utf8) else { return }
        saveToKeychain(service: keychainServiceVerifiedDevice, data: data)
    }

    /// Check if a device UUID matches the previously verified device
    func isVerifiedDevice(uuid: String) -> Bool {
        guard let data = loadFromKeychain(service: keychainServiceVerifiedDevice),
              let stored = String(data: data, encoding: .utf8) else {
            return false
        }
        return stored == uuid
    }

    func clearVerifiedDevice() {
        deleteFromKeychain(service: keychainServiceVerifiedDevice)
    }

    // MARK: - Pairing Status

    var isPaired: Bool {
        loadFromKeychain(service: keychainServiceSharedKey) != nil
    }

    // MARK: - 双主机登记

    func clearPairingData() {
        deleteFromKeychain(service: keychainServiceSharedKey)
        clearVerifiedDevice()
        NSLog("ImmurokSecurity: Pairing data cleared")
    }

    // MARK: - Password (Keychain)

    func savePassword(_ password: String) {
        guard let data = password.data(using: .utf8) else { return }
        saveToKeychain(service: keychainServicePassword, data: data)
        NSLog("ImmurokSecurity: Password saved to Keychain")
    }

    func loadPassword() -> String? {
        guard let data = loadFromKeychain(service: keychainServicePassword) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func hasPassword() -> Bool {
        loadFromKeychain(service: keychainServicePassword) != nil
    }

    func clearPassword() {
        deleteFromKeychain(service: keychainServicePassword)
    }

    /// 用 OpenDirectory 校验给定字符串是否为当前 macOS 登录密码。
    /// 存密码前的拦截（AppViewModel）和解锁失败挂起前的实证
    /// （AppDelegate.recordUnlockFailure）共用。失败会计入系统的
    /// failed-auth 计数，调用方必须限频，不能按指纹次数裸调。
    func verifyLoginPassword(_ password: String) -> Bool {
        do {
            let node = try ODNode(session: ODSession.default(),
                                  type: ODNodeType(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers,
                                         name: NSUserName(), attributes: nil)
            try record.verifyPassword(password)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Apple ID Password (Keychain)

    func saveAppleIDPassword(_ password: String) {
        guard let data = password.data(using: .utf8) else { return }
        saveToKeychain(service: keychainServiceAppleIDPassword, data: data)
        NSLog("ImmurokSecurity: Apple ID password saved to Keychain")
    }

    func loadAppleIDPassword() -> String? {
        guard let data = loadFromKeychain(service: keychainServiceAppleIDPassword) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func hasAppleIDPassword() -> Bool {
        loadFromKeychain(service: keychainServiceAppleIDPassword) != nil
    }

    func clearAppleIDPassword() {
        deleteFromKeychain(service: keychainServiceAppleIDPassword)
    }

    // MARK: - 1Password 解锁密码 (Keychain)
    // 1Password 的解锁密码未必等于系统登录密码——用户可自设。故独立存储，
    // 与登录密码/Apple ID 密码互不影响，随 1Password 解锁开关 setup/clear。

    func saveOnePasswordPassword(_ password: String) {
        guard let data = password.data(using: .utf8) else { return }
        saveToKeychain(service: keychainServiceOnePasswordPassword, data: data)
        NSLog("ImmurokSecurity: 1Password password saved to Keychain")
    }

    func loadOnePasswordPassword() -> String? {
        guard let data = loadFromKeychain(service: keychainServiceOnePasswordPassword) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func hasOnePasswordPassword() -> Bool {
        loadFromKeychain(service: keychainServiceOnePasswordPassword) != nil
    }

    func clearOnePasswordPassword() {
        deleteFromKeychain(service: keychainServiceOnePasswordPassword)
    }

    // MARK: - Bitwarden 解锁密码 (Keychain)
    // Bitwarden 浏览器扩展的解锁密码，独立存储，随 Bitwarden 解锁开关 setup/clear。

    func saveBitwardenPassword(_ password: String) {
        guard let data = password.data(using: .utf8) else { return }
        saveToKeychain(service: keychainServiceBitwardenPassword, data: data)
        NSLog("ImmurokSecurity: Bitwarden password saved to Keychain")
    }

    func loadBitwardenPassword() -> String? {
        guard let data = loadFromKeychain(service: keychainServiceBitwardenPassword) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func hasBitwardenPassword() -> Bool {
        loadFromKeychain(service: keychainServiceBitwardenPassword) != nil
    }

    func clearBitwardenPassword() {
        deleteFromKeychain(service: keychainServiceBitwardenPassword)
    }

    /// 卸载时调用：清除本 App 写入的全部 Keychain 条目（登录密码、Apple ID
    /// 密码、1Password 解锁密码、Bitwarden 解锁密码、配对共享密钥、已验证设备）。
    /// 卸载 pkg 的 postinstall 以 root 运行，够不到用户 Keychain，只能趁 App 进程还在时由 App 自己清。
    func clearAllKeychainData() {
        clearPassword()
        clearAppleIDPassword()
        clearOnePasswordPassword()
        clearBitwardenPassword()
        for svc in allAutomationSecretServices() { deleteSecret(service: svc) }
        clearPairingData()  // shared key + verified device
        deleteFromKeychain(service: keychainServicePamKey)
        NSLog("ImmurokSecurity: All Keychain data cleared (uninstall)")
    }

    // MARK: - 通用 per-service 密码存取（Automation 条目用）
    // 内置条目复用上面各自的固定 service；自定义条目用 com.immurok.automation.<uuid>。

    func saveSecret(_ password: String, service: String) {
        guard let data = password.data(using: .utf8) else { return }
        saveToKeychain(service: service, data: data)
    }
    func loadSecret(service: String) -> String? {
        guard let data = loadFromKeychain(service: service) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    func hasSecret(service: String) -> Bool { loadFromKeychain(service: service) != nil }
    func deleteSecret(service: String) { deleteFromKeychain(service: service) }

    /// 枚举本 App 写入的所有自定义 Automation 条目 service（前缀匹配），供卸载清理。
    func allAutomationSecretServices() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrService as String] as? String }
            .filter { $0.hasPrefix("com.immurok.automation.") }
    }

    // MARK: - Keychain Helpers

    private func saveToKeychain(service: String, data: Data) {
        // Delete existing item first
        deleteFromKeychain(service: service)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("ImmurokSecurity: Keychain save failed: %d", status)
        }
    }

    private func loadFromKeychain(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            return result as? Data
        }
        return nil
    }

    private func deleteFromKeychain(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
