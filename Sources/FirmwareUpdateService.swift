// Sources/FirmwareUpdateService.swift
import Foundation
import CryptoKit
import FirmwareUpdateKit

/// 固件升级编排：检查 → 下载 → 预检 → 一跳/两跳推送 → 跨重启续跳。
/// 全部状态经 @Published state 驱动 UI；同一时刻仅允许一次升级流程。
@MainActor
final class FirmwareUpdateService: ObservableObject {

    enum State: Equatable {
        case idle
        case checking
        case updateAvailable(target: String, notes: String?)
        case downloading
        case updating(progressText: String, fraction: Double)  // 两跳合并进度
        case waitingReconnect
        case success(version: String)
        case failed(message: String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var updateAvailable = false  // 菜单栏红点
    /// 设备低于强制底线版本（旧签名纪元），必须升级才能正常使用
    @Published private(set) var mandatoryUpdate = false

    /// 强制升级底线：低于此版本的设备连接后立刻要求升级
    static let mandatoryMinVersion = "1.6.0"
    private var lastEnforcedVersion: String?

    static let manifestURL = URL(string: "https://immurok.com/fw/manifest.json")!
    static let telemetryURL = URL(string: "https://immurok.com/api/t")!
    static let checkInterval: TimeInterval = 24 * 3600
    static let reconnectTimeout: TimeInterval = 60
    static let minBatteryPct = 30

    // UserDefaults keys
    private static let kLastCheck = "immurok.fwupdate.lastCheck"
    private static let kPendingTarget = "immurok.fwupdate.pendingTargetVersion"
    private static let kPendingFile = "immurok.fwupdate.pendingTargetFile"
    private static let kTelemetryEnabled = "immurok.telemetry.enabled"
    private static let kClientID = "immurok.telemetry.clientId"
    private static let kNotifiedVersion = "immurok.fwupdate.notifiedVersion"

    private let bleManager: BLEManager
    private weak var viewModel: AppViewModel?
    private var manifest: UpdateManifest?
    private var updateTask: Task<Void, Never>?
    let telemetry: TelemetryClient

    init(bleManager: BLEManager, viewModel: AppViewModel) {
        self.bleManager = bleManager
        self.viewModel = viewModel

        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.kClientID) == nil {
            defaults.set(UUID().uuidString, forKey: Self.kClientID)
        }
        if defaults.object(forKey: Self.kTelemetryEnabled) == nil {
            defaults.set(true, forKey: Self.kTelemetryEnabled)  // 默认开启（spec §5）
        }
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        telemetry = TelemetryClient(
            clientID: defaults.string(forKey: Self.kClientID)!,
            appVersion: appVersion,
            isEnabled: { defaults.bool(forKey: Self.kTelemetryEnabled) },
            sender: { data in
                var req = URLRequest(url: Self.telemetryURL)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = data
                URLSession.shared.dataTask(with: req).resume()  // fire-and-forget
            })
    }

    // MARK: - 强制升级

    /// 设备连接/上报版本后调用：低于 mandatoryMinVersion 的旧设备立刻要求升级
    /// （自动弹出固件窗口 + 触发检查）。同一版本只自动弹一次，避免每次状态包重复打扰。
    func enforceMinimumIfNeeded() {
        guard let raw = viewModel?.firmwareVersion,
              let dev = FirmwareVersion(Self.normalizeSemver(raw)),
              let floor = FirmwareVersion(Self.mandatoryMinVersion) else {
            mandatoryUpdate = false
            return
        }
        let below = dev < floor
        mandatoryUpdate = below
        guard below else { lastEnforcedVersion = nil; return }
        // 升级/等待重连中不打扰
        switch state {
        case .updating, .waitingReconnect, .downloading: return
        default: break
        }
        // 同一设备版本只自动弹一次窗口。用归一化版本去重：DIS 报 "1.3.11"、
        // GET_STATUS 报 "1.3.11.<build>"，同一版本两种原始串都会过去重、导致重复弹窗抢焦点。
        let normalized = Self.normalizeSemver(raw)
        if lastEnforcedVersion == normalized { return }
        lastEnforcedVersion = normalized
        NotificationCenter.default.post(name: .openFirmwareUpdateWindow, object: nil)
    }

    // MARK: - 检查

