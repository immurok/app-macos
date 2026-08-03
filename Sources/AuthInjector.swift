import AppKit
import ApplicationServices
import AuthInjectionKit

/// 密码注入的执行层：写值 + 聚焦 + 提交。不做上下文判定（见 AuthContextDetector）、
/// 不做白名单校验（见 InjectionWhitelist）——只负责把 secret 打进已确认的 AX 元素。
struct AuthInjector {

    /// 直接把密码写进安全框（不经键盘 → Secure Event Input 拦不到）。
    @discardableResult
    func inject(_ secret: String, into field: AXUIElement) -> AXError {
        let err = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, secret as CFString)
        if err != .success { NSLog("AuthInjector: inject failed AXError=%d", err.rawValue) }
        return err
    }

    /// 聚焦目标框：先 kAXFocused=true；失败则按 frame 中心合成鼠标点击。
    func focus(_ field: AXUIElement) {
        let r = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if r == .success { return }
        if let center = frameCenter(of: field) {
            clickMouse(at: center)
        }
    }

    /// 提交表单，按优先级尝试四种语言无关的方式：
    /// 0. 窗口的**默认按钮**（`AXDefaultButton`，即回车会触发的那个 = Sign In / Install /
    ///    Unlock）。最可靠：不靠标题文字、不靠几何位置，AppKit 与 Catalyst（App Store）通用。
    ///    App Store 是 Catalyst 应用，Cancel 往往没有 `AXCancelButton` subrole，几何"取最右"
    ///    可能误选 Cancel 把 sheet 关掉——默认按钮策略绕开这个坑。
    /// 1. 几何选主按钮：排除 Cancel（按 subrole **和**窗口 `AXCancelButton` 身份双重排除）
    ///    与窗口控制件，取最右并 AXPress；
    /// 2. 无按钮 / 按压失败时——如 Passwords 解锁只有输入框+回车——对 `field` 执行
    ///    `kAXConfirmAction`（AX 动作，Secure Event Input 拦不到）；
    /// 3. 再不行退回合成回车（secure field + SEI 可能拦，best-effort）。
    /// `field` 可选：App Store 确认页（按 Install）时没有输入框，传 nil 只走按钮路径。
    @discardableResult
    func submit(container: AXUIElement, field: AXUIElement? = nil) -> Bool {
        logCandidates(container)

        // 0) 默认按钮（回车目标）
        if let def = defaultButton(near: container) {
            logLine("submit → press AXDefaultButton '\(title(of: def) ?? "?")'")
            if AXUIElementPerformAction(def, kAXPressAction as CFString) == .success { return true }
            logLine("AXDefaultButton press failed, fall back to geometric")
        }

        // 1) 标题 + 几何选主按钮（Catalyst 无 subrole，靠标题排除 Cancel、优选 confirm）
        let cancelEl = cancelButton(near: container)
        let buttons = collectButtons(container, maxDepth: 6).filter { btn in
            if let cancelEl, CFEqual(btn, cancelEl) { return false }
            return true
        }
        let infos = buttons.map {
            ButtonInfo(subrole: subrole(of: $0), title: title(of: $0), frame: frame(of: $0) ?? .zero)
        }
        if let idx = MainButtonSelector.pick(from: infos) {
            logLine("submit → press '\(title(of: buttons[idx]) ?? "?")'")
            if AXUIElementPerformAction(buttons[idx], kAXPressAction as CFString) == .success {
                return true
            }
        }

        guard let field else { logLine("submit → no button, no field"); return false }
        // 2) 直接确认字段（无按钮场景，如 Passwords）
        if AXUIElementPerformAction(field, kAXConfirmAction as CFString) == .success {
            logLine("submit → field kAXConfirmAction ok")
            return true
        }
        // 3) 合成回车兜底（可能被 SEI 拦，无法确认是否生效）
        logLine("submit → no button + AXConfirm failed, synthetic Return")
        return pressReturnKey()
    }

    /// 1Password 专用提交。1P 是 Chromium 网页表单，通用 `submit` 在这里三处都栽：
    /// ① 聚焦密码框时 **Secure Event Input 开启**，合成回车被拦（用户手按物理回车才行）；
    /// ② 密码框不支持 `AXConfirm`（桌面）或 `kAXConfirmAction` 在 Chromium 上**假成功却空操作**（浏览器），
    ///    导致 `submit` 误判已提交而提前返回；③ 解锁箭头按钮在 AX 树 depth 10–12、空标题，
    ///    超出 `submit` 的 maxDepth 6 扫不到，`AXDefaultButton` 也是 nil。
    ///
    /// 策略（跨"桌面锁定窗 + 浏览器扩展浮层"两界面实测一致）：深扫容器，用**几何**锁定
    /// "与密码框同一排、位于其右侧"的解锁箭头（桌面 x=741/浏览器 x=1096，均紧贴框右、~40×40），
    /// 天然排除框上方的账户头像与框下方的 Cancel，再 `AXPress`（AX 动作不受 SEI 拦，与 kAXValue
    /// 写值可行同理）。找不到箭头才退回通用 `submit` 兜底。
    @discardableResult
    func submitOnePassword(field: AXUIElement, container: AXUIElement) -> Bool {
        guard let fieldFrame = frame(of: field) else {
            logLine("submitOnePassword: no field frame, falling back to generic submit")
            return submit(container: container, field: field)
        }
        // 排除窗口控件与取消键——submitOnePassword 会真点这个按钮，误点破坏性控件后果严重。
        let excludedSubroles: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXFullScreenButton", "AXZoomButton", "AXCancelButton"]
        let buttons = collectButtons(container, maxDepth: 16).filter { b in
            if let sr = subrole(of: b), excludedSubroles.contains(sr) { return false }
            if title(of: b)?.caseInsensitiveCompare("Cancel") == .orderedSame { return false }
            return true
        }
        // 解锁箭头：与密码框**同一行**（垂直中心落在框 Y 区间内），且**紧贴框右缘**
        // （左缘距框右边缘不超过约一个框高——避免误点同排远处的无关按钮）；多个取最靠近框右缘的。
        let adjacency = fieldFrame.height * 1.5
        let arrow = buttons
            .compactMap { b -> (AXUIElement, CGRect)? in frame(of: b).map { (b, $0) } }
            .filter { $0.1.midY >= fieldFrame.minY && $0.1.midY <= fieldFrame.maxY
                      && $0.1.minX >= fieldFrame.midX
                      && $0.1.minX <= fieldFrame.maxX + adjacency }
            .min(by: { abs($0.1.minX - fieldFrame.maxX) < abs($1.1.minX - fieldFrame.maxX) })
        if let arrow {
            // 网页按钮的 AXPress 在 Chromium 上假成功空操作（实测），改用**合成鼠标点击**箭头中心：
            // 鼠标事件不受 Secure Event Input 限制，是真正能触发网页 <button> 的点击。
            let center = CGPoint(x: arrow.1.midX, y: arrow.1.midY)
            logLine("submitOnePassword -> click unlock arrow center=\(center) frame=\(arrow.1)")
            clickMouse(at: center)
            return true
        }
        logLine("submitOnePassword: arrow not located geometrically, falling back to generic submit")
        return submit(container: container, field: field)
    }

    /// Bitwarden 专用提交。Bitwarden 扩展 popup 也是 Chromium 网页表单——`AXPress` 空操作、
    /// 密码框可能开 SEI（回车被拦），故同样走**合成鼠标点击**解锁按钮。
    ///
    /// 与 1Password 的"箭头在框右侧"不同：Bitwarden 的 `Unlock` 按钮在密码框**正下方**、整宽
    /// （实测 field y=391/h=38，Unlock y=446；更下方还有 Log out y=546）。策略：深扫容器，排除
    /// 窗口控件/Cancel，取"位于密码框下方、横向与框重叠、最靠上（紧挨框下）"的按钮 = Unlock，
    /// 天然排除框上方的账户/弹出键与更下方的 Log out。找不到才退回通用 submit。
    @discardableResult
    func submitBitwarden(field: AXUIElement, container: AXUIElement) -> Bool {
        guard let ff = frame(of: field) else {
            logLine("submitBitwarden: no field frame, falling back to generic submit")
            return submit(container: container, field: field)
        }
        let excludedSubroles: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXFullScreenButton", "AXZoomButton", "AXCancelButton"]
        let buttons = collectButtons(container, maxDepth: 16).filter { b in
            if let sr = subrole(of: b), excludedSubroles.contains(sr) { return false }
            if title(of: b)?.caseInsensitiveCompare("Cancel") == .orderedSame { return false }
            return true
        }
        // 位于密码框**紧下方**（顶缘不高于框底，且距框底不超过约 2.5 个框高——排除更下方的 Log out）
        // + 横向与框重叠；多个取最靠上者（紧挨框下 = Unlock）。若 Unlock 按钮缺失，最近的也超距 → 不点，退回。
        let unlock = buttons
            .compactMap { b -> (AXUIElement, CGRect)? in frame(of: b).map { (b, $0) } }
            .filter { $0.1.minY >= ff.maxY - ff.height * 0.5
                      && $0.1.minY <= ff.maxY + ff.height * 2.5
                      && $0.1.maxX > ff.minX && $0.1.minX < ff.maxX }
            .min(by: { $0.1.minY < $1.1.minY })
        if let unlock {
            let center = CGPoint(x: unlock.1.midX, y: unlock.1.midY)
            logLine("submitBitwarden → click Unlock center=\(center) frame=\(unlock.1)")
            clickMouse(at: center)
            return true
        }
        logLine("submitBitwarden: unlock button not located geometrically, falling back to generic submit")
        return submit(container: container, field: field)
    }

    // MARK: - 主按钮定位（默认/取消按钮 + 诊断）

    /// 读取容器（及其所在窗口）的 `AXDefaultButton`——回车会触发的按钮。
    private func defaultButton(near el: AXUIElement) -> AXUIElement? {
        if let b = axElement(el, "AXDefaultButton") { return b }
        if let win = enclosingWindow(of: el), let b = axElement(win, "AXDefaultButton") { return b }
        return nil
    }

    /// 读取容器（及其所在窗口）的 `AXCancelButton`——即使按钮本身缺 subrole，
    /// 窗口通常仍暴露该属性指向取消按钮，用于身份排除。
    private func cancelButton(near el: AXUIElement) -> AXUIElement? {
        if let b = axElement(el, "AXCancelButton") { return b }
        if let win = enclosingWindow(of: el), let b = axElement(win, "AXCancelButton") { return b }
        return nil
    }

    private func enclosingWindow(of el: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = el
        var depth = 0
        while let node = current, depth < 12 {
            if role(of: node) == "AXWindow" { return node }
            var parentRef: CFTypeRef?
            AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parentRef)
            current = (parentRef.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil })
            depth += 1
        }
        return nil
    }

    private func axElement(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private func title(of el: AXUIElement) -> String? {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &ref)
        if let s = ref as? String, !s.isEmpty { return s }
        AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &ref)
        return ref as? String
    }

    /// 诊断：把候选按钮（标题/subrole/frame）与默认/取消按钮身份打进日志，
    /// 供反查为何选错按钮。
    private func logCandidates(_ container: AXUIElement) {
        let buttons = collectButtons(container, maxDepth: 6)
        let defTitle = defaultButton(near: container).flatMap { title(of: $0) } ?? "nil"
        let cancelTitle = cancelButton(near: container).flatMap { title(of: $0) } ?? "nil"
        logLine("submit candidates: default='\(defTitle)' cancel='\(cancelTitle)' count=\(buttons.count)")
        for (i, b) in buttons.enumerated() {
            let f = frame(of: b) ?? .zero
            logLine("  [\(i)] title='\(title(of: b) ?? "?")' subrole=\(subrole(of: b) ?? "nil") maxX=\(Int(f.maxX)) y=\(Int(f.minY))")
        }
    }

    private func logLine(_ s: String) {
        NSLog("AuthInjector: %@", s)
        Task { @MainActor in LogManager.shared.log("[inject] " + s) }
    }

    /// 合成 Return 键（虚拟键 0x24）。secure field 上可能被 Secure Event Input 拦，仅作最后兜底。
    @discardableResult
    private func pressReturnKey() -> Bool {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: false) else { return false }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// App Store 多步向导（对齐 AuthProbe 里实测稳定的 appStoreAutoFlow）：
    /// **直接锁定 App Store 进程的 AX 树**（不依赖 frontmost / 焦点）→ 按主按钮（Install）
    /// → 轮询密码框出现（**子树扫描，不要求已聚焦**）→ 自己聚焦（kAXFocused，失败合成鼠标点击）
    /// → 注入 → 按 Sign In。
    ///
    /// 旧实现每轮用 `AuthContextDetector` 检测，依赖 frontmost==AppStore + 密码框已聚焦；
    /// 多步流程中焦点/前台会漂移，导致返回 none/confirmSheet → 卡顿、或在未聚焦的密码页
    /// 误按 Sign In。改成 probe 的进程定向扫描后不再依赖这两者。
    /// - Parameter confirmSheet: 检测器传入的初始确认页（此实现改为按进程重新扫描，保留参数仅为兼容）。
    func driveAppStore(confirmSheet: AXUIElement, secret: String, completion: @escaping (Bool) -> Void) {
        guard let app = appStoreApp() else {
            logLine("driveAppStore: App Store process not found")
            completion(false)
            return
        }

        // Step1：还没到密码页 → 按主按钮（Install）。已在密码页则跳过。
        let roots = appStoreAuthRoots(app)
        if firstSecureField(in: roots) == nil {
            if let container = roots.first {
                logLine("driveAppStore: Step1 press primary")
                submit(container: container)
            }
        } else {
            logLine("driveAppStore: Step1 skipped (secure field present)")
        }

        // Step2：轮询密码框出现（子树扫描，最多 ~12s）。
        pollSecureField(app: app, tries: 60, interval: 0.2) { field in
            guard let field = field else {
                self.logLine("driveAppStore: Step2 timeout, no secure field")
                completion(false)
                return
            }
            // Step3：聚焦 + 注入。
            self.logLine("driveAppStore: Step3 focus + inject")
            self.focus(field)
            self.inject(secret, into: field)
            // Step4：略等值落定 → 按 Sign In。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let container = self.appStoreAuthRoots(app).first
                let ok = container.map { self.submit(container: $0, field: field) } ?? false
                self.logLine("driveAppStore: Step4 submit → \(ok)")
                completion(ok)
            }
        }
    }

    // MARK: - App Store 进程定向 AX 扫描（对齐 AuthProbe）

    private func appStoreApp() -> AXUIElement? {
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.apple.AppStore" }) else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    /// App Store 认证区：优先窗口下第一个 AXSheet（排除商店背景的 Get/Buy），否则退回窗口。
    private func appStoreAuthRoots(_ app: AXUIElement) -> [AXUIElement] {
        let ws = windows(of: app)
        if let sheet = firstDescendant(in: ws, maxNodes: 6000, where: { self.role(of: $0) == "AXSheet" }) {
            return [sheet]
        }
        return ws
    }

    private func windows(of app: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success,
              let arr = v as? [AXUIElement] else { return [] }
        return arr
    }

    /// 子树扫描密码框——**不要求聚焦**（probe 的关键点：页面刚加载、焦点未落定也能命中）。
    private func firstSecureField(in roots: [AXUIElement]) -> AXUIElement? {
        firstDescendant(in: roots, maxNodes: 6000) {
            self.subrole(of: $0) == (kAXSecureTextFieldSubrole as String) || self.role(of: $0) == "AXSecureTextField"
        }
    }

    /// 有界递归找第一个满足条件的后代（含 roots 自身）。
    private func firstDescendant(in roots: [AXUIElement], maxNodes: Int,
                                 where match: (AXUIElement) -> Bool) -> AXUIElement? {
        var budget = maxNodes
        func rec(_ el: AXUIElement) -> AXUIElement? {
            if budget <= 0 { return nil }
            budget -= 1
            if match(el) { return el }
            for c in children(of: el) {
                if let hit = rec(c) { return hit }
            }
            return nil
        }
        for r in roots {
            if let hit = rec(r) { return hit }
        }
        return nil
    }

    private func pollSecureField(app: AXUIElement, tries: Int, interval: TimeInterval,
                                 done: @escaping (AXUIElement?) -> Void) {
        if let f = firstSecureField(in: appStoreAuthRoots(app)) { done(f); return }
        guard tries > 0 else { done(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            self.pollSecureField(app: app, tries: tries - 1, interval: interval, done: done)
        }
    }

    // MARK: - AX / geometry helpers

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

    /// 有界深度收集 AXButton 子孙（防止病态 AX 树导致无界递归）。
    private func collectButtons(_ el: AXUIElement, maxDepth: Int) -> [AXUIElement] {
        if maxDepth < 0 { return [] }
        var out: [AXUIElement] = []
        for kid in children(of: el) {
            if role(of: kid) == "AXButton" { out.append(kid) }
            out.append(contentsOf: collectButtons(kid, maxDepth: maxDepth - 1))
        }
        return out
    }

    /// 安全桥接：CFTypeRef? → AXValue？直接 `as!` 强转在类型不符时会崩溃，
    /// 因此先用 CFGetTypeID 校验实际类型再转换（与 AuthContextDetector.toAXUIElement 同一防御模式）。
    private func toAXValue(_ ref: CFTypeRef?) -> AXValue? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        return (ref as! AXValue)
    }

    private func frame(of el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = toAXValue(posRef),
              let sizeValue = toAXValue(sizeRef)
        else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue, .cgPoint, &pos)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    private func frameCenter(of el: AXUIElement) -> CGPoint? {
        guard let f = frame(of: el) else { return nil }
        return CGPoint(x: f.midX, y: f.midY)
    }

    /// 合成鼠标点击（不是 KEY 事件）：Secure Event Input 只拦截键盘合成事件，鼠标事件不受影响。
    private func clickMouse(at p: CGPoint) {
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
