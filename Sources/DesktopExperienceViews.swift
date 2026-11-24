import SwiftUI
import AuthInjectionKit

@MainActor
struct DeviceExperienceView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var setup = SetupManager.shared
    @State private var checking = false
    @State private var result: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeviceReadinessCard(status: viewModel.readiness) { performAction() }
            HStack {
                Label("experience.connection.note".localized, systemImage: "cable.connector")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            if let sampled = viewModel.batteryUpdatedAt, viewModel.isDeviceConnected {
                Text("experience.battery.sampled".localized + " " + sampled.formatted(date: .omitted, time: .shortened))
                    .font(.caption).foregroundColor(.secondary)
            }
            if checking { ProgressView("experience.checking".localized).controlSize(.small) }
            if let result { Text(result).font(.caption).foregroundColor(.secondary).accessibilityLabel(result) }
            Button("experience.setup.again".localized) {
                NotificationCenter.default.post(name: .openSetupWizard, object: nil)
            }.buttonStyle(.link).font(.caption)
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            viewModel.objectWillChange.send()
        }
    }
    private func performAction() {
        switch viewModel.readiness {
        case .bluetoothPermission: viewModel.openBluetoothSettings()
        case .bluetoothOff, .disconnected, .unverified, .unsupported: viewModel.openBluetoothPreferences()
        case .accessibility: setup.openAccessibilitySettings()
        case .password: viewModel.configurePassword()
        case .ready, .lowBattery:
            guard !checking else { return }
            checking = true; result = nil
            viewModel.refreshDeviceStatus {
                checking = false
                result = viewModel.isDeviceConnected && viewModel.isDevicePaired && viewModel.isDeviceVerified ? "experience.checked".localized : "experience.checkFailed".localized
            }
        default: NotificationCenter.default.post(name: .openSetupWizard, object: nil)
        }
    }
}

extension AppViewModel {
    var requestedFeatures: Set<SetupFeature> {
        let d = UserDefaults.standard
        var selected = Set((d.stringArray(forKey: "immurok.setup.features") ?? []).compactMap(SetupFeature.init(rawValue:)))
        if d.bool(forKey: "immurok.screenUnlockEnabled") { selected.insert(.screenUnlock) }
        if d.bool(forKey: "immurok.sudoAuthEnabled") || d.bool(forKey: "immurok.authorizationEnabled") { selected.insert(.administrator) }
        if d.bool(forKey: "immurok.sshAgentEnabled") { selected.insert(.ssh) }
        return selected
    }
    var readiness: DeviceReadiness {
        let setup = SetupManager.shared
        var input = DeviceReadinessInput()
        input.permissionDenied = bluetoothStatus == .denied
        input.poweredOff = bluetoothStatus == .poweredOff
        input.unsupported = bluetoothStatus == .unsupported
        input.connected = isDeviceConnected
        input.paired = isDevicePaired && hasLocalPairing
        input.verified = isDeviceVerified
        input.fingerprintCount = fingerprintCount
        input.features = requestedFeatures
        input.hasPassword = isPasswordConfigured
        input.passwordSuspended = UserDefaults.standard.bool(forKey: "immurok.autoUnlockSuspended")
        input.accessibility = setup.hasAccessibilityPermission
        input.pamReady = setup.isPAMModuleInstalled && !setup.needsPAMRepair && setup.pamKeyStatus == .installed
        input.battery = batteryLevel
        return input.status
    }
}
