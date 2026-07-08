// AuthProbe.app — 认证密码框检测测试工具(可跨设备/跨 macOS 版本)
//
// 目的:在不同 Mac / macOS 版本上验证——当 Passwords.app 解锁 或 App Store 付款认证
// 出现时,immurok 能否用 Accessibility 精确定位到密码输入框(AXSecureTextField)。
// 检测到即弹对话框报告结果。只用辅助功能权限,不用屏幕录制/OCR。
//
// 用法:双击运行 → 首次授权辅助功能(系统设置里勾选 AuthProbe)→ 触发
//   Passwords 解锁 / App Store 点购买输密码 → 自动弹窗;也可点窗口里“立即检测”。

import AppKit
import ApplicationServices
import Carbon   // IsSecureEventInputEnabled()

// 已知目标 App(仅用于命名/标注);焦点信号的检测对任意 App 都生效。
let KNOWN: [String: String] = [
    "com.apple.Passwords": "Passwords",
    "com.apple.AppStore": "App Store",
    "com.apple.Safari": "Safari",
]
// 需要“全树主动扫描(还没聚焦也扫)”的 App。Safari 不在此列——它的窗口树太大,
// 且网页里的普通密码框会误报;Safari 的登录 / AutoFill sign in 窗口靠
// “焦点进入密码框”这个主信号捕获。
let FULLSCAN = ["com.apple.Passwords", "com.apple.AppStore"]

// ───────────────────────── AX 工具 ─────────────────────────
func axStr(_ el: AXUIElement, _ attr: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}
func axBool(_ el: AXUIElement, _ attr: String) -> Bool {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return false }
    return (v as? Bool) ?? ((v as? NSNumber)?.boolValue ?? false)
}
func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success,
          let arr = v as? [AXUIElement] else { return [] }
    return arr
}
func pidOf(_ el: AXUIElement) -> pid_t {
    var pid: pid_t = 0
    return AXUIElementGetPid(el, &pid) == .success ? pid : -1
}

// ───────────────────────── 扫描结果 ─────────────────────────
struct Finding {
    var app = ""
    var bundle = ""
    var secureField = false      // 是否找到 AXSecureTextField(核心问题)
    var secureFocused = false    // 密码框当前是否聚焦
    var sheetPresent = false     // 是否存在认证 sheet
    var texts: [String] = []     // 上下文文字(供人工核对)
    var buttons: [String] = []   // 按钮(Sign In / Install / ...)
}

struct ScanAcc {
    var secureField = false
    var secureFocused = false
    var sheet = false
    var texts: [String] = []
    var buttons: [String] = []
    var nodes = 0
}

func scan(_ el: AXUIElement, insideSheet: Bool, collectAll: Bool, acc: inout ScanAcc, depth: Int) {
    if acc.nodes > 6000 || depth > 45 { return }
    acc.nodes += 1
    let role = axStr(el, kAXRoleAttribute as String) ?? ""
    let sub = axStr(el, kAXSubroleAttribute as String)
    var nowInSheet = insideSheet
    if role == "AXSheet" { acc.sheet = true; nowInSheet = true }
    if sub == "AXSecureTextField" || role == "AXSecureTextField" {
        acc.secureField = true
        if axBool(el, kAXFocusedAttribute as String) { acc.secureFocused = true }
    }
    if nowInSheet || collectAll {
        if role == "AXStaticText", let v = axStr(el, kAXValueAttribute as String), !v.isEmpty {
            if acc.texts.count < 30 { acc.texts.append(v) }
        }
        if role == "AXButton" {
            let t = axStr(el, kAXTitleAttribute as String) ?? axStr(el, kAXDescriptionAttribute as String)
            if let t = t, !t.isEmpty, acc.buttons.count < 20 { acc.buttons.append(t) }
        }
    }
    for c in axChildren(el) { scan(c, insideSheet: nowInSheet, collectAll: collectAll, acc: &acc, depth: depth + 1) }
}

