import SwiftUI
import ApplicationServices

@main
struct immurokApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        // Menu Bar Extra - 状态栏图标
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
        } label: {
            // label 抽成独立 View：持久渲染，可持有 openWindow 环境值，
            // 用于响应 .openFirmwareUpdateWindow 通知打开固件升级窗口。
            MenuBarStatusLabel(viewModel: viewModel)
        }
        // .window 样式：菜单内容作为完整 SwiftUI 视图渲染，尊重自定义 HStack/frame/padding
        //（Button(.plain)+padding+frame(width:) 就是按此写的）。默认 .menu(NSMenu) 会拆开
        // Image/Text 各成一行、丢图标（电量图标与文字分两行即因此）。
        .menuBarExtraStyle(.window)

        // Settings window - 可通过菜单打开
        Window("immurok", id: "settings") {
            ContentView(viewModel: viewModel)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 500, height: 640)
        .defaultPosition(.center)

        // 软件更新统一窗口（App + 设备固件）
        Window("update.title".localized, id: "software-update") {
            SoftwareUpdateView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // 首次运行引导窗口（AppDelegate 检测到未完成设置时经通知打开）
        Window("wizard.title".localized, id: "setup-wizard") {
            SetupWizardView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

// MARK: - Menu Bar Status Label

/// 状态栏图标 + 连接点 + 固件更新橙点。作为持久 View 持有 openWindow，
/// 以便收到 .openFirmwareUpdateWindow 通知时（如强制升级）自动打开固件窗口。
struct MenuBarStatusLabel: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 2) {
            if let img = NSImage(named: "StatusBarIconTemplate") {
                Image(nsImage: img)
            } else {
                Image(systemName: "touchid")
            }
            Circle()
                .fill(viewModel.isDeviceConnected ? Color.green : Color.red)
                .frame(width: 6, height: 6)
            if viewModel.firmwareUpdate.updateAvailable || viewModel.appUpdate.updateAvailable {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFirmwareUpdateWindow)) { _ in
            openWindow(id: "software-update")
            NSApp.activate(ignoringOtherApps: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSetupWizard)) { _ in
            openWindow(id: "setup-wizard")
            NSApp.activate(ignoringOtherApps: true)
        }
        // 系统通知点击 → SystemNotifier 路由到这里（AppDelegate 没有
        // openWindow 环境值，只有这个常驻 View 有）。
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsWindow)) { note in
            if let tab = note.object as? SettingsTab {
                viewModel.pendingSettingsTab = tab
            }
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Menu Bar View

struct MenuBarView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var setupManager = SetupManager.shared
    @Environment(\.openWindow) private var openWindow
    // .window 样式的菜单面板点菜单项后不会自动收起，需主动 dismiss。
    @Environment(\.dismiss) private var dismiss

    /// 检查所有状态是否正常
    private var isAllStatusOK: Bool {
        viewModel.isDeviceConnected &&
        viewModel.fingerprintCount > 0 &&
        viewModel.isPasswordConfigured &&
        setupManager.hasAccessibilityPermission &&
        setupManager.isPAMModuleInstalled
    }

    private func batteryIcon(for level: Int) -> String {
        switch level {
        case 88...: return "battery.100"
        case 60...: return "battery.75"
        case 35...: return "battery.50"
        case 10...: return "battery.25"
        default: return "battery.0"
        }
    }

    /// 打开设置窗口并切换到指定 tab
    private func openSettings(tab: SettingsTab? = nil) {
        if let tab = tab {
            viewModel.pendingSettingsTab = tab
        }
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
        dismiss()
    }

    /// 打开软件更新统一窗口（App + 固件）
    private func openUpdateWindow() {
        openWindow(id: "software-update")
        NSApp.activate(ignoringOtherApps: true)
        dismiss()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if setupManager.needsPAMRepair {
                Button(action: {
                    dismiss()
                    setupManager.repairAuthorization { success, error in
                        if !success, let error = error {
                            let alert = NSAlert()
                            alert.messageText = "menu.authrepair".localized
                            alert.informativeText = error
                            alert.runModal()
                        }
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .frame(width: 16)
                        Text("menu.authrepair".localized)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()
            }

            // 连接状态 - 点击进入设备页面
            Button(action: {
                openSettings(tab: .device)
            }) {
                HStack(spacing: 8) {
                    Image(systemName: viewModel.isDeviceConnected ? "bolt.fill" : "bolt.slash.fill")
                        .frame(width: 16)
                    Text(viewModel.isDeviceConnected ? "menu.connected".localized : "menu.disconnected".localized)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // 电量常驻信息行。电量以前只在设置窗口设备页可见（下钻两层），
            // 对电池供电、断电即全功能失效的设备来说太深了。
            if viewModel.isDeviceConnected, let level = viewModel.batteryLevel {
                HStack(spacing: 8) {
                    Image(systemName: batteryIcon(for: level))
                        .font(.system(size: 11))   // 横向电池符号偏宽，缩小到与其他图标视觉一致
                        .foregroundColor(level <= 15 ? .red : .secondary)
                        .frame(width: 16)
                    Text("menu.battery".localized(level))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            // App 或固件任一有新版本 → 统一入口进软件更新窗口
            if viewModel.firmwareUpdate.updateAvailable || viewModel.appUpdate.updateAvailable {
                Button(action: { openUpdateWindow() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill").foregroundColor(.orange)
                            .frame(width: 16)
                        Text("update.menu.available".localized).foregroundColor(.orange)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            // 整体状态 - 点击进入 About（默认显示状态列表）
            Button(action: {
                openSettings(tab: .about)
            }) {
                HStack(spacing: 8) {
                    Image(systemName: isAllStatusOK ? "checkmark.circle" : "exclamationmark.circle")
                        .frame(width: 16)
                    Text(isAllStatusOK ? "menu.status.ok".localized : "menu.status.error".localized)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // 软件更新（常驻入口，App + 固件）
            Button(action: { openUpdateWindow() }) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .frame(width: 16)
                    Text("update.title".localized)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // 设置向导（可随时重新进入首次引导）
            Button(action: {
                openWindow(id: "setup-wizard")
                NSApp.activate(ignoringOtherApps: true)
                dismiss()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .frame(width: 16)
                    Text("menu.wizard".localized)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // 设置
            Button(action: {
                openSettings(tab: .permissions)
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .frame(width: 16)
                    Text("menu.settings".localized)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // 退出
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "power")
                        .frame(width: 16)
                    Text("menu.quit".localized)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 180)
        .onAppear {
            setupManager.refreshStatus()
        }
    }
}
