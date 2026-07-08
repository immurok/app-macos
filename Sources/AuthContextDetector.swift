import AppKit
import ApplicationServices
import AuthInjectionKit

enum AuthContext {
    case none
    case secureField(kind: SecretKind, field: AXUIElement, sheet: AXUIElement)
    case appStoreConfirmSheet(sheet: AXUIElement)
}

/// 在主动指纹路径被触发时，检索当前焦点上下文并分类。单一职责、无副作用。
struct AuthContextDetector {

    func detect() -> AuthContext {
        // 1) 系统级焦点若是 AXSecureTextField，按其**属主进程**判定白名单（而非 frontmost）。
        //    Sign in with Apple 的密码框属主是 AKAuthorizationRemoteViewService（远程视图服务），
        //    前台应用却是 Safari——只有按属主才能命中。App Store 密码页 / Passwords 解锁的焦点框
        //    属主就是自身进程，同样适用。
        //    容器可能是 AXSheet（App Store 密码页 / Sign in with Apple）或 AXWindow
        //    （Passwords 解锁是 AXStandardWindow，实测非 sheet）。两者都要能命中。
        if let focused = systemWideFocusedSecureField(),
           let ownerPID = ownerPID(of: focused),
           let ownerBundle = NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier,
           let kind = InjectionWhitelist.secretKind(forPID: ownerPID, bundleID: ownerBundle),
           let container = enclosingContainer(of: focused) {
            return .secureField(kind: kind, field: focused, sheet: container)
        }

        // 2) App Store 特有：还在 Install/Cancel 确认页（尚无焦点密码框）——按前台应用判定。
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier,
              InjectionWhitelist.secretKind(forPID: frontApp.processIdentifier, bundleID: bundleID) != nil
        else { return .none }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        if bundleID == "com.apple.AppStore",
           let sheet = firstSheetWithButtons(appElement) {
            return .appStoreConfirmSheet(sheet: sheet)
        }

        return .none
    }

    // MARK: - AX helpers

    /// 系统级焦点元素若是安全密码框则返回它，否则 nil。
    private func systemWideFocusedSecureField() -> AXUIElement? {
        guard let focused = copyElement(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute),
              subrole(of: focused) == (kAXSecureTextFieldSubrole as String) else { return nil }
        return focused
    }

    /// 元素所属进程 pid（用于按属主判定白名单 + 代码签名校验）。
    private func ownerPID(of el: AXUIElement) -> pid_t? {
        var p: pid_t = 0
        return AXUIElementGetPid(el, &p) == .success ? p : nil
    }

    /// 安全桥接：CFTypeRef? → AXUIElement?。AXUIElementCopyAttributeValue 对不同属性可能返回
    /// AXUIElement、CFArray、CFString 等不同 CF 类型，直接 `as!` 强转在类型不符时会崩溃，
    /// 因此先用 CFGetTypeID 校验实际类型再转换。
    private func toAXUIElement(_ ref: CFTypeRef?) -> AXUIElement? {
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private func copyElement(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return toAXUIElement(ref)
    }

    private func subrole(of el: AXUIElement) -> String? {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &ref)
        return ref as? String
    }

    private func role(of el: AXUIElement) -> String? {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &ref)
        return ref as? String
    }

    private func children(of el: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success,
              let kids = ref as? [AXUIElement] else { return [] }
        return kids
    }

    /// 从焦点元素向上找最近的"提交容器"祖先（有界深度）：AXSheet 或 AXWindow。
    /// App Store 密码页是嵌套 AXSheet；Passwords 解锁是 AXStandardWindow（role=AXWindow）。
    /// 返回的容器随后交给 AuthInjector.submit 在其子树里几何选主按钮（Sign In / Unlock）。
    private func enclosingContainer(of el: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = el
        var depth = 0
        while let node = current, depth < 12 {
            let r = role(of: node)
            if r == "AXSheet" || r == "AXWindow" { return node }
            var parentRef: CFTypeRef?
            AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parentRef)
            current = toAXUIElement(parentRef)
            depth += 1
        }
        return nil
    }

    /// 有界 BFS 找第一个含 ≥1 个 AXButton 的 AXSheet（App Store 确认页）。
    private func firstSheetWithButtons(_ appRoot: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(appRoot, 0)]
        while !queue.isEmpty {
            let (node, depth) = queue.removeFirst()
            if depth > 8 { continue }
            if role(of: node) == "AXSheet", hasButtonDescendant(node, maxDepth: 6) {
                return node
            }
            for kid in children(of: node) { queue.append((kid, depth + 1)) }
        }
        return nil
    }

    private func hasButtonDescendant(_ el: AXUIElement, maxDepth: Int) -> Bool {
        if maxDepth < 0 { return false }
        for kid in children(of: el) {
            if role(of: kid) == "AXButton" { return true }
            if hasButtonDescendant(kid, maxDepth: maxDepth - 1) { return true }
        }
        return false
    }
}
