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
        case .permissions: return "person.badge.key"
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
    private let contentHeight: CGFloat = 420  // 固定高度，取最大值

    var body: some View {
        VStack(spacing: 0) {
            // Tab Bar (Safari-style) - 固定在顶部
            tabBar
                .frame(height: tabBarHeight)

            Divider()

            // Tab Content - 固定高度容器，内容顶部对齐
            ZStack(alignment: .top) {
                // 透明占位，保持固定高度
                Color.clear
                    .frame(height: contentHeight)

                // 实际内容
                tabContent
            }
            .frame(height: contentHeight)
            .clipped()
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
