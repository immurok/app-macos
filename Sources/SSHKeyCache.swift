/*
 * SSHKeyCache.swift - SSH public key cache for SSH Agent
 *
 * Caches SSH public keys from device in ~/.immurok/ssh_keys.json
 * Private keys never leave the device; only public keys are cached.
 *
 * v2: Device stores full pubkey in SSH entry (112B: name[16]+pubkey[64]+privkey[32]).
 * Sync reads entry via KEY_READ only — avoids KEY_GETPUB callback race with concurrent commands.
 */

import Foundation
import CryptoKit

// MARK: - Cache Entry

struct SSHKeyCacheEntry: Codable {
    let index: Int           // Device-side keystore idx
    let name: String         // 16B name from device
    let publicKeyBlob: Data  // 104B SSH public key blob (ecdsa-sha2-nistp256)
    let fingerprint: String  // SHA256:base64 fingerprint (of SSH blob)
}

// MARK: - SSH Key Cache

class SSHKeyCache {

    static let shared = SSHKeyCache()

    private var _entries: [SSHKeyCacheEntry] = []
    private let lock = NSLock()
    private let cacheURL: URL

    var entries: [SSHKeyCacheEntry] {
        lock.lock()
        defer { lock.unlock() }
        return _entries
    }

    private init() {
        let immurokDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".immurok")
        try? FileManager.default.createDirectory(at: immurokDir, withIntermediateDirectories: true)
        cacheURL = immurokDir.appendingPathComponent("ssh_keys.json")
        loadFromDisk()
    }

    // MARK: - Public API

    /// Sync cache with device: read all SSH key public keys via KEY_GETPUB (flash read, no ECC)
    func sync(completion: @escaping () -> Void) {
        let ble = BLEManager.shared
        guard ble.deviceState.isConnected else {
            completion()
            return
        }

        ble.getKeyCount(cat: .ssh) { [weak self] count in
            guard let self = self, count > 0 else {
                self?.setEntries([])
                self?.saveToDisk()
                completion()
                return
            }

            self.chainSync(ble: ble, count: count, index: 0, result: []) { newEntries in
                self.setEntries(newEntries)
                self.saveToDisk()
                NSLog("SSHKeyCache: synced %d keys", newEntries.count)
                completion()
            }
        }
    }

    /// Add a single entry and save (used after KEY_GENERATE to avoid full sync)
    /// Replaces any existing entry with the same index.
    func addEntry(_ entry: SSHKeyCacheEntry) {
        lock.lock()
        _entries.removeAll(where: { $0.index == entry.index })
        _entries.append(entry)
        lock.unlock()
        saveToDisk()
    }

    /// Find device index for a given SSH public key blob
    func findIndex(forKeyBlob blob: Data) -> Int? {
        entries.first(where: { $0.publicKeyBlob == blob })?.index
    }

    /// Return all cached identities
    func allIdentities() -> [SSHKeyCacheEntry] {
        entries
    }

    /// Build SSH public key blob for ecdsa-sha2-nistp256
    /// Input: 64B public key (x||y, big-endian)
    /// Output: 104B SSH key blob
    static func buildSSHPublicKeyBlob(publicKey: Data) -> Data {
        guard publicKey.count == 64 else { return Data() }

        var blob = Data()

        // string "ecdsa-sha2-nistp256"
        let keyType = "ecdsa-sha2-nistp256"
        blob.appendSSHString(keyType)

        // string "nistp256"
        let curveName = "nistp256"
        blob.appendSSHString(curveName)

        // string 0x04 || x || y (uncompressed point, 65 bytes)
        var point = Data([0x04])
        point.append(publicKey)
        blob.appendSSHString(point)

        return blob
    }

    /// Compute SSH fingerprint (SHA256:base64) from public key blob
    static func computeFingerprint(blob: Data) -> String {
        let hash = SHA256.hash(data: blob)
        let b64 = Data(hash).base64EncodedString()
        // Remove trailing '=' padding to match ssh-keygen output
        let trimmed = b64.replacingOccurrences(of: "=", with: "")
        return "SHA256:\(trimmed)"
    }

    /// Format public key as OpenSSH authorized_keys line
    static func formatOpenSSHPublicKey(blob: Data, comment: String) -> String {
        let b64 = blob.base64EncodedString()
        return "ecdsa-sha2-nistp256 \(b64) \(comment)"
    }

    // MARK: - Internal

    private func setEntries(_ newEntries: [SSHKeyCacheEntry]) {
        lock.lock()
        _entries = newEntries
        lock.unlock()
    }

    // MARK: - Private

    private func chainSync(ble: BLEManager, count: Int, index: Int,
                           result: [SSHKeyCacheEntry],
                           completion: @escaping ([SSHKeyCacheEntry]) -> Void) {
        guard index < count else {
            completion(result)
            return
        }

        // Read full 112B entry via KEY_READ only (no KEY_GETPUB — avoids callback race)
        // Entry layout: name[16] + pubkey_LE[64] + privkey[32]
        ble.readKeyEntry(cat: .ssh, idx: UInt8(index)) { [weak self] entryData in
            guard let self = self else {
                completion(result)
                return
            }

            var updated = result
            if let data = entryData, data.count >= 80 {
                // Extract name (bytes 0-15)
                let nameData = data[0..<16].prefix(while: { $0 != 0 })
                let name = String(data: nameData, encoding: .utf8) ?? ""

                // Extract pubkey LE (bytes 16-79), convert to BE
                let pubkeyLE = data[16..<80]
                let pubkeyBE = ble.convertEndianness64(pubkeyLE)

                let blob = SSHKeyCache.buildSSHPublicKeyBlob(publicKey: pubkeyBE)
                let fp = SSHKeyCache.computeFingerprint(blob: blob)
                updated.append(SSHKeyCacheEntry(
                    index: index,
                    name: name,
                    publicKeyBlob: blob,
                    fingerprint: fp
                ))
            }
            self.chainSync(ble: ble, count: count, index: index + 1,
                          result: updated, completion: completion)
        }
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        do {
            let data = try Data(contentsOf: cacheURL)
            let loaded = try JSONDecoder().decode([SSHKeyCacheEntry].self, from: data)
            lock.lock()
            _entries = loaded
            lock.unlock()
            NSLog("SSHKeyCache: loaded %d entries from disk", loaded.count)
        } catch {
            NSLog("SSHKeyCache: failed to load: %@", error.localizedDescription)
        }
    }

    private func saveToDisk() {
        lock.lock()
        let snapshot = _entries
        lock.unlock()
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            NSLog("SSHKeyCache: failed to save: %@", error.localizedDescription)
        }
    }
}

