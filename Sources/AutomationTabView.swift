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
                            onSetPassword: { setPassword(for: item) },
                            onToggle: { setEnabled($0, for: item) })
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
        // Passwords / Touch ID auto-fill 与屏幕解锁共用登录密码，必须走校验路径，防止存错后在锁屏盲打。
        if item.usesLoginPassword {
            viewModel.setupLoginPasswordIfNeeded()
            refreshToken = UUID()
            return
        }
        guard let pw = viewModel.promptAutomationPassword(name: item.name) else { return }
        store.setPassword(pw, for: item)
        refreshToken = UUID()
    }

    /// 开关规则：开启必须已有密码，没有就当场索取，取消则保持关闭；关闭时清掉该条目的密码。
    /// 例外：用登录密码的条目（Passwords / Touch ID auto-fill）关闭时不清，那份密码屏幕解锁还在用。
    private func setEnabled(_ on: Bool, for item: AutomationItem) {
        if on {
            if !store.hasPassword(item) { setPassword(for: item) }
            if store.hasPassword(item) { store.setEnabled(true, id: item.id) }
        } else {
            store.setEnabled(false, id: item.id)
            if !item.usesLoginPassword { store.clearPassword(item) }
        }
        refreshToken = UUID()   // 被拒绝的开启也要重建行，让开关弹回关闭
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
    let onToggle: (Bool) -> Void

    private var hasPassword: Bool { store.hasPassword(item) }
    /// 用登录密码的条目，修改入口在「功能 > 屏幕解锁」，这里只保留未配置时的设置入口。
    /// Touch ID auto-fill 完全复用系统登录密码，任何时候都不显示密码按钮。
    private var showsPasswordButton: Bool { !item.isTouchIDAutoFill && (!item.usesLoginPassword || !hasPassword) }

    /// 布局与「功能」页的 permissionRow 对齐：单行 = 图标(20pt 宽) + 标题 + 徽标 + (i) 说明气泡，
    /// 右侧是操作按钮（图标样式）+ 开关。目标身份（bundle id / 扩展 origin）收进 (i) 气泡，不再占第二行。
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: iconName)
                        .frame(width: 20)
                        .foregroundColor(.accentColor)
                    Text(item.name.isEmpty ? "automation.unnamed".localized : item.name)
                        .font(.headline)
                    badge(item.builtinKey != nil ? "automation.builtin".localized : "automation.custom".localized)
                    if item.targetKind == .browserExtension {
                        badge("automation.browserExt".localized)
                    }
                    if item.isValid == false {
                        badge("automation.weakIdentity".localized, color: .orange)
                    }
                    InfoTip(text: subtitle)

                    Spacer()

                    if showsPasswordButton {
                        let label = hasPassword ? "automation.changePassword".localized : "automation.setPassword".localized
                        iconButton("key", label: label, action: onSetPassword)
                    }
                    if item.builtinKey == nil {
                        iconButton("pencil", label: "keys.edit".localized, action: onEdit)
                        iconButton("trash", label: "keys.delete".localized) { confirmDelete() }
                    }

                    Toggle("", isOn: Binding(
                        get: { item.enabled },
                        set: { onToggle($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
                if item.enabled && !hasPassword {
                    Text("automation.needPassword".localized).font(.caption).foregroundColor(.orange)
                }
            }
            .padding(4)
        }
    }

    /// 删除会连同该条目存的密码一起清掉且不可恢复，先文字确认。
    private func confirmDelete() {
        let confirm = NSAlert()
        confirm.messageText = "automation.delete.confirm.title".localized(
            item.name.isEmpty ? "automation.unnamed".localized : item.name)
        confirm.informativeText = "automation.delete.confirm.message".localized
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "alert.delete".localized)
        confirm.addButton(withTitle: "alert.cancel".localized)
        // 不设 hasDestructiveAction：macOS 27 深色模式的 sheet 里破坏性按钮会被画成不可见。
        guard confirm.runModalOverSettings() == .alertFirstButtonReturn else { return }
        store.remove(id: item.id)
    }

    private var iconName: String {
        if item.isTouchIDAutoFill { return "touchid" }
        return item.targetKind == .browserExtension ? "puzzlepiece.extension" : "app.badge"
    }

    /// 与「功能」页行内的次要按钮同款：12pt 灰色图标 + tooltip。
    private func iconButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
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
