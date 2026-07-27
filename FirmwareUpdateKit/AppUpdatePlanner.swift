import Foundation

/// App 自升级判定（纯逻辑，可单测）：解析 GitHub Release、比较版本、挑安装包。
/// 只认正式版：/releases/latest 端点本身不返回 prerelease/draft，
/// 这里再对 prerelease 标记与 tag 预发布后缀（-beta/-rc 等）做双保险。
public enum AppUpdatePlanner {

    /// GitHub /releases/latest 响应中用到的字段
    public struct Release: Decodable, Equatable {
        public struct Asset: Decodable, Equatable {
            public let name: String
            public let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }

            public init(name: String, browserDownloadURL: URL) {
                self.name = name
                self.browserDownloadURL = browserDownloadURL
            }
        }

        public let tagName: String
        public let prerelease: Bool
        public let draft: Bool
        public let body: String?
        public let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case prerelease, draft, body, assets
        }

        public init(tagName: String, prerelease: Bool, draft: Bool,
                    body: String?, assets: [Asset]) {
            self.tagName = tagName
            self.prerelease = prerelease
            self.draft = draft
            self.body = body
            self.assets = assets
        }
    }

    public static func decodeRelease(from data: Data) throws -> Release {
        try JSONDecoder().decode(Release.self, from: data)
    }

    /// "v1.4.2" / "1.20.0-beta.1" → 三段核心版本 + 是否带预发布后缀
    public static func parseTag(_ tag: String) -> (core: FirmwareVersion, isPrerelease: Bool)? {
        var s = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let isPrerelease = s.contains("-")
        if let dash = s.firstIndex(of: "-") { s = String(s[..<dash]) }
        guard let core = FirmwareVersion(s) else { return nil }
        return (core, isPrerelease)
    }

    /// 应升级到的版本号（nil = 无需升级或 release 不是正式版）：
    /// - release 是 prerelease/draft 或 tag 带预发布后缀 → 不升
    /// - latest 核心版本 > 本机 → 升
    /// - 核心版本相同但本机是预发布构建（如 1.20.0-beta.1 → 1.20.0 正式版）→ 升
    public static func updateTarget(installed: String, release: Release) -> String? {
        guard !release.prerelease, !release.draft,
              let latest = parseTag(release.tagName), !latest.isPrerelease,
              let inst = parseTag(installed) else { return nil }
        if latest.core > inst.core { return latest.core.description }
        if latest.core == inst.core && inst.isPrerelease { return latest.core.description }
        return nil
    }

    /// release 资产中的安装包（CI 产物 immurok-<version>.pkg）
    public static func pkgAsset(in release: Release) -> Release.Asset? {
        release.assets.first { $0.name.hasSuffix(".pkg") }
    }
}
