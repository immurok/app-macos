// FirmwareUpdateKit/UpdateManifest.swift
import Foundation

public enum ManifestError: Error, Equatable {
    case unsupportedSchema(Int)
}

/// 官网固件更新清单（spec §1）。字段增改须 bump schema。
public struct UpdateManifest: Decodable {
    public struct Asset: Decodable {
        public let version: String
        public let secVersion: Int?
        public let format: String        // "v1" | "v2"
        public let url: URL
        public let sha256: String
        public let size: Int?
        public let minDirect: String?    // 仅 latest 使用
        public let notes: String?        // 英文发布说明（仅 latest 使用）

        enum CodingKeys: String, CodingKey {
            case version, format, url, sha256, size, notes
            case secVersion = "sec_version"
            case minDirect = "min_direct"
        }
    }

    public let schema: Int
    public let latest: Asset
    public let bridge: Asset?

    public static func decode(from data: Data) throws -> UpdateManifest {
        let m = try JSONDecoder().decode(UpdateManifest.self, from: data)
        guard m.schema == 1 else { throw ManifestError.unsupportedSchema(m.schema) }
        return m
    }
}
