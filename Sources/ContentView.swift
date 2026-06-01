import SwiftUI

// MARK: - Settings Tab

enum SettingsTab: String, CaseIterable {
    case device
    case keys
    case permissions
    case status
    case about

    var icon: String {
        switch self {
        case .device: return "antenna.radiowaves.left.and.right"
        case .keys: return "key.fill"
        case .permissions: return "slider.horizontal.3"
        case .status: return "list.bullet.rectangle"
        case .about: return "info.circle"
        }
    }

    var localizedName: String {
        switch self {
        case .device: return "tab.device".localized
        case .keys: return "tab.keys".localized
        case .permissions: return "tab.permissions".localized
        case .status: return "tab.status".localized
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
    // 每个 tab 自适应内容高度，window 跟随调整（windowResizability(.contentSize) 在 immurokApp.swift 已设）。
    // 加 minHeight 防止内容很少（如关于页）时窗口太矮。
    private let minContentHeight: CGFloat = 360

    var body: some View {
        VStack(spacing: 0) {
            // Tab Bar (Safari-style) - 固定在顶部
            tabBar
                .frame(height: tabBarHeight)

            Divider()

            // Tab Content - 自适应高度，按当前 tab 内容自然撑开
            tabContent
                .frame(minHeight: minContentHeight, alignment: .top)
        }
        .frame(width: 500)
        .background(Color(NSColor.windowBackgroundColor))
        .id(localization.currentLanguage)  // Force view rebuild on language change
        .onAppear {
            setupManager.refreshStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsTab)) { notification in
            if let tab = notification.object as? SettingsTab {
                selectedTab = tab
            }
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
        case .status:
            StatusTabView(viewModel: viewModel, setupManager: setupManager)
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