// 扫某个目标 App 的所有窗口
func scanApp(bundle: String, name: String) -> Finding? {
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundle }) else {
        return nil
    }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &v) == .success,
          let wins = v as? [AXUIElement], !wins.isEmpty else { return nil }
    // Passwords 的锁屏在普通窗口里(非 sheet),要全树收文字;App Store 只收 sheet 内文字
    let collectAll = (bundle == "com.apple.Passwords")
    var acc = ScanAcc()
    for w in wins { scan(w, insideSheet: false, collectAll: collectAll, acc: &acc, depth: 0) }
    var f = Finding()
    f.app = name; f.bundle = bundle
    f.secureField = acc.secureField
    f.secureFocused = acc.secureFocused
    f.sheetPresent = acc.sheet
    f.texts = acc.texts
    f.buttons = acc.buttons
    return f
}

// 系统级焦点:当前聚焦元素若是密码框,返回该元素及其归属 App(适配任意 App)
func focusedSecureField() -> (el: AXUIElement, bundle: String, name: String)? {
    let sys = AXUIElementCreateSystemWide()
    var f: CFTypeRef?
    guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &f) == .success,
          let el = f, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
    let e = el as! AXUIElement
    guard axStr(e, kAXSubroleAttribute as String) == "AXSecureTextField" else { return nil }
    let pid = pidOf(e)
    guard let app = NSRunningApplication(processIdentifier: pid),
          let bundle = app.bundleIdentifier else { return nil }
    let name = KNOWN[bundle] ?? (app.localizedName ?? bundle)
    return (e, bundle, name)
}

// 从聚焦的密码框向上找最近的容器(优先 AXSheet,否则最近的 AXWindow)
func nearestContainer(of el: AXUIElement) -> (container: AXUIElement, isSheet: Bool) {
    var cur = el
    var lastWindow = el
    for _ in 0..<20 {
        var p: CFTypeRef?
        guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &p) == .success,
              let pv = p, CFGetTypeID(pv) == AXUIElementGetTypeID() else { break }
        let parent = pv as! AXUIElement
        let role = axStr(parent, kAXRoleAttribute as String) ?? ""
        if role == "AXSheet" { return (parent, true) }
        if role == "AXWindow" { lastWindow = parent }
        cur = parent
    }
    return (lastWindow, false)
}

// 由聚焦的密码框直接构造报告——从最近容器取上下文,适配 Safari 这类大窗口树
func findingFromFocused(_ field: AXUIElement, bundle: String, name: String) -> Finding {
    var f = Finding()
    f.app = name; f.bundle = bundle
    f.secureField = true; f.secureFocused = true
    let (container, isSheet) = nearestContainer(of: field)
    f.sheetPresent = isSheet
    var acc = ScanAcc()
    scan(container, insideSheet: isSheet, collectAll: true, acc: &acc, depth: 0)
    if acc.sheet { f.sheetPresent = true }
    f.texts = acc.texts
    f.buttons = acc.buttons
    return f
}

