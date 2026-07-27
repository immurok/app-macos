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
    }
}

// MARK: - Menu Bar View

struct MenuBarView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var setupManager = SetupManager.shared
    @Environment(\.openWindow) private var openWindow

    /// 检查所有状态是否正常
    private var isAllStatusOK: Bool {
        viewModel.isDeviceConnected &&
        viewModel.fingerprintCount > 0 &&
        viewModel.isPasswordConfigured &&
        setupManager.hasAccessibilityPermission &&
        setupManager.isPAMModuleInstalled
    }

    /// 设置窗口是否已经可见
    private var isSettingsWindowVisible: Bool {
        NSApp.windows.contains { $0.title == "immurok" && $0.isVisible }
    }

    /// 打开设置窗口，仅在窗口不可见时跳转到指定 tab
    private func openSettings(tab: SettingsTab? = nil) {
        if !isSettingsWindowVisible, let tab = tab {
            NotificationCenter.default.post(name: .openSettingsTab, object: tab)
        }
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 打开软件更新统一窗口（App + 固件）
    private func openUpdateWindow() {
        openWindow(id: "software-update")
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if setupManager.needsPAMRepair {
                Button(action: {
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
                    Text(viewModel.isDeviceConnected ? "menu.connected".localized : "menu.disconnected".localized)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // App 或固件任一有新版本 → 统一入口进软件更新窗口
            if viewModel.firmwareUpdate.updateAvailable || viewModel.appUpdate.updateAvailable {
                Button(action: { openUpdateWindow() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill").foregroundColor(.orange)
                        Text("update.menu.available".localized).foregroundColor(.orange)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            // 整体状态 - 点击进入状态页面
            Button(action: {
                openSettings(tab: .status)
            }) {
                HStack(spacing: 8) {
                    Image(systemName: isAllStatusOK ? "checkmark.circle" : "exclamationmark.circle")
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
        .frame(width: 160)
        .onAppear {
            setupManager.refreshStatus()
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let openSettingsTab = Notification.Name("openSettingsTab")
}
