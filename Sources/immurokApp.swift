import SwiftUI
import ApplicationServices
import CoreGraphics

@main
struct immurokApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        // Menu Bar Extra - 状态栏图标
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
        } label: {
            // 使用自定义岩石图标 + 状态点
            HStack(spacing: 2) {
                if let img = NSImage(named: "StatusBarIconTemplate") {
                    Image(nsImage: img)
                } else {
                    Image(systemName: "touchid")
                }
                Circle()
                    .fill(viewModel.isDeviceConnected ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
            }
        }

        // Settings window - 可通过菜单打开
        Window("immurok", id: "settings") {
            ContentView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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

            // 测试辅助功能
            Button(action: {
                testAccessibility()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "keyboard")
                        .frame(width: 16)
                    Text("测试辅助功能")
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

// MARK: - Test Accessibility

private func testAccessibility() {
    // Check if we have accessibility permission
    guard AXIsProcessTrusted() else {
        NSLog("Test: No accessibility permission!")
        let alert = NSAlert()
        alert.messageText = "没有辅助功能权限"
        alert.informativeText = "请在系统设置中授予辅助功能权限"
        alert.runModal()
        return
    }

    NSLog("Test: Sending Ctrl+Cmd+Q to lock screen...")

    // Send Ctrl+Cmd+Q (lock screen shortcut)
    // Q key = 0x0C
    let src = CGEventSource(stateID: .hidSystemState)
    let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x0C, keyDown: true)
    let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x0C, keyDown: false)

    // Add Ctrl (0x40000) + Cmd (0x100000) modifiers
    keyDown?.flags = [.maskCommand, .maskControl]
    keyUp?.flags = [.maskCommand, .maskControl]

    keyDown?.post(tap: .cghidEventTap)
    keyUp?.post(tap: .cghidEventTap)

    NSLog("Test: Lock screen command sent")
}
