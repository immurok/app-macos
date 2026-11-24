import AppKit
import ApplicationServices
import AuthInjectionKit

/// 浏览器扩展解锁框的检测（泛化自原 BitwardenDetector）。解锁框归**浏览器进程**，
/// 是浏览器工具栏 popup 里的一个网页 input。三重信任模型：
///   1. 拥有进程确是**正牌浏览器**——按 bundle id + Team ID 钉住代码签名（防冒充）；
///   2. 密码框所处 **AXWebArea 的文档 URL** 属于指定扩展（`chrome-extension://<固定ID>/`
///      前缀 + 指定路由片段，网页无法把自身文档 URL 伪造成扩展 URL）；
///   3. 该 WebArea 内**恰好一个 secure field**（硬化：排除加/改条目等多字段界面）。
struct BrowserExtensionDetector {

    /// 浏览器宿主注册表：bundle id → Team ID（钉住签名）。Chrome 已在真机实测；其余 Chromium
    /// 浏览器用公开 Team ID——若某值不符，该浏览器 fail-closed（签名校验不过 → 不检测 → 绝不误注入）。
    /// Safari/Firefox 的扩展 URL 是每安装随机 UUID，无稳定锚点，不在此列。
    static let browsers: [String: String] = [
        "com.google.Chrome": "EQHXZ8M8AV",            // Google LLC（实测）
        "com.brave.Browser": "KL8N8XSYF4",            // Brave Software, Inc.
        "com.microsoft.edgemac": "UBF8T346G9",        // Microsoft Corporation
        "company.thebrowser.Browser": "S6N382Y83G",   // The Browser Company（Arc）
    ]

    /// 命中则返回 (密码框, 容器 WebArea, 浏览器 bundle id)。
    /// - origin: 扩展来源前缀，如 `chrome-extension://nngceckbapebfimnlniiiahkandclblb/`
    /// - urlFragment: 解锁路由片段，如 `#/lock`（排除加/改条目路由）
    func detect(origin: String, urlFragment: String) -> (field: AXUIElement, container: AXUIElement, browserBundle: String)? {
        for (bundle, teamID) in Self.browsers {
            // 同一 bundle id 可能有多个进程实例；逐个校验签名（冒充进程排前面时真浏览器不漏检）。
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) {
                guard InjectionWhitelist.processSatisfies(pid: app.processIdentifier, bundleID: bundle,
                                                          signing: .developerID(teamID: teamID)) else { continue }
                // 浏览器弹出系统授权框时 UI 线程同步阻塞、AX 不回话，先探测再遍历（见 AXAppProbe）。
                guard let appEl = AXAppProbe.responsiveApplication(pid: app.processIdentifier, tag: "ext-scan \(bundle)") else { continue }
                if let hit = soleSecureFieldInWebArea(appEl, origin: origin, urlFragment: urlFragment) {
                    return (hit.field, hit.web, bundle)
                }
            }
        }
        return nil
    }

    // MARK: - 扫描

    private func isUnlockURL(_ url: String, origin: String, urlFragment: String) -> Bool {
        url.hasPrefix(origin) && url.contains(urlFragment)
    }

    /// 在浏览器 AX 树里找 URL 属于给定扩展来源的 WebArea，且其内恰好一个 secure field。
    private func soleSecureFieldInWebArea(_ root: AXUIElement, origin: String, urlFragment: String) -> (field: AXUIElement, web: AXUIElement)? {
        var budget = 40000
        let deadline = CFAbsoluteTimeGetCurrent() + AXAppProbe.scanTimeBudget
        var timedOut = false
        var result: (AXUIElement, AXUIElement)?
        func walk(_ el: AXUIElement) {
            if budget <= 0 || timedOut || result != nil { return }
            if CFAbsoluteTimeGetCurrent() > deadline { timedOut = true; return }
            budget -= 1
            let node = AXNode.snapshot(el)
            if node.role == "AXWebArea" {
                if let u = url(of: el), isUnlockURL(u, origin: origin, urlFragment: urlFragment) {
                    let fields = secureFields(in: el, limit: 2, deadline: deadline)
                    // 子扫描超时时 fields 可能不完整，「恰好一个」不成立 → 整体判未命中。
                    if CFAbsoluteTimeGetCurrent() > deadline { timedOut = true; return }
                    if fields.count == 1 { result = (fields[0], el) }
                }
                // 命中/否决这个 WebArea 后都不再下钻：扩展 popup 是独立的顶层 WebArea，
                // 不会嵌在普通网页里；下钻普通网页会把整页内容（可能上万节点）逐个 IPC 一遍，
                // 期间浏览器主线程停止处理用户的键盘输入。
                return
            }
            for c in node.children { walk(c) }
        }
        walk(root)
        if timedOut {
            let msg = "[ax] ext-scan exceeded \(Int(AXAppProbe.scanTimeBudget * 1000))ms budget → skip"
            Task { @MainActor in LogManager.shared.log(msg) }
            return nil
        }
        return result
    }

    /// 超时时返回的结果可能不完整；调用方只在「恰好一个」时命中，并在超时后整体判未命中。
    private func secureFields(in web: AXUIElement, limit: Int, deadline: CFAbsoluteTime) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var budget = 8000
        func rec(_ el: AXUIElement) {
            if budget <= 0 || out.count >= limit || CFAbsoluteTimeGetCurrent() > deadline { return }
            budget -= 1
            let node = AXNode.snapshot(el)
            if node.subrole == (kAXSecureTextFieldSubrole as String) || node.role == "AXSecureTextField" {
                out.append(el)
                return
            }
            for c in node.children { rec(c) }
        }
        rec(web)
        return out
    }

    // MARK: - AX 读取

    private func url(of el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXURL" as CFString, &v) == .success else { return nil }
        if let u = v as? URL { return u.absoluteString }
        if let s = v as? String { return s }
        return nil
    }
}
