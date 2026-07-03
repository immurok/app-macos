import SwiftUI

/// 把承载它的 NSWindow 设为指定层级（用于让固件升级窗口浮在最前）。
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

/// 固件升级独立窗口（Window id "firmware-update"）。
/// 从 About 页拆出来，专门承载检查/下载/一跳两跳进度/确认。
struct FirmwareUpdateView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var localization = LocalizationManager.shared
    @ObservedObject private var fwService: FirmwareUpdateService
    @State private var showingUpgradeConfirm = false

    init(viewModel: AppViewModel) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._fwService = ObservedObject(wrappedValue: viewModel.firmwareUpdate)
    }

    var body: some View {
        VStack(spacing: 16) {
            // 标题
            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .font(.system(size: 26))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("fwupdate.title".localized)
                        .font(.title2).fontWeight(.bold)
                    Text("fwupdate.window.subtitle".localized)
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }

            // 强制升级横幅
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

            Divider()

            // 当前版本
            HStack {
                Text("fwupdate.current".localized)
                    .foregroundColor(.secondary)
                Spacer()
                Text(viewModel.firmwareVersion.map { "v\($0)" } ?? "—")
                    .fontWeight(.medium)
            }

            // 状态 / 操作
            statusContent
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 420)
        .frame(minHeight: fwService.mandatoryUpdate ? 300 : 260)
        .id(localization.currentLanguage)
        .background(WindowLevelSetter(level: .floating))  // 始终在最前方
        .onAppear {
            // 打开窗口即检查一次（设备已连接且当前空闲时）
            if case .idle = fwService.state, viewModel.isDeviceConnected {
                fwService.checkIfDue(force: true)
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
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
                    }.frame(maxHeight: 80)
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
