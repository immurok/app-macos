import SwiftUI

/// 把承载它的 NSWindow 设为指定层级（用于让软件更新窗口浮在最前）。
/// SwiftUI 的 Window 没有直接设 level 的 API，借 NSViewRepresentable 抓宿主窗口。
struct WindowLevelSetter: NSViewRepresentable {
    let level: NSWindow.Level
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in v?.window?.level = level }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in nsView?.window?.level = level }
    }
}

/// 软件更新统一窗口（Window id "software-update"）：
/// 上半 macOS App（GitHub Release），下半设备固件（manifest + BLE OTA）。
struct SoftwareUpdateView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var localization = LocalizationManager.shared
    @ObservedObject private var fwService: FirmwareUpdateService
    @ObservedObject private var appService: AppUpdateService
    @State private var showingUpgradeConfirm = false

    init(viewModel: AppViewModel) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._fwService = ObservedObject(wrappedValue: viewModel.firmwareUpdate)
        self._appService = ObservedObject(wrappedValue: viewModel.appUpdate)
    }

    var body: some View {
        VStack(spacing: 16) {
            // 标题
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 26))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("update.title".localized)
                        .font(.title2).fontWeight(.bold)
                    Text("update.window.subtitle".localized)
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }

            // 强制升级横幅（固件低于底线版本）
            if fwService.mandatoryUpdate {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("fwupdate.mandatory".localized)
                        .font(.callout).fontWeight(.medium)
                    Spacer()
                }
                .padding(10)
                .background(Color.orange.opacity(0.15))
                .cornerRadius(8)
            }

            // ---- macOS App ----
            sectionHeader("update.section.app".localized, icon: "macwindow")
            HStack {
                Text("fwupdate.current".localized)
                    .foregroundColor(.secondary)
                Spacer()
                Text("v\(appService.installedVersion)")
                    .fontWeight(.medium)
            }
            appStatusContent
                .frame(maxWidth: .infinity, alignment: .leading)

            // ---- 设备固件 ----
            sectionHeader("update.section.firmware".localized, icon: "cpu")
            HStack {
                Text("fwupdate.current".localized)
                    .foregroundColor(.secondary)
                Spacer()
                Text(viewModel.firmwareVersion.map { "v\($0)" } ?? "—")
                    .fontWeight(.medium)
            }
            fwStatusContent
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 440)
        .frame(minHeight: fwService.mandatoryUpdate ? 460 : 420)
        .id(localization.currentLanguage)
        .background(WindowLevelSetter(level: .floating))  // 始终在最前方
        .onAppear {
            // 打开窗口即检查一次（固件需设备连接；App 不依赖设备）
            if case .idle = fwService.state, viewModel.isDeviceConnected {
                fwService.checkIfDue(force: true)
            }
            if case .idle = appService.state {
                appService.checkIfDue(force: true)
            }
        }
        .onDisappear {
            // 关闭窗口时复位终态，让下次打开能重新检查（进行中不复位）
            fwService.resetIfInactive()
            appService.resetIfInactive()
        }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
            Text(title)
                .font(.callout).fontWeight(.semibold)
                .foregroundColor(.secondary)
            VStack { Divider() }
        }
    }

    // MARK: - App 状态区

    @ViewBuilder
    private var appStatusContent: some View {
        switch appService.state {
        case .idle:
            Button("appupdate.check".localized) { appService.checkIfDue(force: true) }

        case .checking:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.6)
                Text("appupdate.checking".localized).foregroundColor(.secondary)
            }

        case .upToDate:
            Text("appupdate.upToDate".localized).foregroundColor(.secondary)

        case .updateAvailable(let version, let notes):
            VStack(alignment: .leading, spacing: 10) {
                Text("appupdate.available".localized(version))
                    .font(.headline).foregroundColor(.orange)
                if let notes = notes, !notes.isEmpty {
                    ScrollView {
                        Text(notes).font(.callout).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 70)
                }
                Button("appupdate.install".localized) { appService.downloadAndInstall() }
                    .buttonStyle(.borderedProminent)
            }

        case .downloading:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.6)
                Text("appupdate.downloading".localized).foregroundColor(.secondary)
            }

        case .installerOpened:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("appupdate.installerOpened".localized).foregroundColor(.secondary)
            }

        case .failed(let msg):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                    Text(msg).foregroundColor(.red)
                }
                Button("appupdate.check".localized) { appService.checkIfDue(force: true) }
            }
        }
    }

    // MARK: - 固件状态区

    @ViewBuilder
    private var fwStatusContent: some View {
        switch fwService.state {
        case .idle:
            VStack(alignment: .leading, spacing: 8) {
                if viewModel.isDeviceConnected {
                    Text("fwupdate.upToDate".localized)
                        .foregroundColor(.secondary)
                } else {
                    Text("fwupdate.error.notconnected".localized)
                        .foregroundColor(.orange)
                }
                Button("fwupdate.check".localized) { fwService.checkIfDue(force: true) }
                    .disabled(!viewModel.isDeviceConnected)
            }

        case .checking:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.6)
                Text("fwupdate.check".localized).foregroundColor(.secondary)
            }

        case .updateAvailable(let target, let notes):
            VStack(alignment: .leading, spacing: 10) {
                Text("fwupdate.available".localized(target))
                    .font(.headline).foregroundColor(.orange)
                if let notes = notes, !notes.isEmpty {
                    ScrollView {
                        Text(notes).font(.callout).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 70)
                }
                Button("fwupdate.upgrade".localized) { showingUpgradeConfirm = true }
                    .buttonStyle(.borderedProminent)
            }
            .alert("fwupdate.confirm.title".localized(target), isPresented: $showingUpgradeConfirm) {
                Button("alert.cancel".localized, role: .cancel) { }
                Button("fwupdate.upgrade".localized) { fwService.startUpdate() }
            } message: { Text("fwupdate.confirm.message".localized) }

        case .downloading:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.6)
                Text("fwupdate.progress.downloading".localized).foregroundColor(.secondary)
            }

        case .updating(let text, let fraction):
            VStack(alignment: .leading, spacing: 8) {
                Text("fwupdate.progress.pushing".localized(text)).font(.callout)
                ProgressView(value: fraction)
                Text("\(Int(fraction * 100))%").font(.caption).foregroundColor(.secondary)
            }

        case .waitingReconnect:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.6)
                Text("fwupdate.progress.waiting".localized).foregroundColor(.secondary)
            }

        case .success(let v):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("fwupdate.success".localized(v)).foregroundColor(.green)
            }

        case .failed(let msg):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                    Text(msg).foregroundColor(.red)
                }
                Button("fwupdate.check".localized) { fwService.checkIfDue(force: true) }
            }
        }
    }
}
