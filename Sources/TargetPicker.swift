import AppKit
import ApplicationServices
import Security
import AuthInjectionKit

/// 准星拾取到的目标身份。
struct PickedTarget {
    var bundleID: String
    var appName: String
    var signing: SigningRequirement
    var targetKind: TargetKind
    var extensionOrigin: String?
    var urlFragment: String?
    var fieldAXIdentifier: String?
}

/// 准星拾取器（仿 Windows TargetPicker）：CGEventTap 全局接管鼠标，悬停高亮元素，
/// 左键确认采集身份（bundleID + 代码签名 + 密码框 AXIdentifier + 浏览器扩展 URL），
/// 右键 / Esc 取消。不铺全屏遮罩（否则 AXUIElementCopyElementAtPosition 会命中遮罩自身）。
final class TargetPicker {
    /// 拾取期间强引用自己，防止临时创建的实例（TargetPicker().pick{...}）被 ARC 提前释放，
    /// 否则 event tap 回调 takeUnretainedValue 会访问已释放对象（hover 失效 + 左键崩溃）。
    private static var active: TargetPicker?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var overlay: NSWindow?
    private var highlightView: HighlightView?
    private var completion: ((PickedTarget?) -> Void)?
    private var hiddenWindows: [NSWindow] = []
    private var cursorPushed = false
    private let systemWide = AXUIElementCreateSystemWide()

    /// 在主线程调用；完成回调回主线程。
    func pick(completion: @escaping (PickedTarget?) -> Void) {
        TargetPicker.active = self   // 保活至 finish()
        self.completion = completion

        // 隐藏 app 自身窗口，避免命中自己。
        hiddenWindows = NSApp.windows.filter { $0.isVisible }
        hiddenWindows.forEach { $0.orderOut(nil) }

        setupOverlay()
        NSCursor.crosshair.push()
        cursorPushed = true

        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let picker = Unmanaged<TargetPicker>.fromOpaque(refcon).takeUnretainedValue()
            return picker.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("TargetPicker: failed to create event tap (need Accessibility permission)")
            finish(with: nil); return
        }
        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .mouseMoved:
            updateHighlight(at: event.location)
            return Unmanaged.passUnretained(event)
        case .leftMouseDown:
            confirm(at: event.location)
            return nil // 吞掉，避免点到目标应用
        case .rightMouseDown:
            finish(with: nil)
            return nil
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 { // Esc
                finish(with: nil)
                return nil
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func element(at point: CGPoint) -> AXUIElement? {
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &el) == .success else { return nil }
        return el
    }

    private func updateHighlight(at point: CGPoint) {
        guard let el = element(at: point) else { highlightView?.update(frame: nil, text: nil); return }
        let f = axFrame(of: el)
        let isSecure = (subrole(of: el) == (kAXSecureTextFieldSubrole as String) || role(of: el) == "AXSecureTextField")
        let appName = NSRunningApplication(processIdentifier: pid(of: el) ?? -1)?.localizedName ?? "?"
        let kindLabel = isSecure ? "🔒 密码框" : (role(of: el) ?? "元素")
        highlightView?.update(frame: f, text: "\(appName) · \(kindLabel)")
    }

    private func confirm(at point: CGPoint) {
        // 先隐藏高亮，再取元素（避免命中覆盖层）。
        highlightView?.update(frame: nil, text: nil)
        overlay?.orderOut(nil)
        let target = element(at: point).flatMap { capture(element: $0) }
        finish(with: target)
    }

    private func finish(with target: PickedTarget?) {
        let done = completion
        cleanup()
        done?(target)
        // 异步丢掉静态强引用：确保 self 活过当前 event-tap 回调调用栈后再释放。
        DispatchQueue.main.async { TargetPicker.active = nil }
    }

