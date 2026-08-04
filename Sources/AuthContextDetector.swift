import AppKit
import ApplicationServices
import AuthInjectionKit

enum AuthContext {
    case none
    case secureField(kind: SecretKind, field: AXUIElement, sheet: AXUIElement, bundleID: String)
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
           // 1Password **不走这条**：它必须经下面 Path 1.5 的"恰好一个 secure field"硬化判据，
           // 否则改主密码等多字段表单的某个框被聚焦时会从这里绕过 guard 被误注入。
           ownerBundle != "com.1password.1password",
           let kind = InjectionWhitelist.secretKind(forPID: ownerPID, bundleID: ownerBundle),
           let container = enclosingContainer(of: focused) {
            return .secureField(kind: kind, field: focused, sheet: container, bundleID: ownerBundle)
        }

        // 1.5) 1Password 解锁：浏览器扩展解锁浮层是 layer-101 popover，未必是系统焦点元素，
        //      systemWideFocused 可能命不中。改用进程定向扫描 com.1password.1password 的 AX 树
        //      找 secure field（不依赖焦点），统一覆盖"整屏锁定窗 + 扩展浮层"。1P 未锁定时树内
        //      无 secure field，自然不触发。
        if let onep = NSRunningApplication.runningApplications(withBundleIdentifier: "com.1password.1password").first,
           InjectionWhitelist.secretKind(forPID: onep.processIdentifier, bundleID: "com.1password.1password") == .onePasswordPassword {
            let appEl = AXUIElementCreateApplication(onep.processIdentifier)
            // 下行扫描直接拿到 (密码框, 所在窗口)——不能用 enclosingContainer 上行爬，
            // 1P 的 Chromium 树 kAXParent 链断裂，上行会得 nil 导致检测失败。
            // 仅当树里"恰好一个"secure field 才触发（硬化：排除改主密码等多字段表单）。
            if let hit = soleSecureFieldWithWindow(under: appEl) {
                return .secureField(kind: .onePasswordPassword, field: hit.field, sheet: hit.window, bundleID: "com.1password.1password")
            }
        }

        // 1.6) Bitwarden 浏览器扩展解锁：密码框归浏览器进程，靠"浏览器签名 + WebArea URL 属于
        //      Bitwarden 扩展 + 恰好一个 secure field"识别（见 BitwardenDetector）。扫浏览器 AX 树
        //      较重，仅在功能开启时才扫。
        if UserDefaults.standard.bool(forKey: "immurok.bitwardenUnlockEnabled"),
           let bw = BitwardenDetector().detect() {
            return .secureField(kind: .bitwardenPassword, field: bw.field, sheet: bw.container, bundleID: bw.browserBundle)
        }

        // 1.7) Passwords（系统密码 App）：焦点不在密码框时（刚打开、焦点落在列表 /
        //      搜索框等），Path 1 的 systemWideFocused 命不中，就出现"焦点已经在
        //      Passwords App 上却注入不了"。改用进程定向下行扫描 com.apple.Passwords
        //      的 AX 树找 secure field（不依赖焦点），与 1P Path 1.5 同一套路。
        //      安全边界：仅前台 Passwords 才扫（后台窗口不注入）；白名单 + 代码签名
        //      校验（applePlatform）防冒充；硬化同 1P —— soleSecureFieldWithWindow
        //      恰好一个 secure field 才触发，排除改密码等多字段表单。
        if let pw = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Passwords").first,
           pw.isActive,
           let kind = InjectionWhitelist.secretKind(forPID: pw.processIdentifier, bundleID: "com.apple.Passwords") {
            let appEl = AXUIElementCreateApplication(pw.processIdentifier)
            if let hit = soleSecureFieldWithWindow(under: appEl) {
                return .secureField(kind: kind, field: hit.field, sheet: hit.window, bundleID: "com.apple.Passwords")
            }
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

    /// 扫描 root 子树里的**全部** AXSecureTextField（有界，>1 即提前收手），
    /// **仅当恰好一个时**返回它及所在 AXWindow/AXSheet 容器，否则 nil。
    ///
    /// 两层用意：
    /// 1. 容器用**下行追踪**得到——1Password 是 Chromium 内核，密码框到窗口的 `kAXParent` 上行链
    ///    是断的，从框往上爬（`enclosingContainer`）会拿到 nil；从 app 往下扫时窗口就是祖先，顺手记住。
    /// 2. **恰好一个**是硬化判据（locale-independent）：解锁框（桌面锁定窗 / 浏览器扩展浮层）永远是
    ///    单个密码框；而"修改主密码"等表单有当前/新/确认多个 secure field，用"恰好一个"即可天然排除，
    ///    避免把登录密码误注入多字段表单。解锁后的编辑登录条目是明文框（0 个 secure field），也不触发。
    ///    其余"单个密码框"场景（确认密码以显示/授权）本身也要账户密码，注入登录密码无害。
    private func soleSecureFieldWithWindow(under root: AXUIElement) -> (field: AXUIElement, window: AXUIElement)? {
        var budget = 8000
        var results: [(AXUIElement, AXUIElement?)] = []
        func rec(_ el: AXUIElement, _ nearestWindow: AXUIElement?) {
            if budget <= 0 || results.count > 1 { return }
            budget -= 1
            let r = role(of: el)
            let win = (r == "AXWindow" || r == "AXSheet") ? el : nearestWindow
            if subrole(of: el) == (kAXSecureTextFieldSubrole as String) || r == "AXSecureTextField" {
                results.append((el, win))
                return   // 命中即止，不下钻密码框内部
            }
            for c in children(of: el) {
                rec(c, win)
                if results.count > 1 { return }
            }
        }
        rec(root, nil)
        guard results.count == 1, let win = results[0].1 else { return nil }
        return (results[0].0, win)
    }
}
