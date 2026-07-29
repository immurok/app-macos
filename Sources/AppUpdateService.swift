// Sources/AppUpdateService.swift
import Foundation
import AppKit
import FirmwareUpdateKit

/// App 自升级：GitHub Releases 检查（仅正式版，跳过 beta/rc）→ 下载签名 pkg
/// → 本地校验 Developer ID 签名 → 交系统安装器安装（postinstall 处理 PAM 等）。
/// 状态经 @Published state 驱动 UI；同一时刻仅允许一次下载流程。
@MainActor
final class AppUpdateService: ObservableObject {

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(version: String, notes: String?)
        case downloading
        case installerOpened(version: String)   // 已移交系统安装器
        case failed(message: String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var updateAvailable = false  // 菜单栏橙点 + 菜单项

    static let latestReleaseURL = URL(string: "https://api.github.com/repos/immurok/app-macos/releases/latest")!
    static let checkInterval: TimeInterval = 24 * 3600
    /// 下载的 pkg 必须由本项目 Developer ID Team 签名（URLSession 下载无
    /// quarantine 标记，Gatekeeper 不会替我们把关，必须自验）
    static let expectedTeamID = "UH43X23J62"

    // UserDefaults keys
    private static let kLastCheck = "immurok.appupdate.lastCheck"
    private static let kNotifiedVersion = "immurok.appupdate.notifiedVersion"

    private var release: AppUpdatePlanner.Release?
    private var pendingVersion: String?
    private var downloadTask: Task<Void, Never>?
    private var timer: Timer?

    var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    init() {
        // 启动 15s 后首查（避开启动高峰），此后每 6h 复查（checkIfDue 内部按 24h 去重）
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            self?.checkIfDue()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
    }

    // MARK: - 检查

    /// 24h 内不重复（force 忽略间隔，供"检查更新"按钮）。检查失败静默，手动检查时提示。
    func checkIfDue(force: Bool = false) {
        let last = UserDefaults.standard.double(forKey: Self.kLastCheck)
        if !force && Date().timeIntervalSince1970 - last < Self.checkInterval { return }
        switch state {
        case .checking, .downloading: return
        default: break
        }
        state = .checking
        Task {
            do {
                var req = URLRequest(url: Self.latestReleaseURL)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, resp) = try await URLSession.shared.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                // 仓库还没有任何正式 Release → 404，视为已是最新
                if status == 404 {
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.kLastCheck)
                    finishCheck(target: nil, notes: nil)
                    return
                }
                guard status == 200 else { throw URLError(.badServerResponse) }
                let rel = try AppUpdatePlanner.decodeRelease(from: data)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.kLastCheck)
                release = rel
                finishCheck(target: AppUpdatePlanner.updateTarget(installed: installedVersion, release: rel),
                            notes: rel.body)
            } catch {
                if force { state = .failed(message: "appupdate.error.check".localized) }
                else { state = .idle }
            }
        }
    }

    private func finishCheck(target: String?, notes: String?) {
        guard let target else {
            updateAvailable = false
            pendingVersion = nil
            state = .upToDate
            return
        }
        updateAvailable = true
        pendingVersion = target
        state = .updateAvailable(version: target, notes: notes)
        // 每个版本只弹一次系统通知，避免每 24h 检查重复打扰
        let notified = UserDefaults.standard.string(forKey: Self.kNotifiedVersion)
        if notified != target {
            UserDefaults.standard.set(target, forKey: Self.kNotifiedVersion)
            NotificationCenter.default.post(name: .appUpdateAvailable, object: target)
        }
    }

    /// 更新窗口关闭时调用：终态（已最新/失败）复位到 idle，下次打开重新检查。
    /// 下载中与「安装器已打开」保留（后者对用户仍有意义）。
    func resetIfInactive() {
        switch state {
        case .upToDate, .failed:
            state = .idle
        default:
            break
        }
    }

    // MARK: - 下载 + 安装

    func downloadAndInstall() {
        guard downloadTask == nil, let rel = release, let version = pendingVersion,
              let asset = AppUpdatePlanner.pkgAsset(in: rel) else { return }
        downloadTask = Task {
            await runDownloadAndInstall(version: version, asset: asset)
            downloadTask = nil
        }
    }

    private func runDownloadAndInstall(version: String, asset: AppUpdatePlanner.Release.Asset) async {
        state = .downloading
        do {
            let (tmp, resp) = try await URLSession.shared.download(from: asset.browserDownloadURL)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("immurok-appupdate", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let pkgURL = dir.appendingPathComponent("immurok-\(version).pkg")
            try? FileManager.default.removeItem(at: pkgURL)
            try FileManager.default.moveItem(at: tmp, to: pkgURL)

            guard await Self.verifyPkgSignature(at: pkgURL, teamID: Self.expectedTeamID) else {
                try? FileManager.default.removeItem(at: pkgURL)
                state = .failed(message: "appupdate.error.verify".localized)
                return
            }
            NSWorkspace.shared.open(pkgURL)
            // 装完这个版本后允许下个版本再弹通知
            UserDefaults.standard.removeObject(forKey: Self.kNotifiedVersion)
            state = .installerOpened(version: version)
            watchForInstallAndRelaunch(version: version)
        } catch {
            state = .failed(message: "appupdate.error.download".localized)
        }
    }

    /// 安装器交给用户后轮询磁盘上的 bundle 版本；检测到已替换为目标版本
    /// 即自动重启（老进程继续跑的是内存里的旧版本，不重启版本不生效）。
    /// 15 分钟内未完成视为用户取消，静默复位。
    private func watchForInstallAndRelaunch(version: String) {
        Task { [weak self] in
            let plistPath = "/Applications/immurok.app/Contents/Info.plist"
            let deadline = Date().addingTimeInterval(15 * 60)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let dict = NSDictionary(contentsOfFile: plistPath),
                   let onDisk = dict["CFBundleShortVersionString"] as? String,
                   onDisk == version {
                    // 再等 2s 让 Installer 完成收尾（postinstall/收据落盘）
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    Self.relaunch()
                    return
                }
            }
            self?.state = .idle
        }
    }

    /// 先派生一个脱离本进程的 shell 延迟重开 App，再退出自己。
    /// applicationWillTerminate 会正常停掉 BLE/PAM 等服务。
    nonisolated private static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"/Applications/immurok.app\""]
        try? p.run()
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    /// pkgutil --check-signature：必须能验签且证书链是本 Team 的 Developer ID Installer
    nonisolated private static func verifyPkgSignature(at url: URL, teamID: String) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
                p.arguments = ["--check-signature", url.path]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = Pipe()
                do { try p.run() } catch {
                    cont.resume(returning: false)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let out = String(data: data, encoding: .utf8) ?? ""
                cont.resume(returning: p.terminationStatus == 0
                            && out.contains("Developer ID Installer")
                            && out.contains("(\(teamID))"))
            }
        }
    }
}
