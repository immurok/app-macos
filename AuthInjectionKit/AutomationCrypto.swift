import Foundation
import CryptoKit
import CommonCrypto

/// 导出/导入的明文载荷：条目 + 各条密码（service → password）。
public struct AutomationExportPayload: Codable, Equatable {
    public var items: [AutomationItem]
    public var secrets: [String: String]
    public init(items: [AutomationItem], secrets: [String: String]) {
        self.items = items; self.secrets = secrets
    }
}

/// 导出容器：明文头部 + AES-256-GCM 密文。口令经 PBKDF2-SHA256 派生密钥。
public enum AutomationCrypto {
    public enum CryptoError: Error, Equatable { case badContainer, wrongPasswordOrCorrupted, unsupportedVersion }

    private static let magic = "immurok-automation"
    private static let version = 1
    private static let iterations = 210_000
    private static let keyLen = 32
    private static let saltLen = 16

    private struct Container: Codable {
        let magic: String; let version: Int; let kdf: String
        let iterations: Int; let salt: String; let nonce: String
        let ciphertext: String; let tag: String
    }

    public static func encrypt(_ payload: AutomationExportPayload, password: String) throws -> Data {
        let plaintext = try JSONEncoder().encode(payload)
        var salt = Data(count: saltLen)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, saltLen, $0.baseAddress!) }
        let key = try deriveKey(password: password, salt: salt)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        let container = Container(
            magic: magic, version: version, kdf: "pbkdf2-sha256", iterations: iterations,
            salt: salt.base64EncodedString(),
            nonce: Data(sealed.nonce).base64EncodedString(),
            ciphertext: sealed.ciphertext.base64EncodedString(),
            tag: sealed.tag.base64EncodedString())
        return try JSONEncoder().encode(container)
    }

    public static func decrypt(_ data: Data, password: String) throws -> AutomationExportPayload {
        guard let container = try? JSONDecoder().decode(Container.self, from: data),
              container.magic == magic else { throw CryptoError.badContainer }
        guard container.version == version else { throw CryptoError.unsupportedVersion }
        guard let salt = Data(base64Encoded: container.salt),
              let nonceData = Data(base64Encoded: container.nonce),
              let ct = Data(base64Encoded: container.ciphertext),
              let tag = Data(base64Encoded: container.tag) else { throw CryptoError.badContainer }
        let key = try deriveKey(password: password, salt: salt, iterations: container.iterations)
        do {
            let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonceData), ciphertext: ct, tag: tag)
            let plaintext = try AES.GCM.open(box, using: key)
            return try JSONDecoder().decode(AutomationExportPayload.self, from: plaintext)
        } catch {
            throw CryptoError.wrongPasswordOrCorrupted
        }
    }

    private static func deriveKey(password: String, salt: Data, iterations: Int = iterations) throws -> SymmetricKey {
        var derived = Data(count: keyLen)
        let pwData = Data(password.utf8)
        let status = derived.withUnsafeMutableBytes { dOut in
            salt.withUnsafeBytes { sIn in
                pwData.withUnsafeBytes { pIn in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pIn.baseAddress!.assumingMemoryBound(to: Int8.self), pwData.count,
                        sIn.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                        dOut.baseAddress!.assumingMemoryBound(to: UInt8.self), keyLen)
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.wrongPasswordOrCorrupted }
        return SymmetricKey(data: derived)
    }
}