// MARK: - Data SSH Helpers

extension Data {
    /// Append an SSH string (uint32 length prefix + bytes)
    mutating func appendSSHString(_ string: String) {
        let bytes = Array(string.utf8)
        appendSSHUInt32(UInt32(bytes.count))
        append(contentsOf: bytes)
    }

    /// Append SSH string from raw data
    mutating func appendSSHString(_ data: Data) {
        appendSSHUInt32(UInt32(data.count))
        append(data)
    }

    /// Append a big-endian uint32
    mutating func appendSSHUInt32(_ value: UInt32) {
        var be = value.bigEndian
        append(Data(bytes: &be, count: 4))
    }

    /// Append an SSH mpint (big-endian integer with sign bit handling)
    mutating func appendSSHMpint(_ data: Data) {
        if data.isEmpty {
            appendSSHUInt32(0)
            return
        }
        // If high bit is set, prepend 0x00 to indicate positive
        if data[data.startIndex] & 0x80 != 0 {
            appendSSHUInt32(UInt32(data.count + 1))
            append(0x00)
            append(data)
        } else {
            appendSSHUInt32(UInt32(data.count))
            append(data)
        }
    }

    /// Read a big-endian uint32 at offset
    func readSSHUInt32(at offset: Int) -> UInt32? {
        guard offset + 4 <= count else { return nil }
        return UInt32(self[offset]) << 24
             | UInt32(self[offset + 1]) << 16
             | UInt32(self[offset + 2]) << 8
             | UInt32(self[offset + 3])
    }

    /// Read an SSH string at offset, returns (data, bytesConsumed)
    func readSSHString(at offset: Int) -> (Data, Int)? {
        guard let len = readSSHUInt32(at: offset) else { return nil }
        let start = offset + 4
        let end = start + Int(len)
        guard end <= count else { return nil }
        return (subdata(in: start..<end), 4 + Int(len))
    }
}