// ───────────────────────── App ─────────────────────────
let osVer = ProcessInfo.processInfo.operatingSystemVersion
let osStr = "macOS \(osVer.majorVersion).\(osVer.minorVersion).\(osVer.patchVersion)"

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var textView: NSTextView!
    var statusLabel: NSTextField!
    var timer: Timer?
    var lastState: [String: String] = [:]   // bundle -> 已报告状态,去重防刷屏
    var tickCount = 0
    var lastSecureField: AXUIElement?        // 最近一次聚焦到的密码框(供注入测试用)
    var lastSecureFieldName = ""
    var injectField: NSTextField!            // 要注入的自定义字符串(可填真实密码)
    // 语言容错的按钮关键词(小写匹配 title/desc);找不到默认按钮时用
    let installWords = ["install", "get", "buy", "安装", "安裝", "获取", "獲取", "购买", "購買", "購入", "取得", "下载", "下載", "免费", "免費", "update", "更新"]
    let signinWords  = ["sign in", "signin", "sign", "登录", "登入", "サインイン", "确定", "確定", "continue", "继续", "繼續"]
    let cancelWords  = ["cancel", "取消", "取り消", "forgot", "忘记", "忘記", "later", "稍后", "稍後", "not now"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMainMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)

        if !AXIsProcessTrusted() {
            log("⚠️ 未获辅助功能权限。正在弹出授权请求…")
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            log("请到 系统设置 ▸ 隐私与安全性 ▸ 辅助功能,勾选 “AuthProbe”,然后重启本程序。")
            statusLabel.stringValue = "❌ 需要辅助功能权限"
        } else {
            log("✅ 辅助功能权限 OK。\(osStr)")
            statusLabel.stringValue = "监控中… 请触发 Passwords 解锁 或 App Store 购买"
        }
        log("提示:也可随时点“立即检测”按钮,对当前屏幕上的认证界面强制出一次报告。\n")

        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    // 主菜单——提供 Cmd+Q 退出、Cmd+H 隐藏,以及日志区可用的复制/全选
    func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "隐藏 AuthProbe", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 AuthProbe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 620, height: 520)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "immurok AuthProbe — 密码框检测测试"
        window.center()

        let container = NSView(frame: rect)

        // 第一行:状态 + 立即检测
        statusLabel = NSTextField(labelWithString: "启动中…")
        statusLabel.frame = NSRect(x: 12, y: rect.height - 32, width: rect.width - 140, height: 20)
        statusLabel.autoresizingMask = [.width, .minYMargin]
        container.addSubview(statusLabel)

        let detectBtn = NSButton(title: "立即检测", target: self, action: #selector(manualCheck))
        detectBtn.frame = NSRect(x: rect.width - 120, y: rect.height - 40, width: 108, height: 28)
        detectBtn.autoresizingMask = [.minXMargin, .minYMargin]
        detectBtn.bezelStyle = .rounded
        container.addSubview(detectBtn)

        // 第二行:注入字符串 + 两个注入按钮
        let injectLabel = NSTextField(labelWithString: "注入字符串:")
        injectLabel.frame = NSRect(x: 12, y: rect.height - 70, width: 72, height: 20)
        injectLabel.autoresizingMask = [.minYMargin]
        container.addSubview(injectLabel)

        injectField = NSTextField(string: "helloworld")
        injectField.frame = NSRect(x: 88, y: rect.height - 72, width: 150, height: 24)
        injectField.autoresizingMask = [.minYMargin]
        injectField.placeholderString = "要注入的字符串(可填真实密码)"
        container.addSubview(injectField)

        let injectBtn = NSButton(title: "注入(A:AX / B:键击)", target: self, action: #selector(injectHello))
        injectBtn.frame = NSRect(x: 244, y: rect.height - 74, width: 168, height: 28)
        injectBtn.autoresizingMask = [.minYMargin]
        injectBtn.bezelStyle = .rounded
        container.addSubview(injectBtn)

        let submitBtn = NSButton(title: "注入并提交(AX)", target: self, action: #selector(injectAndSubmit))
        submitBtn.frame = NSRect(x: 418, y: rect.height - 74, width: 150, height: 28)
        submitBtn.autoresizingMask = [.minYMargin]
        submitBtn.bezelStyle = .rounded
        container.addSubview(submitBtn)

        // 第三行:App Store 全自动流程
        let flowBtn = NSButton(title: "App Store 一键流程(Install→聚焦→注入→Sign In)",
                               target: self, action: #selector(appStoreAutoFlow))
        flowBtn.frame = NSRect(x: 12, y: rect.height - 110, width: 396, height: 28)
        flowBtn.autoresizingMask = [.minYMargin]
        flowBtn.bezelStyle = .rounded
        container.addSubview(flowBtn)

        let flowHint = NSTextField(labelWithString: "⚠️ 会真实点击 Install/Sign In,请用免费 app 测试")
        flowHint.frame = NSRect(x: 416, y: rect.height - 106, width: 190, height: 20)
        flowHint.font = NSFont.systemFont(ofSize: 10)
        flowHint.textColor = .secondaryLabelColor
        flowHint.autoresizingMask = [.minYMargin]
        container.addSubview(flowHint)

        let scroll = NSScrollView(frame: NSRect(x: 12, y: 12, width: rect.width - 24, height: rect.height - 128))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        container.addSubview(scroll)

        window.contentView = container
        window.makeKeyAndOrderFront(nil)
    }

    func log(_ s: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(stamp)] \(s)\n"
        textView.textStorage?.append(NSAttributedString(
            string: line,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: NSColor.textColor]))
        textView.scrollToEndOfDocument(nil)
    }

    // 自动轮询:焦点落到目标 App 的密码框 → 报告
    func tick() {
        tickCount += 1
        if tickCount % 25 == 0 { log("… 监控中(第 \(tickCount) 次轮询)") }

        // 主信号:系统级焦点落到任意 App 的密码框(语言无关、最精确)。
        // 这条能捕获 Safari 登录 / AutoFill 的 sign in 窗口,以及任意其它密码框。
        if let hit = focusedSecureField() {
            lastSecureField = hit.el          // 记住供“注入 helloworld”按钮使用
            lastSecureFieldName = hit.name
            let key = "focused:\(hit.bundle)"
            if lastState["_focus"] != key {
                lastState["_focus"] = key
                report(findingFromFocused(hit.el, bundle: hit.bundle, name: hit.name),
                       trigger: "焦点进入密码框")
            }
            return
        } else {
            lastState["_focus"] = nil
        }

        // 次信号:Passwords / App Store 出现认证界面(即使还没聚焦密码框也报一次)
        for bundle in FULLSCAN {
            let name = KNOWN[bundle] ?? bundle
            guard let f = scanApp(bundle: bundle, name: name) else { lastState[bundle] = nil; continue }
            let reportable = f.secureField || f.sheetPresent
            let key = "\(f.secureField)-\(f.sheetPresent)"
            if !reportable { lastState[bundle] = nil; continue }
            if lastState[bundle] == key { continue }
            lastState[bundle] = key
            report(f, trigger: "出现认证界面")
        }
    }

    @objc func manualCheck() {
        var any = false
        // 1) 任意 App 的聚焦密码框(含 Safari sign in 窗口)
        if let hit = focusedSecureField() {
            any = true
            report(findingFromFocused(hit.el, bundle: hit.bundle, name: hit.name),
                   trigger: "手动检测(聚焦密码框)")
        }
        // 2) Passwords / App Store 的认证界面全树扫描
        for bundle in FULLSCAN {
            let name = KNOWN[bundle] ?? bundle
            if let f = scanApp(bundle: bundle, name: name), f.secureField || f.sheetPresent {
                any = true
                report(f, trigger: "手动检测")
            }
        }
        if !any {
            log("手动检测:当前没有聚焦的密码框,也没找到 Passwords / App Store 认证界面。")
            let a = NSAlert()
            a.messageText = "没检测到密码框 / 认证界面"
            a.informativeText = "现在没有聚焦的密码框,也没找到 Passwords / App Store 的认证窗口。\n请先让认证界面出现(并点进密码框)再检测。\n\nSafari:点开某网站登录框、触发密码 AutoFill 的 sign in 窗口后再点“立即检测”。"
            a.runModal()
        }
    }

    // ── 注入测试:往最近聚焦的密码框写 "helloworld" ──
    // 测两种“软件”注入(本 app 不接 BLE 设备,无法模拟真实 HID):
    //   方法A AX 直接设值——不经键盘,不受 Secure Event Input 影响;看安全框是否放行
    //   方法B CGEvent 合成键击——模拟软件键盘,SEI 开启时预计被拦
    @objc func injectHello() {
        guard let field = lastSecureField else {
            let a = NSAlert()
            a.messageText = "没有可注入的密码框"
            a.informativeText = "请先点进一个密码框(Passwords / App Store / Safari 的),让本工具捕获到它,再点此按钮。"
            a.runModal()
            return
        }
        let text = injectField.stringValue.isEmpty ? "helloworld" : injectField.stringValue
        log("── 注入测试开始(目标:\(lastSecureFieldName),字符串:\(text))──")

        // 方法A:AX 直接设值(立即,针对元素本身,不需要聚焦)
        let axErr = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString)
        let axOK = (axErr == .success)
        log("方法A AX 设值 kAXValue:\(axOK ? "调用返回成功(AXError=0)" : "被拒/不支持(AXError=\(axErr.rawValue))")")

        // 方法B:CGEvent 需要密码框保持聚焦——倒计时让用户点回去
        log("方法B:3 秒后发送 CGEvent 合成键击,请立刻点回密码框并保持聚焦…")
        var n = 3
        func step() {
            if n > 0 { log("  \(n)…"); n -= 1; DispatchQueue.main.asyncAfter(deadline: .now() + 1) { step() }; return }
            let sei = IsSecureEventInputEnabled()
            log("发送前 Secure Event Input(SEI):\(sei ? "开启(合成键击预计被拦)" : "关闭")")
            self.postCGEventString(text)
            log("方法B CGEvent:\(text) 已发送")
            self.finishInjectReport(sei: sei, axOK: axOK, axErr: axErr)
        }
        step()
    }

    // 注入 + 用 AX 直接提交(不走键盘,不受 SEI 影响):端到端验证“注入的密码真能认证”
    @objc func injectAndSubmit() {
        guard let field = lastSecureField else {
            let a = NSAlert()
            a.messageText = "没有可注入的密码框"
            a.informativeText = "请先点进一个密码框让工具捕获,再点此按钮。"
            a.runModal()
            return
        }
        let text = injectField.stringValue.isEmpty ? "helloworld" : injectField.stringValue
        log("── 注入并提交(目标:\(lastSecureFieldName),字符串:\(text))──")

        let axErr = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString)
        log("AX 设值:\(axErr == .success ? "成功" : "失败(AXError=\(axErr.rawValue))")")

        // 提交尝试A:对字段执行 Confirm(等价回车,非键盘事件)
        let cErr = AXUIElementPerformAction(field, kAXConfirmAction as CFString)
        log("提交A field.AXConfirm:\(cErr == .success ? "已执行" : "不支持(AXError=\(cErr.rawValue))")")

        // 提交尝试B:找所在窗口/sheet 的默认按钮并按下(Sign In / Install / 解锁 …)
        var submitB = "无默认按钮(Safari 网页表单常无)"
        if let btn = findDefaultButton(from: field) {
            let title = axStr(btn, kAXTitleAttribute as String)
                ?? axStr(btn, kAXDescriptionAttribute as String) ?? "?"
            let pErr = AXUIElementPerformAction(btn, kAXPressAction as CFString)
            submitB = "默认按钮“\(title)” press:\(pErr == .success ? "已按下" : "失败(AXError=\(pErr.rawValue))")"
        }
        log("提交B \(submitB)")

        let body = """
        目标 App:\(lastSecureFieldName)
        注入字符串:\(text)
        AX 设值:\(axErr == .success ? "成功" : "失败(AXError=\(axErr.rawValue))")
        提交A(field.AXConfirm):\(cErr == .success ? "已执行" : "不支持(\(cErr.rawValue))")
        提交B:\(submitB)

        关键观察:是否真的认证通过 / 登录成功?
        • 通过 → AX 注入的密码是“真实值”,能端到端认证 ✅
        • 框里有字但登录失败 → 值没真正生效(Safari 网页多半是没触发 input 事件)
        """
        log("── 注入并提交 结束 ──")
        let a = NSAlert()
        a.messageText = "注入+提交:\(lastSecureFieldName)"
        a.informativeText = body
        a.addButton(withTitle: "好")
        a.addButton(withTitle: "复制报告")
        if a.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)
        }
    }

    // 从密码框沿父链向上,返回第一个带默认按钮的祖先(窗口/sheet)的默认按钮
    func findDefaultButton(from el: AXUIElement) -> AXUIElement? {
        var cur = el
        for _ in 0..<25 {
            var p: CFTypeRef?
            guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &p) == .success,
                  let pv = p, CFGetTypeID(pv) == AXUIElementGetTypeID() else { break }
            let parent = pv as! AXUIElement
            var d: CFTypeRef?
            if AXUIElementCopyAttributeValue(parent, kAXDefaultButtonAttribute as CFString, &d) == .success,
               let dv = d, CFGetTypeID(dv) == AXUIElementGetTypeID() {
                return (dv as! AXUIElement)
            }
            cur = parent
        }
        return nil
    }

    // ── App Store 一键流程 + 相关 AX 工具 ──
    func runningAXApp(_ bundle: String) -> AXUIElement? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundle })
        else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }
    func axWindows(_ app: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success,
              let arr = v as? [AXUIElement] else { return [] }
        return arr
    }
    func firstElement(in roots: [AXUIElement], match: (AXUIElement, String) -> Bool) -> AXUIElement? {
        var result: AXUIElement?
        var budget = 6000
        func rec(_ el: AXUIElement) {
            if result != nil || budget <= 0 { return }
            budget -= 1
            let role = axStr(el, kAXRoleAttribute as String) ?? ""
            if match(el, role) { result = el; return }
            for c in axChildren(el) { rec(c); if result != nil { return } }
        }
        for r in roots { rec(r); if result != nil { break } }
        return result
    }
    func firstSecureField(in roots: [AXUIElement]) -> AXUIElement? {
        firstElement(in: roots) { el, role in
            axStr(el, kAXSubroleAttribute as String) == "AXSecureTextField" || role == "AXSecureTextField"
        }
    }
    func defaultButton(of el: AXUIElement) -> AXUIElement? {
        var d: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXDefaultButtonAttribute as CFString, &d) == .success,
           let dv = d, CFGetTypeID(dv) == AXUIElementGetTypeID() { return (dv as! AXUIElement) }
        return nil
    }
    func anyDefaultButton(in roots: [AXUIElement]) -> AXUIElement? {
        for r in roots { if let b = defaultButton(of: r) { return b } }
        if let sheet = firstElement(in: roots, match: { $1 == "AXSheet" }), let b = defaultButton(of: sheet) { return b }
        return nil
    }
    func btnTitle(_ btn: AXUIElement) -> String {
        axStr(btn, kAXTitleAttribute as String) ?? axStr(btn, kAXDescriptionAttribute as String) ?? "?"
    }
    func axValuePoint(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
              let val = v, CFGetTypeID(val) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero
        return AXValueGetValue(val as! AXValue, .cgPoint, &pt) ? pt : nil
    }
    func axValueSize(_ el: AXUIElement, _ attr: String) -> CGSize? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
              let val = v, CFGetTypeID(val) == AXValueGetTypeID() else { return nil }
        var sz = CGSize.zero
        return AXValueGetValue(val as! AXValue, .cgSize, &sz) ? sz : nil
    }
    // 聚焦密码框:先 kAXFocused=true;失败则合成鼠标点击其中心(鼠标事件不被 SEI 拦)
    func focusField(_ field: AXUIElement) {
        let e = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        var back: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(field, kAXFocusedAttribute as CFString, &back)
        let focused = (back as? Bool) ?? ((back as? NSNumber)?.boolValue ?? false)
        log("  设 kAXFocused=true:\(e == .success ? "OK" : "AXError=\(e.rawValue)"),读回 focused=\(focused)")
        if !focused,
           let pt = axValuePoint(field, kAXPositionAttribute as String),
           let sz = axValueSize(field, kAXSizeAttribute as String) {
            let c = CGPoint(x: pt.x + sz.width / 2, y: pt.y + sz.height / 2)
            let src = CGEventSource(stateID: .combinedSessionState)
            CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: c, mouseButton: .left)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: c, mouseButton: .left)?.post(tap: .cghidEventTap)
            log("  fallback 合成鼠标点击密码框中心 (\(Int(c.x)),\(Int(c.y)))")
        }
    }
    // 非阻塞轮询:cond 命中即回调 done(元素);超次数回调 done(nil)
    func poll(tries: Int, interval: TimeInterval, cond: @escaping () -> AXUIElement?, done: @escaping (AXUIElement?) -> Void) {
        if let hit = cond() { done(hit); return }
        if tries <= 0 { done(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            self.poll(tries: tries - 1, interval: interval, cond: cond, done: done)
        }
    }

    // 认证区:优先取 sheet(把商店背景那些 Get/Buy 按钮排除在外),否则退回窗口
    func authRoots(_ app: AXUIElement) -> [AXUIElement] {
        let ws = axWindows(app)
        if let sheet = firstElement(in: ws, match: { $1 == "AXSheet" }) { return [sheet] }
        return ws
    }
    func allButtons(in roots: [AXUIElement]) -> [AXUIElement] {
        var out: [AXUIElement] = []; var budget = 6000
        func rec(_ el: AXUIElement) {
            if budget <= 0 || out.count > 40 { return }
            budget -= 1
            if (axStr(el, kAXRoleAttribute as String) ?? "") == "AXButton" { out.append(el) }
            for c in axChildren(el) { rec(c) }
        }
        for r in roots { rec(r) }
        return out
    }
    func axFrame(_ el: AXUIElement) -> CGRect? {
        guard let p = axValuePoint(el, kAXPositionAttribute as String),
              let s = axValueSize(el, kAXSizeAttribute as String) else { return nil }
        return CGRect(origin: p, size: s)
    }
    // 结构化排除取消键后、按 HIG 惯例取最右的主按钮(语言无关的几何规则)
    func geometryPrimary(in btns: [AXUIElement]) -> AXUIElement? {
        let nonCancel = btns.filter { axStr($0, kAXSubroleAttribute as String) != "AXCancelButton" }
        return nonCancel.max(by: { (axFrame($0)?.maxX ?? -1) < (axFrame($1)?.maxX ?? -1) })
    }
    // 分层选主操作按钮,并把候选/几何判断全打进 log 以便校准语言无关规则
    func pickPrimary(in roots: [AXUIElement], keywords: [String], avoid: [String], label: String) -> (btn: AXUIElement, how: String)? {
        if let db = anyDefaultButton(in: roots) { log("  [\(label)] 命中 kAXDefaultButton:「\(btnTitle(db))」"); return (db, "kAXDefaultButton") }

        let btns = allButtons(in: roots)
        log("  [\(label)] 候选按钮 \(btns.count) 个:")
        for b in btns {
            let sub = axStr(b, kAXSubroleAttribute as String) ?? "-"
            let frs = axFrame(b).map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))" } ?? "?"
            log("    · 「\(btnTitle(b))」 subrole=\(sub) frame=\(frs)")
        }
        if let geo = geometryPrimary(in: btns) {
            log("  [\(label)] 参考·几何最右(排除AXCancelButton)会选:「\(btnTitle(geo))」")
        }

        // 当前实际用关键词推进(几何是否可靠等日志校准);关键词也没有则退回几何
        if let kw = btns.first(where: { b in
            let l = btnTitle(b).lowercased()
            return !avoid.contains(where: { l.contains($0) }) && keywords.contains(where: { l.contains($0) })
        }) { return (kw, "关键词") }
        if let geo = geometryPrimary(in: btns) { return (geo, "几何兜底") }
        return nil
    }

    @objc func appStoreAutoFlow() {
        guard let app = runningAXApp("com.apple.AppStore") else {
            let a = NSAlert()
            a.messageText = "App Store 未运行"
            a.informativeText = "请先打开 App Store 并对某个 app 点“获取/购买”,触发确认框,再点此按钮。建议用免费 app。"
            a.runModal(); return
        }
        let text = injectField.stringValue.isEmpty ? "helloworld" : injectField.stringValue
        log("── App Store 一键流程(Install→聚焦→注入→Sign In)──")

        // 诊断快照:此刻(本 app 已激活)App Store 认证区还在不在?有哪些按钮?
        let ws = axWindows(app)
        let sheet = firstElement(in: ws, match: { $1 == "AXSheet" })
        let roots = authRoots(app)
        let btns = allButtons(in: roots)
        log("  快照:窗口\(ws.count) / sheet \(sheet != nil ? "有" : "无") / 密码框 \(firstSecureField(in: roots) != nil ? "有" : "无")")
        log("  认证区按钮(\(btns.count)):" + btns.prefix(12).map { btnTitle($0) }.joined(separator: " / "))

        // Step1:未到密码页 → 按 Install
        if firstSecureField(in: roots) == nil {
            if let hit = pickPrimary(in: roots, keywords: installWords, avoid: cancelWords, label: "Step1") {
                AXUIElementPerformAction(hit.btn, kAXPressAction as CFString)
                log("Step1 按下「\(btnTitle(hit.btn))」(\(hit.how))→ 进入密码页")
            } else {
                log("Step1 认证区里没找到可按的确认按钮(见上方清单;若为空则失焦后 sheet 被关闭)")
            }
        } else {
            log("Step1 跳过(密码框已存在)")
        }

        // Step2:等密码框出现 → 聚焦
        poll(tries: 40, interval: 0.15, cond: { self.firstSecureField(in: self.authRoots(app)) }) { field in
            guard let field = field else { self.log("Step2 超时:密码框未出现"); return }
            self.log("Step2 密码框已出现,聚焦…")
            self.focusField(field)
            // Step3:注入
            self.log("Step3 注入字符串:\(text)")
            let e = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString)
            self.log("  AX 设值:\(e == .success ? "成功" : "AXError=\(e.rawValue)")")
            // Step4:略等值提交,再按 Sign In(默认按钮或关键词)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let hit = self.pickPrimary(in: self.authRoots(app), keywords: self.signinWords, avoid: self.cancelWords, label: "Step4") {
                    AXUIElementPerformAction(hit.btn, kAXPressAction as CFString)
                    self.log("Step4 按下「\(self.btnTitle(hit.btn))」(\(hit.how))→ 提交登录")
                    self.log("── 流程结束,请看是否登录成功 ──")
                } else {
                    self.log("Step4 未找到提交按钮")
                }
            }
        }
    }

    func postCGEventString(_ s: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for scalar in s.unicodeScalars {
            var ch = UniChar(scalar.value)
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
                up.post(tap: .cghidEventTap)
            }
        }
    }

    func finishInjectReport(sei: Bool, axOK: Bool, axErr: AXError) {
        let body = """
        目标 App:\(lastSecureFieldName)
        系统:\(osStr)
        Secure Event Input:\(sei ? "开启" : "关闭")
        方法A(AX 设值):\(axOK ? "调用成功(AXError=0)" : "失败/不支持(AXError=\(axErr.rawValue))")
        方法B(CGEvent 合成键击):已发送

        请看密码框里是否出现 “helloworld”,判断哪种方法真正生效:
        • 只有 A 进了 → AX 设值可注入(绕过键盘/SEI)——软件即可,是重大发现
        • 只有 B 进了 → 合成键击可注入(此处 SEI 未拦)
        • 两者都没进 → 软件注入被拦,必须靠 immurok 真实 HID 硬件输入(符合预期)
        """
        log("── 注入测试结束 ──")
        for l in body.split(separator: "\n") { log(String(l)) }

        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = "注入测试结果:\(lastSecureFieldName)"
        a.informativeText = body
        a.addButton(withTitle: "好")
        a.addButton(withTitle: "复制报告")
        if a.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)
        }
    }

    func report(_ f: Finding, trigger: String) {
        let verdict = f.secureField
            ? "✅ 精确检测到密码输入框 (AXSecureTextField)"
            : (f.sheetPresent
                ? "⚠️ 检测到认证界面,但未找到密码框(可能是 Touch ID/生物识别 sheet,AX 不可见;或仅是确认框)"
                : "❌ 未检测到密码框")

        var lines = [
            "触发:\(trigger)",
            "App:\(f.app)  (\(f.bundle))",
            "系统:\(osStr)",
            verdict,
        ]
        if f.secureField { lines.append("密码框当前聚焦:\(f.secureFocused ? "是(可直接输入)" : "否")") }
        lines.append("认证 sheet:\(f.sheetPresent ? "有" : "无")")
        if !f.buttons.isEmpty { lines.append("按钮:\(f.buttons.joined(separator: " / "))") }
        if !f.texts.isEmpty { lines.append("上下文文字:\n  " + f.texts.prefix(12).joined(separator: "\n  ")) }
        // 只写 log,不弹对话框——弹窗会把焦点从密码框/认证 sheet 抢走。
        log("──── 检测报告(\(trigger)) ────")
        for l in lines { log(l) }
        log("")
    }
}

let app = NSApplication.shared
let delegate = ProbeDelegate()
app.delegate = delegate
app.run()
