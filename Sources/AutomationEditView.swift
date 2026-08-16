import SwiftUI
import AppKit
import Security
import UniformTypeIdentifiers
import AuthInjectionKit

struct AutomationEditView: View {
    @State var item: AutomationItem
    let store: AutomationStore
    @ObservedObject var viewModel: AppViewModel
    let onClose: () -> Void

    private var isExisting: Bool { store.items.contains { $0.id == item.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isExisting ? "automation.edit.title".localized : "automation.add.title".localized)
                .font(.title3).bold()

            TextField("automation.name".localized, text: $item.name)
                .textFieldStyle(.roundedBorder)

            targetSection

            HStack {
                Button { pickTarget() } label: { Label("automation.pick".localized, systemImage: "scope") }
                Button { selectApp() } label: { Label("automation.selectApp".localized, systemImage: "app.dashed") }
            }

            Picker("automation.submitStrategy".localized, selection: $item.submitStrategy) {
                Text("automation.strategy.generic".localized).tag(SubmitStrategy.generic)
                Text("automation.strategy.rightArrow".localized).tag(SubmitStrategy.rightArrow)
                Text("automation.strategy.belowButton".localized).tag(SubmitStrategy.belowButton)
                Text("automation.strategy.appStoreWizard".localized).tag(SubmitStrategy.appStoreWizard)
            }

            Divider()
            HStack {
                Spacer()
                Button("alert.cancel".localized) { onClose() }
                Button("password.save".localized) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(item.name.isEmpty || item.bundleIDs.isEmpty || !item.isValid)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    // MARK: - 目标身份展示

    @ViewBuilder private var targetSection: some View {
        GroupBox {
            if item.bundleIDs.isEmpty {
                Text("automation.noTarget".localized).foregroundColor(.secondary).padding(6)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    infoRow("automation.field.type".localized,
                            item.targetKind == .browserExtension ? "automation.browserExt".localized : "automation.field.app".localized)
                    infoRow("automation.field.bundle".localized, item.bundleIDs.joined(separator: ", "))
                    infoRow("automation.field.signing".localized, signingText)
                    if let origin = item.extensionOrigin {
                        infoRow("automation.field.extension".localized, origin)
                    }
                    if let axID = item.fieldAXIdentifier {
                        infoRow("automation.field.pwid".localized, axID)
                    }
                }
                .padding(6)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption).foregroundColor(.secondary).frame(width: 80, alignment: .leading)
            Text(value).font(.caption).textSelection(.enabled)
            Spacer()
        }
    }

    private var signingText: String {
        switch item.signing {
        case .applePlatform: return "Apple"
        case .developerID(let t): return "Developer ID · \(t)"
        }
    }

    // MARK: - 拾取 / 选 App

    /// 浏览器扩展只支持 Chromium 系（有稳定的 chrome-extension:// 固定 ID）。
    /// Safari/Firefox 扩展 URL 是每安装随机 UUID，无稳定锚点，且 Safari popup 命中测试
    /// 拿不到扩展内容，故拾取到这些浏览器时直接提示不支持。
    private static let unsupportedBrowsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "org.mozilla.firefox",
    ]

    private func pickTarget() {
        TargetPicker().pick { picked in
            guard let p = picked else { return }
            // 拦截不支持的浏览器扩展宿主。
            let isUnsupportedBrowser = Self.unsupportedBrowsers.contains(p.bundleID)
                || (p.targetKind == .browserExtension && BrowserExtensionDetector.browsers[p.bundleID] == nil)
            if isUnsupportedBrowser {
                DispatchQueue.main.async {
                    viewModel.showAlert(title: "automation.pick.unsupported.title".localized,
                                        message: "automation.pick.unsupported.message".localized)
                }
                return
            }
            item.bundleIDs = [p.bundleID]
            item.signing = p.signing
            item.targetKind = p.targetKind
            item.extensionOrigin = p.extensionOrigin
            item.urlFragment = p.urlFragment
            item.fieldAXIdentifier = p.fieldAXIdentifier
            if item.name.isEmpty { item.name = p.appName }
            if p.targetKind == .browserExtension { item.submitStrategy = .belowButton }
        }
    }

    private func selectApp() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
        item.bundleIDs = [bundleID]
        item.targetKind = .app
        item.extensionOrigin = nil
        item.urlFragment = nil
        item.signing = Self.deriveSigning(appURL: url)
        if item.name.isEmpty {
            item.name = (bundle.infoDictionary?["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        }
    }

    /// 从 .app 路径读代码签名 → SigningRequirement。
    static func deriveSigning(appURL: URL) -> SigningRequirement {
        var stat: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &stat) == errSecSuccess, let stat else {
            return .applePlatform
        }
        var appleReq: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &appleReq) == errSecSuccess,
           let r = appleReq, SecStaticCodeCheckValidity(stat, [], r) == errSecSuccess {
            return .applePlatform
        }
        var infoRef: CFDictionary?
        if SecCodeCopySigningInformation(stat, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef) == errSecSuccess,
           let info = infoRef as? [String: Any],
           let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String,
           IdentityValidation.isValidTeamID(teamID) {
            return .developerID(teamID: teamID)
        }
        return .applePlatform
    }

    private func save() {
        if isExisting { store.update(item) } else { store.add(item) }
        onClose()
    }
}
