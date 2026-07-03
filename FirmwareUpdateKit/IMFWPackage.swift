import Foundation

public enum IMFWError: Error, Equatable {
    case truncated
    case badMagic
    case unsupportedVersion(UInt8)
    case sizeMismatch
    case tooLarge
}

/// .imfw 包解析（对照 ota/ota-update.py parse_imfw）
/// v1: 96B header (HMAC, ≤1.5.x)；v2: 128B header (ECDSA, 1.6.0+)
public struct IMFWPackage {
    public static let magic: UInt32 = 0x494D4657  // "IMFW"
    public static let headerSizeV1 = 96
    public static let headerSizeV2 = 128
    public static let imageBSize = 216 * 1024

    public let header: Data
    public let encryptedFirmware: Data
    public let formatVersion: UInt8
    public let hwId: UInt16
    public let fwSize: UInt32
    public let secVersion: UInt16?  // 仅 v2

    public init(data: Data) throws {
        guard data.count >= Self.headerSizeV1 else { throw IMFWError.truncated }
        let magic = data.readU32LE(at: 0)
        guard magic == Self.magic else { throw IMFWError.badMagic }
        let version = data[data.startIndex + 4]
        guard version == 1 || version == 2 else { throw IMFWError.unsupportedVersion(version) }
        let headerSize = version >= 2 ? Self.headerSizeV2 : Self.headerSizeV1
        guard data.count >= headerSize else { throw IMFWError.truncated }

        formatVersion = version
        hwId = data.readU16LE(at: 6)
        fwSize = data.readU32LE(at: 8)
        secVersion = version >= 2 ? data.readU16LE(at: 0x0C) : nil
        header = data.prefix(headerSize)
        encryptedFirmware = data.dropFirst(headerSize)

        guard fwSize <= Self.imageBSize, encryptedFirmware.count <= Self.imageBSize else {
            throw IMFWError.tooLarge
        }
        // 密文按 16B 对齐可能略大于 fw_size，但绝不应小于
        guard encryptedFirmware.count >= Int(fwSize) else { throw IMFWError.sizeMismatch }
    }
}

extension Data {
    func readU16LE(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | (UInt16(self[i + 1]) << 8)
    }
    func readU32LE(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | (UInt32(self[i + 1]) << 8)
            | (UInt32(self[i + 2]) << 16) | (UInt32(self[i + 3]) << 24)
    }
}
