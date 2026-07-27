import XCTest
@testable import FirmwareUpdateKit

final class AppUpdatePlannerTests: XCTestCase {

    private func release(tag: String, prerelease: Bool = false, draft: Bool = false,
                         assets: [AppUpdatePlanner.Release.Asset] = []) -> AppUpdatePlanner.Release {
        AppUpdatePlanner.Release(tagName: tag, prerelease: prerelease, draft: draft,
                                 body: nil, assets: assets)
    }

    // MARK: - parseTag

    func testParseTagStripsVPrefix() {
        let parsed = AppUpdatePlanner.parseTag("v1.4.2")
        XCTAssertEqual(parsed?.core.description, "1.4.2")
        XCTAssertEqual(parsed?.isPrerelease, false)
    }

    func testParseTagWithoutPrefix() {
        let parsed = AppUpdatePlanner.parseTag("1.4.2")
        XCTAssertEqual(parsed?.core.description, "1.4.2")
    }

    func testParseTagPrereleaseSuffix() {
        let parsed = AppUpdatePlanner.parseTag("v1.20.0-beta.1")
        XCTAssertEqual(parsed?.core.description, "1.20.0")
        XCTAssertEqual(parsed?.isPrerelease, true)
    }

    func testParseTagInvalid() {
        XCTAssertNil(AppUpdatePlanner.parseTag("garbage"))
        XCTAssertNil(AppUpdatePlanner.parseTag("v1.2"))
    }

    // MARK: - updateTarget

    func testNewerStableRelease() {
        XCTAssertEqual(AppUpdatePlanner.updateTarget(installed: "1.4.2",
                                                     release: release(tag: "v1.5.0")), "1.5.0")
    }

    func testSameVersionNoUpdate() {
        XCTAssertNil(AppUpdatePlanner.updateTarget(installed: "1.4.2",
                                                   release: release(tag: "v1.4.2")))
    }

    func testOlderReleaseNoUpdate() {
        XCTAssertNil(AppUpdatePlanner.updateTarget(installed: "1.5.0",
                                                   release: release(tag: "v1.4.2")))
    }

    func testPrereleaseFlagSkipped() {
        XCTAssertNil(AppUpdatePlanner.updateTarget(installed: "1.4.2",
                                                   release: release(tag: "v1.5.0", prerelease: true)))
    }

    func testDraftSkipped() {
        XCTAssertNil(AppUpdatePlanner.updateTarget(installed: "1.4.2",
                                                   release: release(tag: "v1.5.0", draft: true)))
    }

    func testPrereleaseTagSuffixSkipped() {
        // 即使 prerelease 标记缺失，tag 带 -beta/-rc 后缀也不升
        XCTAssertNil(AppUpdatePlanner.updateTarget(installed: "1.4.2",
                                                   release: release(tag: "v1.5.0-beta.1")))
        XCTAssertNil(AppUpdatePlanner.updateTarget(installed: "1.4.2",
                                                   release: release(tag: "v1.5.0-rc.2")))
    }

    func testInstalledPrereleaseUpgradesToSameCoreStable() {
        // 本机跑 1.20.0-beta.1，正式版 1.20.0 发布 → 应升级
        XCTAssertEqual(AppUpdatePlanner.updateTarget(installed: "1.20.0-beta.1",
                                                     release: release(tag: "v1.20.0")), "1.20.0")
    }

    func testUnparseableInstalledVersionNoUpdate() {
        XCTAssertNil(AppUpdatePlanner.updateTarget(installed: "dev",
                                                   release: release(tag: "v1.5.0")))
    }

    // MARK: - pkgAsset

    func testPkgAssetPicked() {
        let pkg = AppUpdatePlanner.Release.Asset(
            name: "immurok-1.5.0.pkg",
            browserDownloadURL: URL(string: "https://example.com/immurok-1.5.0.pkg")!)
        let other = AppUpdatePlanner.Release.Asset(
            name: "checksums.txt",
            browserDownloadURL: URL(string: "https://example.com/checksums.txt")!)
        XCTAssertEqual(AppUpdatePlanner.pkgAsset(in: release(tag: "v1.5.0", assets: [other, pkg])), pkg)
    }

    func testPkgAssetMissing() {
        XCTAssertNil(AppUpdatePlanner.pkgAsset(in: release(tag: "v1.5.0")))
    }

    // MARK: - decode

    func testDecodeGitHubReleaseJSON() throws {
        let json = """
        {
          "tag_name": "v1.5.0",
          "draft": false,
          "prerelease": false,
          "body": "Release notes",
          "assets": [
            {
              "name": "immurok-1.5.0.pkg",
              "browser_download_url": "https://github.com/immurok/app-macos/releases/download/v1.5.0/immurok-1.5.0.pkg",
              "size": 12345
            }
          ]
        }
        """.data(using: .utf8)!
        let rel = try AppUpdatePlanner.decodeRelease(from: json)
        XCTAssertEqual(rel.tagName, "v1.5.0")
        XCTAssertFalse(rel.prerelease)
        XCTAssertEqual(rel.body, "Release notes")
        XCTAssertEqual(rel.assets.first?.name, "immurok-1.5.0.pkg")
    }
}
