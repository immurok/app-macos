import SwiftUI
import AppKit
import AuthInjectionKit

struct AutomationTabView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var store = AutomationStore.shared
    @State private var refreshToken = UUID()   // 密码变更后强制刷新行状态

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("automation.description".localized)
                        .font(.callout).foregroundColor(.secondary)

                    HStack(spacing: 10) {
                        Button { viewModel.editingAutomationItem = AutomationItem.newCustom() } label: {
                            Label("automation.add".localized, systemImage: "plus")
                        }
                        Spacer()
                        Button { importConfig() } label: {
                            Label("automation.import".localized, systemImage: "square.and.arrow.down")
                        }
                        Button { exportConfig() } label: {
                            Label("automation.export".localized, systemImage: "square.and.arrow.up")
                        }
                    }

                    ForEach(store.items) { item in
                        AutomationRow(item: item, store: store,
                            onEdit: { viewModel.editingAutomationItem = item },
                            onSetPassword: { setPassword(for: item) })
                            .id("\(item.id)-\(refreshToken)")
                    }
                }
                .padding(20)
            }

            // 编辑器用同窗口内的覆盖层而非 .sheet：LSUIElement 附属 app 里 .sheet 是子窗口，
            // 父窗口失焦再获焦（cmd+tab）会被 AppKit 关掉；覆盖层是视图树的一部分，免疫 app 切换。
            if let item = viewModel.editingAutomationItem {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { }   // 吸收点击，避免穿透到下层
                AutomationEditView(item: item, store: store, viewModel: viewModel,
                                   onClose: { viewModel.editingAutomationItem = nil })
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.windowBackgroundColor)))
                    .shadow(radius: 20)
                    .transition(.opacity)
            }
        }
    }

    private func setPassword(for item: AutomationItem) {
        guard let pw = viewModel.promptAutomationPassword(name: item.name) else { return }
        store.setPassword(pw, for: item)
        refreshToken = UUID()
    }

    // MARK: - 导入导出

    private func exportConfig() {
        guard let pw = viewModel.promptExportPassword() else { return }
        let payload = store.exportPayload()
        guard let blob = try? AutomationCrypto.encrypt(payload, password: pw) else {
            viewModel.showAlert(title: "automation.export.failed.title".localized,
                                message: "automation.export.failed.message".localized)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "immurok-automation.immurokauto"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do { try blob.write(to: url, options: .atomic) }
            catch {
                viewModel.showAlert(title: "automation.export.failed.title".localized,
                                    message: "automation.export.failed.message".localized)
            }
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let blob = try? Data(contentsOf: url) else { return }
        guard let pw = viewModel.promptSinglePassword(title: "automation.import.title".localized,
                                                      message: "automation.import.message".localized) else { return }
        do {
            let payload = try AutomationCrypto.decrypt(blob, password: pw)
            store.importPayload(payload)
            refreshToken = UUID()
        } catch {
            viewModel.showAlert(title: "automation.import.failed.title".localized,
                                message: "automation.import.failed.message".localized)
        }
    }
}

// MARK: - Row

private struct AutomationRow: View {
    let item: AutomationItem
    @ObservedObject var store: AutomationStore
    let onEdit: () -> Void
    let onSetPassword: () -> Void

    private var hasPassword: Bool { store.hasPassword(item) }

    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: item.targetKind == .browserExtension ? "puzzlepiece.extension" : "app.badge")
                    .font(.system(size: 20)).frame(width: 24).foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.name.isEmpty ? "automation.unnamed".localized : item.name)
                            .font(.headline)
                        badge(item.builtinKey != nil ? "automation.builtin".localized : "automation.custom".localized)
                        if item.targetKind == .browserExtension {
                            badge("automation.browserExt".localized)
                        }
                        if item.isValid == false {
                            badge("automation.weakIdentity".localized, color: .orange)
                        }
                    }
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                    if item.enabled && !hasPassword {
                        Text("automation.needPassword".localized).font(.caption).foregroundColor(.orange)
                    }
                }

                Spacer()

                Button(hasPassword ? "automation.changePassword".localized : "automation.setPassword".localized,
                       action: onSetPassword)
                    .buttonStyle(.borderless).font(.caption)

                if item.builtinKey == nil {
                    Button { onEdit() } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                    Button { store.remove(id: item.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }

                Toggle("", isOn: Binding(
                    get: { item.enabled },
                    set: { store.setEnabled($0, id: item.id) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            .padding(6)
        }
    }

    private var subtitle: String {
        if item.targetKind == .browserExtension {
            return item.extensionOrigin ?? item.bundleIDs.joined(separator: ", ")
        }
        return item.bundleIDs.joined(separator: ", ")
    }

    private func badge(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}