    /// 设备连接就绪后调用；24h 内不重复（force 忽略间隔，供“检查更新”按钮）。
    func checkIfDue(force: Bool = false) {
        let last = UserDefaults.standard.double(forKey: Self.kLastCheck)
        if !force && Date().timeIntervalSince1970 - last < Self.checkInterval { return }
        guard let deviceVersion = viewModel?.firmwareVersion else { return }
        if case .updating = state { return }  // 升级中不检查

        state = .checking
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: Self.manifestURL)
                let m = try UpdateManifest.decode(from: data)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.kLastCheck)
                self.manifest = m
                let plan = UpdatePlanner.plan(device: Self.normalizeSemver(deviceVersion),
                                              latest: m.latest.version,
                                              minDirect: m.latest.minDirect)
                let available = plan != .upToDate && plan != .unknown
                self.updateAvailable = available
                telemetry.send(.fwCheck(deviceVersion: deviceVersion,
                                        latestVersion: m.latest.version,
                                        updateAvailable: available))
                if available {
                    state = .updateAvailable(target: m.latest.version,
                                             notes: m.latest.notes)
                    telemetry.send(.fwPromptShown(from: deviceVersion, to: m.latest.version))
                    // 明确升级提示：每个版本只弹一次系统通知，避免每 24h 检查重复打扰
                    let notified = UserDefaults.standard.string(forKey: Self.kNotifiedVersion)
                    if notified != m.latest.version {
                        UserDefaults.standard.set(m.latest.version, forKey: Self.kNotifiedVersion)
                        NotificationCenter.default.post(name: .firmwareUpdateAvailable,
                                                        object: m.latest.version)
                    }
                } else {
                    state = .idle
                }
            } catch {
                // 检查失败静默（spec §3），手动检查时给出提示
                if force { state = .failed(message: "fwupdate.error.check".localized) }
                else { state = .idle }
            }
        }
    }

    /// 固件窗口关闭时调用：把停留在终态（可用/成功/失败）的状态复位到 idle，
    /// 这样下次打开窗口 onAppear 能重新检查。升级流程进行中（检查/下载/推送/
    /// 等待重连）不复位，避免丢掉正在跑的进度显示。
    func resetIfInactive() {
        if updateTask != nil { return }
        switch state {
        case .checking, .downloading, .updating, .waitingReconnect:
            return
        case .idle, .updateAvailable, .success, .failed:
            state = .idle
        }
    }

    // MARK: - 升级入口

    func startUpdate() {
        guard updateTask == nil, let m = manifest,
              let deviceVersion = viewModel?.firmwareVersion else { return }
        updateTask = Task {
            await runUpdate(manifest: m, deviceVersion: deviceVersion)
            updateTask = nil
        }
    }

    private func runUpdate(manifest m: UpdateManifest, deviceVersion: String) async {
        let plan = UpdatePlanner.plan(device: Self.normalizeSemver(deviceVersion), latest: m.latest.version,
                                      minDirect: m.latest.minDirect)
        let hops: [(role: String, version: String)]
        switch plan {
        case .direct:      hops = [("final", m.latest.version)]
        case .bridgeOnly:  hops = [("bridge", m.bridge?.version ?? m.latest.version)]
        case .twoHops:     hops = [("bridge", m.bridge?.version ?? UpdatePlanner.fallbackMinDirect),
                                   ("final", m.latest.version)]
        default: return
        }
        telemetry.send(.fwUpdateStarted(from: deviceVersion, to: m.latest.version, hops: hops.count))
        let t0 = Date()

        // 预检
        guard preflight() else { return }

        // 下载目标包（桥包优先用内置）
        state = .downloading
        let targetData: Data
        do {
            targetData = try await download(asset: m.latest)
        } catch {
            state = .failed(message: "fwupdate.error.download".localized)
            telemetry.send(.fwUpdateFailed(stage: "download", errorCode: "download_failed", hop: "final"))
            return
        }

        // 逐跳执行
        var completedHops = 0.0
        var retries = 0
        let totalHops = Double(hops.count)
        for (idx, hop) in hops.enumerated() {
            let hopStart = Date()
            let pkgData: Data
            if hop.role == "bridge" {
                guard let bridge = await loadBridgePackage(manifest: m) else {
                    state = .failed(message: "fwupdate.error.bridge".localized)
                    telemetry.send(.fwUpdateFailed(stage: "download", errorCode: "bridge_missing", hop: "bridge"))
                    return
                }
                pkgData = bridge
            } else {
                pkgData = targetData
            }

            do {
                let pkg = try IMFWPackage(data: pkgData)
                try await pushWithRetry(pkg, label: hop.version,
                                        baseFraction: completedHops / totalHops,
                                        hopWeight: 1.0 / totalHops,
                                        retries: &retries)
            } catch let e as OTAEngineError {
                let (msgKey, code) = Self.mapEngineError(e)
                state = .failed(message: msgKey.localized)
                telemetry.send(.fwUpdateFailed(stage: Self.isVerifyError(e) ? "verify" : "transfer",
                                               errorCode: code, hop: hop.role))
                return
            } catch {
                state = .failed(message: "fwupdate.error.generic".localized)
                telemetry.send(.fwUpdateFailed(stage: "transfer", errorCode: "package_error", hop: hop.role))
                return
            }
            completedHops += 1.0

            // 等设备重启重连 + 版本核对
            state = .waitingReconnect
            let reconnected = await waitForVersion(hop.version, timeout: Self.reconnectTimeout)
            guard reconnected else {
                state = .failed(message: "fwupdate.error.reconnect".localized)
                telemetry.send(.fwUpdateFailed(stage: "reconnect", errorCode: "timeout", hop: hop.role))
                return
            }
            telemetry.send(.fwHopDone(hop: hop.role,
                                      durationMs: Int(Date().timeIntervalSince(hopStart) * 1000)))
            // 本跳已确认重连成功；若后面还有跳，持久化待执行的最终包以便崩溃/退出后续跳
            if hops.count == 2 && idx == 0 {
                persistPendingHop(target: m.latest.version, fileData: targetData)
            }
        }

        clearPendingHop()
        updateAvailable = false
        state = .success(version: m.latest.version)
        UserDefaults.standard.removeObject(forKey: Self.kNotifiedVersion)  // 已升级，允许下个版本再提示
        NotificationCenter.default.post(name: .firmwareUpdateFinished, object: m.latest.version)
        telemetry.send(.fwUpdateSuccess(from: deviceVersion, to: m.latest.version,
                                        totalDurationMs: Int(Date().timeIntervalSince(t0) * 1000),
                                        retries: retries))
    }

    /// 断连/超时类错误自动重试一次（从 ERASE 重来，spec §2）；验签类错误不重试。
    private func pushWithRetry(_ pkg: IMFWPackage, label: String,
                               baseFraction: Double, hopWeight: Double,
                               retries: inout Int) async throws {
        let engine = OTAEngine(transport: bleManager)
        let progressCb: (Double) -> Void = { [weak self] p in
            Task { @MainActor in
                self?.state = .updating(progressText: label, fraction: baseFraction + p * hopWeight)
            }
        }
        state = .updating(progressText: label, fraction: baseFraction)
        do {
            try await engine.push(pkg, progress: progressCb)
        } catch let e as OTAEngineError where Self.isRetryable(e) {
            retries += 1
            try await engine.push(pkg, progress: progressCb)
        }
    }

    static func isRetryable(_ e: OTAEngineError) -> Bool {
        switch e {
        case .noResponse, .writeFailed: return true
        default: return false
        }
    }

    static func isVerifyError(_ e: OTAEngineError) -> Bool {
        switch e {
        case .sha256Mismatch, .signatureMismatch, .headerRejected: return true
        default: return false
        }
    }

    // MARK: - 续跳恢复（App 启动/设备重连时调用）

    func resumePendingHopIfAny() {
        guard updateTask == nil else { return }  // 不与进行中的升级流程并发（关键：防两跳期间重连触发二次推送）
        switch state {
        case .checking, .downloading, .updating, .waitingReconnect: return
        default: break
        }
        let defaults = UserDefaults.standard
        guard let target = defaults.string(forKey: Self.kPendingTarget),
              let path = defaults.string(forKey: Self.kPendingFile),
              let deviceRaw = viewModel?.firmwareVersion,
              let deviceSem = FirmwareVersion(Self.normalizeSemver(deviceRaw)),
              let targetSem = FirmwareVersion(target) else { return }
        // 已达目标版本 → 完成，清除
        if deviceSem >= targetSem { clearPendingHop(); return }
        // 只有设备已 >= 桥(minDirect) 才能收 final(v2) 包；否则说明桥那跳没成，放弃续跳、清除待走完整流程
        guard let gate = FirmwareVersion(UpdatePlanner.fallbackMinDirect), deviceSem >= gate else {
            clearPendingHop(); return
        }
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            clearPendingHop(); return
        }
        telemetry.send(.fwUpdateResumed(pendingHop: "final"))
        updateTask = Task {
            guard preflight() else { updateTask = nil; return }
            do {
                let pkg = try IMFWPackage(data: data)
                state = .updating(progressText: target, fraction: 0)
                try await OTAEngine(transport: bleManager).push(pkg) { [weak self] p in
                    Task { @MainActor in
                        self?.state = .updating(progressText: target, fraction: p)
                    }
                }
                state = .waitingReconnect
                if await waitForVersion(target, timeout: Self.reconnectTimeout) {
                    clearPendingHop()
                    updateAvailable = false
                    state = .success(version: target)
                    UserDefaults.standard.removeObject(forKey: Self.kNotifiedVersion)
                    NotificationCenter.default.post(name: .firmwareUpdateFinished, object: target)
                } else {
                    state = .failed(message: "fwupdate.error.reconnect".localized)
                }
            } catch {
                state = .failed(message: "fwupdate.error.generic".localized)
            }
            updateTask = nil
        }
    }

    // MARK: - Helpers

    private func preflight() -> Bool {
        guard let vm = viewModel else { return false }
        guard vm.isDeviceConnected, bleManager.isOTAAvailable else {
            state = .failed(message: "fwupdate.error.notconnected".localized)
            telemetry.send(.fwUpdateFailed(stage: "preflight", errorCode: "not_connected", hop: "-"))
            return false
        }
        if let batt = vm.batteryLevel, batt < Self.minBatteryPct {
            state = .failed(message: "fwupdate.error.battery".localized)
            telemetry.send(.fwUpdateFailed(stage: "preflight", errorCode: "low_battery", hop: "-"))
            return false
        }
        guard !vm.isPairing else {
            state = .failed(message: "fwupdate.error.busy".localized)
            telemetry.send(.fwUpdateFailed(stage: "preflight", errorCode: "device_busy", hop: "-"))
            return false
        }
        return true
    }

    private func download(asset: UpdateManifest.Asset) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: asset.url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == asset.sha256.lowercased() else {
            throw URLError(.cannotParseResponse)  // sha 不符按下载失败处理
        }
        _ = try IMFWPackage(data: data)  // 预解析把关
        return data
    }

    /// 桥包：优先 App 内置，manifest.bridge.sha256 不一致时改用下载版（spec §1）
    private func loadBridgePackage(manifest m: UpdateManifest) async -> Data? {
        let bundled = Bundle.main.url(forResource: "fw-1.6.0-bridge", withExtension: "imfw")
            .flatMap { try? Data(contentsOf: $0) }
        guard let bridgeAsset = m.bridge else { return bundled }
        if let b = bundled {
            let digest = SHA256.hash(data: b).map { String(format: "%02x", $0) }.joined()
            if digest == bridgeAsset.sha256.lowercased() { return b }
        }
        // 内置缺失或与 manifest 不符 → 下载；下载失败仍回退内置
        return (try? await download(asset: bridgeAsset)) ?? bundled
    }

    /// 轮询等待设备重连且 2A26/status 上报的版本 >= 目标版本（容忍第 4 段 build）
    private func waitForVersion(_ version: String, timeout: TimeInterval) async -> Bool {
        guard let target = FirmwareVersion(Self.normalizeSemver(version)) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let raw = viewModel?.firmwareVersion,
               let dev = FirmwareVersion(Self.normalizeSemver(raw)), dev >= target {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    private func persistPendingHop(target: String, fileData: Data) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".immurok/fwupdate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("pending-target.imfw")
        try? fileData.write(to: file)
        UserDefaults.standard.set(target, forKey: Self.kPendingTarget)
        UserDefaults.standard.set(file.path, forKey: Self.kPendingFile)
    }

    private func clearPendingHop() {
        if let path = UserDefaults.standard.string(forKey: Self.kPendingFile) {
            try? FileManager.default.removeItem(atPath: path)
        }
        UserDefaults.standard.removeObject(forKey: Self.kPendingTarget)
        UserDefaults.standard.removeObject(forKey: Self.kPendingFile)
    }

    /// 设备版本可能带第 4 段 build（getStatus 格式 "a.b.c.build"），归一到 3 段 semver。
    static func normalizeSemver(_ raw: String) -> String {
        let parts = raw.split(separator: ".")
        guard parts.count >= 3 else { return raw }
        return parts.prefix(3).joined(separator: ".")
    }

    static func mapEngineError(_ e: OTAEngineError) -> (msgKey: String, code: String) {
        switch e {
        case .sha256Mismatch:          return ("fwupdate.error.verify", "sha256_mismatch")
        case .signatureMismatch:       return ("fwupdate.error.verify", "sig_mismatch")
        case .headerRejected(let c):   return ("fwupdate.error.rejected", "header_\(String(format: "%02x", c))")
        case .eraseFailed(let c):      return ("fwupdate.error.generic", "erase_\(String(format: "%02x", c))")
        case .writeFailed(let off):    return ("fwupdate.error.transfer", "write_\(off)")
        case .noResponse(let stage):   return ("fwupdate.error.transfer", "timeout_\(stage)")
        }
    }
}
