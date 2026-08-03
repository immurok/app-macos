import Foundation
import CryptoKit

/// Parses SSH ECDSA P-256 private key files for import to the device.
/// Supports two file formats:
///   1) PEM SEC1 / PKCS#8 — `-----BEGIN EC PRIVATE KEY-----` or
///      `-----BEGIN PRIVATE KEY-----`. Decoded via CryptoKit.
///   2) OpenSSH unencrypted — `-----BEGIN OPENSSH PRIVATE KEY-----`.
///      Decoded via a small custom parser (RFC openssh-keys.h binary layout).
/// Encrypted OpenSSH (passphrase-protected) is rejected with a clear error —
/// user must run `ssh-keygen -p -N '' -f keyfile` to strip the passphrase first.
enum SSHKeyImporter {

    enum ImportError: Error, LocalizedError {
        case fileReadFailed
        case unrecognizedFormat
        case unsupportedKeyType(String)  // e.g. "ssh-ed25519", "ssh-rsa"
        case encryptedKey                 // passphrase required, not supported
        case parseFailed(String)
        case invalidScalar                // privkey scalar fails P-256 sanity check

        /// Surfaced verbatim in an NSAlert (SettingsTabViews.importSSHKey),
        /// so every branch must be localized. The `parseFailed` payload is
        /// deliberately left as English technical detail — it names file
        /// format internals, not UI copy.
        var errorDescription: String? {
            switch self {
            case .fileReadFailed:
                return "ssh.import.error.fileread".localized
            case .unrecognizedFormat:
                return "ssh.import.error.format".localized
            case .unsupportedKeyType(let t):
                return String(format: "ssh.import.error.keytype".localized, t)
            case .encryptedKey:
                return "ssh.import.error.encrypted".localized
            case .parseFailed(let detail):
                return String(format: "ssh.import.error.parse".localized, detail)
            case .invalidScalar:
                return "ssh.import.error.scalar".localized
            }
        }
    }

    /// Result: 32B raw private scalar (P-256). Caller derives pubkey via CryptoKit.
    struct ImportedKey {
        let privateKeyRaw: Data        // 32 bytes
        let publicKeyRaw: Data         // 64 bytes (x || y, big-endian)
        var openSSHFingerprint: String {
            let blob = SSHKeyCache.buildSSHPublicKeyBlob(publicKey: publicKeyRaw)
            return SSHKeyCache.computeFingerprint(blob: blob)
        }
    }

