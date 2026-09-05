import SwiftUI

// MARK: - Settings Tab

enum SettingsTab: String, CaseIterable {
    case device
    case keys
    case permissions
    case automation
    case about

    var icon: String {
        switch self {
        case .device: return "antenna.radiowaves.left.and.right"
        case .keys: return "key.fill"
        case .permissions: return "slider.horizontal.3"
        case .automation: return "wand.and.stars"
        case .about: return "info.circle"
        }
    }

    var localizedName: String {
        switch self {
        case .device: return "tab.device".localized
        case .keys: return "tab.keys".localized
        case .permissions: return "tab.permissions".localized
        case .automation: return "tab.automation".localized
        case .about: return "tab.about".localized
        }
    }
}

// MARK: - Main Content View

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var setupManager = SetupManager.shared
    @ObservedObject var localization = LocalizationManager.shared
    @State private var selectedTab: SettingsTab = .device

    private let tabBarHeight: CGFloat = 70
    // 窗口可由用户调整（windowResizability(.contentMinSize) 在 immurokApp.swift 已设）。
    // 这里只约束最小尺寸；各 tab 顶层都有 ScrollView，小屏/低分辨率下内容可滚动不裁切。
    private let minContentHeight: CGFloat = 360

    var body: some View {
        VStack(spacing: 0) {
            // Tab Bar (Safari-style) - 固定在顶部
            tabBar
                .frame(height: tabBarHeight)

            Divider()

            // Tab Content - 弹性填满窗口，内容超高时由各 tab 的 ScrollView 承接
            tabContent
                .frame(maxWidth: .infinity, minHeight: minContentHeight,
                       maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 560)
        .background(Color(NSColor.windowBackgroundColor))
        .id(localization.currentLanguage)  // Force view rebuild on language change
        .onAppear {
            setupManager.refreshStatus()
            // 正在编辑 Automation 条目时打开/重建窗口，停在 Automation tab 直接显示编辑器，
            // 不切到默认页（编辑状态存在常驻 viewModel，窗口重建也在）。
            if viewModel.editingAutomationItem != nil {
                selectedTab = .automation
            }
        }
        .onReceive(viewModel.$pendingSettingsTab) { tab in
            guard let tab = tab else { return }
            // 编辑 Automation 期间，任何打开设置窗口的入口都停在 Automation，不切走。
            selectedTab = (viewModel.editingAutomationItem != nil) ? .automation : tab
            viewModel.pendingSettingsTab = nil
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 24) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                TabButton(
                    tab: tab,
                    isSelected: selectedTab == tab
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedTab = tab
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .device:
            DeviceTabView(viewModel: viewModel)
        case .keys:
            KeysTabView(viewModel: viewModel)
        case .permissions:
            PermissionsTabView(viewModel: viewModel, setupManager: setupManager)
        case .automation:
            AutomationTabView(viewModel: viewModel)
        case .about:
            AboutTabView(viewModel: viewModel, setupManager: setupManager)
        }
    }
}

// MARK: - Tab Button

struct TabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tab.icon)
                    .font(.system(size: 24))
                    .frame(height: 28)

                Text(tab.localizedName)
                    .font(.caption)
            }
            .foregroundColor(isSelected ? .accentColor : .secondary)
            .frame(width: 70, height: 54)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
