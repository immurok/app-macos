/*
 * ImmurokSecurity.swift - ECDH pairing, HMAC verification, Keychain storage
 */

import CryptoKit
import Foundation
import Security

class ImmurokSecurity {
    static let shared = ImmurokSecurity()

    // MARK: - Constants

    private let keychainServiceSharedKey = "com.immurok.shared-key"
    private let keychainServicePassword = "com.immurok.password"
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

    // MARK: - Pairing Status

    var isPaired: Bool {
        loadFromKeychain(service: keychainServiceSharedKey) != nil
    }

    func clearPairingData() {
        deleteFromKeychain(service: keychainServiceSharedKey)
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