    private func cleanup() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        eventTap = nil; runLoopSource = nil
        overlay?.orderOut(nil); overlay = nil; highlightView = nil
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
        hiddenWindows.forEach { $0.makeKeyAndOrderFront(nil) }
        hiddenWindows = []
        completion = nil
    }

    // MARK: - 身份采集

    private func capture(element: AXUIElement) -> PickedTarget? {
        guard let p = pid(of: element),
              let app = NSRunningApplication(processIdentifier: p),
              let bundleID = app.bundleIdentifier else { return nil }
        let appName = app.localizedName ?? bundleID
        let signing = deriveSigning(pid: p)
        let axID = axIdentifier(of: element)
        if let (origin, frag) = webExtensionInfo(of: element) {
            return PickedTarget(bundleID: bundleID, appName: appName, signing: signing,
                targetKind: .browserExtension, extensionOrigin: origin, urlFragment: frag,
                fieldAXIdentifier: axID)
        }
        return PickedTarget(bundleID: bundleID, appName: appName, signing: signing,
            targetKind: .app, extensionOrigin: nil, urlFragment: nil, fieldAXIdentifier: axID)
    }

    /// codesign 身份 → SigningRequirement：apple 一方签名用 .applePlatform；否则读 TeamID 用 .developerID。
    private func deriveSigning(pid: pid_t) -> SigningRequirement {
        var codeRef: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &codeRef) == errSecSuccess, let code = codeRef,
              let stat = staticCode(from: code) else { return .applePlatform }
        // apple platform：anchor apple 校验通过（系统一方签名）
        var appleReq: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &appleReq) == errSecSuccess,
           let r = appleReq, SecStaticCodeCheckValidity(stat, [], r) == errSecSuccess {
            return .applePlatform
        }
        if let teamID = teamIdentifier(of: stat), IdentityValidation.isValidTeamID(teamID) {
            return .developerID(teamID: teamID)
        }
        return .applePlatform
    }

    private func staticCode(from code: SecCode) -> SecStaticCode? {
        var stat: SecStaticCode?
        return SecCodeCopyStaticCode(code, [], &stat) == errSecSuccess ? stat : nil
    }

    private func teamIdentifier(of stat: SecStaticCode) -> String? {
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(stat, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// 从元素向上找最近的 AXWebArea，读其 AXURL，解析扩展 origin + fragment。
    private func webExtensionInfo(of el: AXUIElement) -> (origin: String, fragment: String)? {
        var node: AXUIElement? = el
        var depth = 0
        while let n = node, depth < 20 {
            if role(of: n) == "AXWebArea", let u = url(of: n) {
                return parseExtensionURL(u)
            }
            node = parent(of: n)
            depth += 1
        }
        return nil
    }

    /// chrome-extension://<id>/popup/index.html#/lock → (origin: "chrome-extension://<id>/", fragment: "#/lock")
    /// 无 hash 路由的扩展（如 LastPass 的 …/webclient-extension-toolbar.html）退回用页面路径做判据；
    /// 以前兜底填 "#/"，而检测端是 `url.contains(fragment)`，URL 里根本没有 "#/" 就永远匹配不上。
    private func parseExtensionURL(_ urlStr: String) -> (String, String)? {
        let extSchemes = ["chrome-extension://", "safari-web-extension://", "moz-extension://"]
        guard let scheme = extSchemes.first(where: { urlStr.hasPrefix($0) }) else { return nil }
        // origin = scheme + host + "/"
        let afterScheme = urlStr.dropFirst(scheme.count)
        let host = afterScheme.prefix { $0 != "/" }
        let origin = scheme + host + "/"
        var fragment = ""
        if let hashIdx = urlStr.firstIndex(of: "#") {
            // 只保留路由前缀（去掉可能的查询参数），如 #/lock
            let frag = String(urlStr[hashIdx...])
            fragment = frag.prefix { $0 != "?" }.description
        }
        if fragment.isEmpty {
            // 路径部分：origin 之后到 "?" 为止，如 "/webclient-extension-toolbar.html"
            let path = "/" + urlStr.dropFirst(origin.count).prefix { $0 != "?" && $0 != "#" }
            fragment = path == "/" ? "/" : path
        }
        return (origin, fragment)
    }

    // MARK: - AX helpers

    private func pid(of el: AXUIElement) -> pid_t? {
        var p: pid_t = 0
        return AXUIElementGetPid(el, &p) == .success ? p : nil
    }
    private func role(of el: AXUIElement) -> String? {
        var v: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v); return v as? String
    }
    private func subrole(of el: AXUIElement) -> String? {
        var v: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &v); return v as? String
    }
    private func axIdentifier(of el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXIdentifierAttribute as CFString, &v) == .success else { return nil }
        let s = v as? String
        return (s?.isEmpty == false) ? s : nil
    }
    private func url(of el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXURL" as CFString, &v) == .success else { return nil }
        if let u = v as? URL { return u.absoluteString }
        return v as? String
    }
    private func parent(of el: AXUIElement) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    private func axFrame(of el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?; var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success else { return nil }
        var pos = CGPoint.zero; var size = CGSize.zero
        if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
        if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &size) }
        return CGRect(origin: pos, size: size)
    }

    // MARK: - Overlay

    private func setupOverlay() {
        // 覆盖主显示器（primary，global top-left = 0,0），flipped view 里直接用 AX 全局坐标绘制。
        guard let screen = NSScreen.screens.first else { return }
        let win = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.level = .screenSaver
        win.isOpaque = false
        win.backgroundColor = .clear
        win.ignoresMouseEvents = true
        win.hasShadow = false
        let view = HighlightView(frame: NSRect(origin: .zero, size: screen.frame.size))
        win.contentView = view
        win.orderFrontRegardless()
        overlay = win
        highlightView = view
    }
}

/// 覆盖层里画绿框 + 信息卡。坐标用全局 top-left（primary 屏），view 为 flipped。
private final class HighlightView: NSView {
    private var box: CGRect?
    private var label: String?
    override var isFlipped: Bool { true }

    func update(frame: CGRect?, text: String?) {
        box = frame; label = text
        DispatchQueue.main.async { [weak self] in self?.needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let box else { return }
        NSColor.systemGreen.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(rect: box); path.lineWidth = 3; path.stroke()
        NSColor.systemGreen.withAlphaComponent(0.12).setFill(); path.fill()
        guard let label else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let text = label as NSString
        let textSize = text.size(withAttributes: attrs)
        let pad: CGFloat = 6
        var cardY = box.maxY + 4
        if cardY + textSize.height + pad * 2 > bounds.height { cardY = box.minY - textSize.height - pad * 2 - 4 }
        let card = CGRect(x: box.minX, y: cardY, width: textSize.width + pad * 2, height: textSize.height + pad * 2)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: card, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: card.minX + pad, y: card.minY + pad), withAttributes: attrs)
    }
}
