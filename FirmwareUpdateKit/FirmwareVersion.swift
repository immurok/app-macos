import Foundation

/// 固件语义化版本 "MAJOR.MINOR.PATCH"（设备 DIS 2A26 与 manifest 均用此格式）
public struct FirmwareVersion: Comparable, Equatable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let ma = Int(parts[0]), let mi = Int(parts[1]), let pa = Int(parts[2]),
              ma >= 0, mi >= 0, pa >= 0 else { return nil }
        major = ma; minor = mi; patch = pa
    }

    public static func < (lhs: FirmwareVersion, rhs: FirmwareVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}