    static func parse(fileURL: URL) throws -> ImportedKey {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw ImportError.fileReadFailed
        }
        return try parse(text: text)
    }

    static func parse(text: String) throws -> ImportedKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.contains("-----BEGIN OPENSSH PRIVATE KEY-----") {
            return try parseOpenSSH(text: trimmed)
        }
        if trimmed.contains("-----BEGIN EC PRIVATE KEY-----")
            || trimmed.contains("-----BEGIN PRIVATE KEY-----") {
            return try parsePEM(text: trimmed)
        }
        throw ImportError.unrecognizedFormat
    }

    // MARK: - PEM (SEC1 / PKCS#8) via CryptoKit

    private static func parsePEM(text: String) throws -> ImportedKey {
        do {
            let key = try P256.Signing.PrivateKey(pemRepresentation: text)
            // rawRepresentation is the 32-byte scalar; publicKey.rawRepresentation
            // is 64-byte uncompressed (x || y) big-endian.
            return ImportedKey(
                privateKeyRaw: key.rawRepresentation,
                publicKeyRaw: key.publicKey.rawRepresentation
            )
        } catch {
            throw ImportError.parseFailed("PEM: \(error.localizedDescription)")
        }
    }

    // MARK: - OpenSSH binary parser

    /// OpenSSH unencrypted private key file layout (PROTOCOL.key):
    ///   "openssh-key-v1\0"           (15 bytes)
    ///   string ciphername            ("none" for unencrypted)
    ///   string kdfname               ("none")
    ///   string kdfoptions            (empty)
    ///   uint32 num_keys              (always 1 for ssh-keygen output)
    ///   string public_key_blob
    ///   string encrypted_section
    /// For ciphername="none" the encrypted_section is plaintext:
    ///   uint32 check1, uint32 check2 (must match)
    ///   string keytype               ("ecdsa-sha2-nistp256")
    ///   string curve                 ("nistp256")
    ///   string Q                     (uncompressed pubkey, 0x04 || x || y, 65B)
    ///   string privkey_scalar        (mpint, BE; may be 32 or 33 bytes if high bit set)
    ///   string comment
    ///   padding (1, 2, 3, ...)
    private static func parseOpenSSH(text: String) throws -> ImportedKey {
        // Strip PEM headers + whitespace, base64-decode
        let lines = text.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
            .filter { !$0.isWhitespace }
        guard let blob = Data(base64Encoded: lines) else {
            throw ImportError.parseFailed("base64 decode failed")
        }

        var p = ByteReader(blob)
        let magic = p.read(15)
        guard magic == Data("openssh-key-v1\0".utf8) else {
            throw ImportError.parseFailed("magic is not openssh-key-v1")
        }
        let cipher = try p.readSSHString()
        let kdf = try p.readSSHString()
        _ = try p.readSSHString()  // kdfoptions

        guard cipher == Data("none".utf8) else {
            throw ImportError.encryptedKey
        }
        guard kdf == Data("none".utf8) else {
            throw ImportError.encryptedKey
        }

        let numKeys = try p.readUInt32()
        guard numKeys == 1 else {
            throw ImportError.parseFailed("num_keys=\(numKeys) (expected 1)")
        }

        // Public key blob — peek the type for early type-mismatch detection
        let pubBlob = try p.readSSHString()
        var pp = ByteReader(pubBlob)
        let keyType = try pp.readSSHString()
        let keyTypeStr = String(data: keyType, encoding: .utf8) ?? "?"
        guard keyTypeStr == "ecdsa-sha2-nistp256" else {
            throw ImportError.unsupportedKeyType(keyTypeStr)
        }

        // Encrypted section (plaintext when cipher="none")
        let priv = try p.readSSHString()
        var pr = ByteReader(priv)
        let check1 = try pr.readUInt32()
        let check2 = try pr.readUInt32()
        guard check1 == check2 else {
            throw ImportError.parseFailed("check int mismatch")
        }
        let keyType2 = try pr.readSSHString()
        guard String(data: keyType2, encoding: .utf8) == "ecdsa-sha2-nistp256" else {
            throw ImportError.parseFailed("inner key type mismatch")
        }
        let curve = try pr.readSSHString()
        guard String(data: curve, encoding: .utf8) == "nistp256" else {
            throw ImportError.parseFailed("curve != nistp256")
        }
        // Q: 0x04 || x[32] || y[32] — 65 bytes uncompressed
        let q = try pr.readSSHString()
        guard q.count == 65, q.first == 0x04 else {
            throw ImportError.parseFailed("Q is not in uncompressed 65-byte form")
        }
        let publicKeyRaw = q.subdata(in: 1..<65)  // 64B (x || y)

        // Private scalar mpint: BE-encoded, may have leading 0x00 sign byte
        let scalarRaw = try pr.readSSHString()
        let privateKeyRaw: Data
        if scalarRaw.count == 33 && scalarRaw.first == 0x00 {
            privateKeyRaw = scalarRaw.subdata(in: 1..<33)
        } else if scalarRaw.count == 32 {
            privateKeyRaw = scalarRaw
        } else if scalarRaw.count < 32 {
            // Short scalar (unusual but possible) — left-pad with zeros to 32B
            var padded = Data(count: 32 - scalarRaw.count)
            padded.append(scalarRaw)
            privateKeyRaw = padded
        } else {
            throw ImportError.parseFailed("unexpected private scalar length (\(scalarRaw.count)B)")
        }

        // Sanity-check by importing into CryptoKit. P256 rejects zero or
        // out-of-range scalars; we catch that to avoid bricking a slot with
        // a key the device can never sign with. ALSO verify the derived
        // pubkey matches the parsed pubkey — catches any byte-order /
        // parsing bug between scalar and Q before it ends up in flash.
        guard let priv = try? P256.Signing.PrivateKey(rawRepresentation: privateKeyRaw) else {
            throw ImportError.invalidScalar
        }
        let derivedPub = priv.publicKey.rawRepresentation
        guard derivedPub == publicKeyRaw else {
            throw ImportError.parseFailed(
                "public key derived from the private key does not match the one in the file (parse or endianness bug)"
            )
        }

        return ImportedKey(privateKeyRaw: privateKeyRaw, publicKeyRaw: publicKeyRaw)
    }

    /// Same self-check for the PEM path — CryptoKit constructs the key from
    /// rawRepresentation, but we still want a final assertion that the pair
    /// is internally consistent (defense-in-depth against a future refactor).
    private static func validatePair(privateKeyRaw: Data, publicKeyRaw: Data) throws {
        guard let priv = try? P256.Signing.PrivateKey(rawRepresentation: privateKeyRaw),
              priv.publicKey.rawRepresentation == publicKeyRaw else {
            throw ImportError.parseFailed("private key does not match its public key")
        }
    }
}

// MARK: - Tiny binary reader

private struct ByteReader {
    let data: Data
    var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func read(_ n: Int) -> Data {
        let end = offset + n
        let slice = data.subdata(in: offset..<min(end, data.endIndex))
        offset = end
        return slice
    }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.endIndex else {
            throw SSHKeyImporter.ImportError.parseFailed("ran out of bytes")
        }
        let b = data[offset..<(offset + 4)]
        offset += 4
        return UInt32(b[b.startIndex]) << 24
             | UInt32(b[b.startIndex + 1]) << 16
             | UInt32(b[b.startIndex + 2]) << 8
             | UInt32(b[b.startIndex + 3])
    }

    mutating func readSSHString() throws -> Data {
        let len = Int(try readUInt32())
        guard offset + len <= data.endIndex else {
            throw SSHKeyImporter.ImportError.parseFailed("string length out of range")
        }
        let s = data.subdata(in: offset..<(offset + len))
        offset += len
        return s
    }
}
