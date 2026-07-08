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
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return .none }
        let pid = frontApp.processIdentifier
        let bundleID = frontApp.bundleIdentifier
        guard let kind = InjectionWhitelist.secretKind(forPID: pid, bundleID: bundleID) else { return .none }

        let appElement = AXUIElementCreateApplication(pid)

        // 1) 焦点是不是 AXSecureTextField？是 → secureField
        //    容器可能是 AXSheet（App Store 密码页）或 AXWindow（Passwords 解锁是 AXStandardWindow，
        //    实测非 sheet）。两者都要能命中，否则 Passwords 路径会静默失效。
        if let focused = copyElement(appElement, kAXFocusedUIElementAttribute),
           subrole(of: focused) == (kAXSecureTextFieldSubrole as String),
           let container = enclosingContainer(of: focused) {
            return .secureField(kind: kind, field: focused, sheet: container)
        }

        // 2) App Store 特有：还在 Install/Cancel 确认页（尚无密码框）
        if bundleID == "com.apple.AppStore",
           let sheet = firstSheetWithButtons(appElement) {
            return .appStoreConfirmSheet(sheet: sheet)
        }

        return .none
    }

    // MARK: - AX helpers

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
