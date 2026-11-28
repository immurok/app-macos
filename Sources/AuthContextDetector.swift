import AppKit
import ApplicationServices
import AuthInjectionKit

enum AuthContext {
    case none
    case secureField(item: AutomationItem, field: AXUIElement, sheet: AXUIElement)
    case appStoreConfirmSheet(item: AutomationItem, sheet: AXUIElement)
}

/// 在主动指纹路径被触发时，检索当前焦点上下文并分类。单一职责、无副作用。
/// 遍历 AutomationStore 里 enabled 的条目，而非硬编码 bundle id。
struct AuthContextDetector {

    /// 承载任意网页内容的浏览器进程。它们的 AXSecureTextField 可能来自网页（属主 pid 同样是
    /// 浏览器），app 类条目命中这些进程时必须加结构硬化：只认"原生 AXSheet 且上行不穿过
    /// AXWebArea"的密码框（如 Safari 内 Passwords 解锁 sheet），网页登录框一律拒绝。
    private static let webBrowserBundles: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "org.mozilla.firefox",
    ]

    func detect() -> AuthContext {
        let items = AutomationStore.shared.enabledItems()
        // Touch ID auto-fill 条目走 localAuthDialog() 专用路径（要先按「使用密码…」），不参与通用检测。
        let appItems = items.filter { $0.targetKind == .app && !$0.isTouchIDAutoFill }
        let extItems = items.filter { $0.targetKind == .browserExtension }

        // Path 1) 系统级焦点若是 AXSecureTextField，按其**属主进程** bundleID 命中 app 条目
        //   （而非 frontmost）。Sign in with Apple 的密码框属主是 AKAuthorizationRemoteViewService，
        //   前台却是 Safari——只有按属主才能命中。
        //   rightArrow 策略（1Password）**不走这条**：它必须经 Path 2 的"恰好一个 secure field"
        //   硬化判据，否则改主密码等多字段表单的某个框被聚焦时会从这里绕过 guard 被误注入。
        path1: if let focused = systemWideFocusedSecureField(),
           let ownerPID = ownerPID(of: focused),
           let ownerBundle = NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier,
           let item = appItems.first(where: { $0.matches(bundleID: ownerBundle) && $0.submitStrategy != .rightArrow }),
           InjectionWhitelist.passesSigning(for: item, pid: ownerPID, bundleID: ownerBundle),
           let hit = enclosingContainer(of: focused) {
            // 属主是浏览器（如 Safari 内 Passwords 解锁）：只认原生 sheet，且上行链不得穿过
            // AXWebArea——网页登录框满足不了这两条，防止把登录密码注入任意网站。
            // 拒绝时不终止检测，放行到 Path 2-4（如另一浏览器里的 Bitwarden 浮层）。
            if Self.webBrowserBundles.contains(ownerBundle),
               hit.crossedWebArea || role(of: hit.container) != "AXSheet" {
                NSLog("AuthContextDetector: reject browser-owned secure field (%@) — webArea=%d containerRole=%@",
                      ownerBundle, hit.crossedWebArea ? 1 : 0, role(of: hit.container) ?? "nil")
                break path1
            }
            return .secureField(item: item, field: focused, sheet: hit.container)
        }

        // Path 2) 定向下行扫描：1Password 桌面锁定窗 / 扩展浮层（rightArrow 策略），以及 Passwords
        //   焦点不在框时。下行扫描直接拿到 (密码框, 所在窗口)——1P 的 Chromium 树 kAXParent 链断裂，
        //   上行会得 nil。仅当树里"恰好一个"secure field 才触发（硬化：排除改主密码等多字段表单）。
        //   generic 策略（Passwords 类）要求前台才扫（后台窗口不注入）。
        // 浏览器进程不做下行全树扫描：树巨大且网页里随处可能恰好有一个密码框（会被误注入）。
        // 浏览器内的原生解锁 sheet（Safari Passwords）出现时密码框自动聚焦，Path 1 已覆盖。
        for item in appItems where item.submitStrategy != .appStoreWizard {
            for bundleID in item.bundleIDs where !Self.webBrowserBundles.contains(bundleID) {
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                    if item.submitStrategy == .generic && !app.isActive { continue }
                    guard InjectionWhitelist.passesSigning(for: item, pid: app.processIdentifier, bundleID: bundleID) else { continue }
                    guard let appEl = AXAppProbe.responsiveApplication(pid: app.processIdentifier, tag: "app-scan \(bundleID)") else { continue }
                    if let hit = soleSecureFieldWithWindow(under: appEl) {
                        return .secureField(item: item, field: hit.field, sheet: hit.window)
                    }
                }
            }
        }

        // Path 3) 浏览器扩展条目：密码框归浏览器进程，靠"浏览器签名 + WebArea URL 属于扩展 +
        //   恰好一个 secure field"识别。扫浏览器 AX 树较重，仅遍历 enabled 的扩展条目。
        for item in extItems {
            guard let origin = item.extensionOrigin, let frag = item.urlFragment else { continue }
            if let hit = BrowserExtensionDetector().detect(origin: origin, urlFragment: frag) {
                return .secureField(item: item, field: hit.field, sheet: hit.container)
            }
        }

        // Path 4) App Store 特有：还在 Install/Cancel 确认页（尚无焦点密码框）——按前台应用判定。
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier,
              let item = appItems.first(where: { $0.submitStrategy == .appStoreWizard && $0.matches(bundleID: bundleID) }),
              InjectionWhitelist.passesSigning(for: item, pid: frontApp.processIdentifier, bundleID: bundleID)
        else { return .none }
        guard let appElement = AXAppProbe.responsiveApplication(pid: frontApp.processIdentifier, tag: "appstore-scan") else { return .none }
        if let sheet = firstSheetWithButtons(appElement) {
            return .appStoreConfirmSheet(item: item, sheet: sheet)
        }

        return .none
    }

    /// LocalAuthentication 系统密码框（coreautha）的识别结果。
    enum LocalAuthDialog {
        case notPresent
        /// 焦点密码框属主自称是 coreautha 但签名校验没过，或找不到所在窗口：不注入、也不发回车。
        case untrusted
        case ready(field: AXUIElement, window: AXUIElement)
        /// 还停在 Touch ID 页（本机 Touch ID 可用时的默认页），且带「使用密码…」按钮：
        /// 按下后同一窗口原地切到密码页（→ `.ready`）。
        case touchID(usePasswordButton: AXUIElement)
    }

    /// 识别 coreautha 的认证框，校验其 Apple 平台签名。对应 Automation 内置条目「Touch ID auto-fill」
    ///（开关由调用方判断，这里只管识别）。
    ///
    /// 两条路径：
    /// 1. 系统级焦点是 coreautha 的密码框 → `.ready`（最便宜，原有路径）。
    /// 2. 否则直接扫 coreautha 进程的窗口（不依赖焦点/前台）。必须有这条：Touch ID 页根本没有
    ///    密码框；而按下「使用密码…」后密码框虽已出现，系统级焦点却常是 nil（实测），路径 1 认不出。
    ///
    /// 识别全部靠结构与 AXIdentifier（`authentication_ui` 容器、`touchid` 图标），与界面语言无关。
    func localAuthDialog() -> LocalAuthDialog {
        let bundleID = AutomationItem.localAuthUIAgentBundleID
        if let focused = systemWideFocusedSecureField(), let pid = ownerPID(of: focused),
           NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleID {
            guard InjectionWhitelist.processSatisfies(pid: pid, bundleID: bundleID, signing: .applePlatform),
                  let hit = enclosingContainer(of: focused) else { return .untrusted }
            return .ready(field: focused, window: hit.container)
        }

        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            let pid = app.processIdentifier
            guard let appEl = AXAppProbe.responsiveApplication(pid: pid, tag: "localauth-scan") else { continue }
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement], !windows.isEmpty else { continue }
            for window in windows {
                guard let ui = children(of: window).first(where: { identifier(of: $0) == "authentication_ui" }) else { continue }
                // 确有认证框才做签名校验（coreautha 常驻但平时无窗口，避免每次触摸都验签）。
                guard InjectionWhitelist.processSatisfies(pid: pid, bundleID: bundleID, signing: .applePlatform) else { return .untrusted }
                let kids = children(of: ui)
                if let field = kids.first(where: { subrole(of: $0) == (kAXSecureTextFieldSubrole as String) }) {
                    return .ready(field: field, window: window)
                }
                // Touch ID 页：touchid 图标 + 恰好两个按钮 [使用密码…, 取消]（实测子节点顺序）。
                // 只有一个按钮 = 该请求不允许密码回退（仅生物识别），不处理。
                let buttons = kids.filter { role(of: $0) == "AXButton" }
                if buttons.count == 2,
                   kids.contains(where: { role(of: $0) == "AXImage" && identifier(of: $0) == "touchid" }) {
                    return .touchID(usePasswordButton: buttons[0])
                }
            }
        }
        return passwordsLockPage()
    }

    /// Passwords 的锁定页：菜单栏图标面板（com.apple.Passwords.MenuBarExtra，AXSystemDialog）
    /// 和 Passwords App 主窗口（com.apple.Passwords，AXStandardWindow）是同一套界面。实测结构：
    ///   … > AXGroup > AXGroup >
    ///     AXImage id=touchid、「Passwords Is Locked」文字、AXButton「使用密码…」（**没有**取消键）
    /// 按下后原地换成：AXImage id=lock.fill + 一个 AXSecureTextField。
    /// 与 coreautha 不同，这里"唯一按钮"就是「使用密码…」，所以判据收得更紧：
    /// - 只在这两个进程里认；App 主窗口要求 App 在前台（与 Passwords 条目一致）；
    /// - 窗口控制按钮（关闭/最小化/全屏/缩放）不计数；
    /// - Touch ID 页：touchid 图标 + 无密码框 + 恰好一个其它按钮；
    /// - 密码页：恰好一个密码框 + touchid 或 lock.fill 图标（别的单密码框界面不认）。
    /// 识别只靠结构与 AXIdentifier，与界面语言无关。
    private func passwordsLockPage() -> LocalAuthDialog {
        let targets: [(bundleID: String, windowSubrole: String?, requireActive: Bool)] = [
            (AutomationItem.passwordsMenuBarBundleID, "AXSystemDialog", false),
            (AutomationItem.passwordsAppBundleID, nil, true),
        ]
        let windowControls: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXFullScreenButton", "AXZoomButton"]
        for target in targets {
          for app in NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID) {
            if target.requireActive && !app.isActive { continue }
            let bundleID = target.bundleID
            let pid = app.processIdentifier
            guard let appEl = AXAppProbe.responsiveApplication(pid: pid, tag: "passwords-lock-scan") else { continue }
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement], !windows.isEmpty else { continue }
            for window in windows where target.windowSubrole == nil || subrole(of: window) == target.windowSubrole {
                // 锁定页很小：有界下行扫描（深度 ≤ 6、≤ 80 个节点）。解锁后的主窗口树很大，
                // 预算用完就当没命中。
                var budget = 80
                var buttons: [AXUIElement] = []
                var fields: [AXUIElement] = []
                var hasTouchIDGlyph = false
                var hasLockGlyph = false
                func rec(_ el: AXUIElement, _ depth: Int) {
                    if depth > 6 || budget <= 0 { return }
                    for c in children(of: el) {
                        budget -= 1
                        if budget <= 0 { return }
                        let r = role(of: c)
                        if r == "AXButton" {
                            if !windowControls.contains(subrole(of: c) ?? "") { buttons.append(c) }
                            continue
                        }
                        if subrole(of: c) == (kAXSecureTextFieldSubrole as String) { fields.append(c); continue }
                        if r == "AXImage" {
                            let id = identifier(of: c)
                            if id == "touchid" { hasTouchIDGlyph = true }
                            if id == "lock.fill" { hasLockGlyph = true }
                        }
                        rec(c, depth + 1)
                    }
                }
                rec(window, 0)
                if budget <= 0 { continue }
                let isPasswordPage = fields.count == 1 && (hasLockGlyph || hasTouchIDGlyph)
                let isTouchIDPage = fields.isEmpty && hasTouchIDGlyph && buttons.count == 1
                guard isPasswordPage || isTouchIDPage else { continue }
                guard InjectionWhitelist.processSatisfies(pid: pid, bundleID: bundleID, signing: .applePlatform) else { return .untrusted }
                return isPasswordPage ? .ready(field: fields[0], window: window)
                                      : .touchID(usePasswordButton: buttons[0])
            }
          }
        }
        return .notPresent
    }

    private func identifier(of el: AXUIElement) -> String? {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXIdentifierAttribute as CFString, &ref)
        return ref as? String
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
    /// 同时报告上行途中是否穿过 AXWebArea——浏览器属主的硬化判据（网页字段必在 WebArea 内）。
    private func enclosingContainer(of el: AXUIElement) -> (container: AXUIElement, crossedWebArea: Bool)? {
        var current: AXUIElement? = el
        var depth = 0
        var crossedWebArea = false
        while let node = current, depth < 12 {
            let r = role(of: node)
            if r == "AXWebArea" { crossedWebArea = true }
            if r == "AXSheet" || r == "AXWindow" { return (node, crossedWebArea) }
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
        let deadline = CFAbsoluteTimeGetCurrent() + AXAppProbe.scanTimeBudget
        var timedOut = false
        var results: [(AXUIElement, AXUIElement?)] = []
        func rec(_ el: AXUIElement, _ nearestWindow: AXUIElement?) {
            if budget <= 0 || timedOut || results.count > 1 { return }
            if CFAbsoluteTimeGetCurrent() > deadline { timedOut = true; return }
            budget -= 1
            let node = AXNode.snapshot(el)
            let r = node.role
            let win = (r == "AXWindow" || r == "AXSheet") ? el : nearestWindow
            if node.subrole == (kAXSecureTextFieldSubrole as String) || r == "AXSecureTextField" {
                results.append((el, win))
                return   // 命中即止，不下钻密码框内部
            }
            for c in node.children {
                rec(c, win)
                if results.count > 1 || timedOut { return }
            }
        }
        rec(root, nil)
        // 超时 = 没扫完，「恰好一个」无从断言 → 按未命中处理（不注入）。
        if timedOut {
            let msg = "[ax] app-scan exceeded \(Int(AXAppProbe.scanTimeBudget * 1000))ms budget (\(8000 - budget) nodes) → skip"
            Task { @MainActor in LogManager.shared.log(msg) }
            return nil
        }
        guard results.count == 1, let win = results[0].1 else { return nil }
        return (results[0].0, win)
    }
}
