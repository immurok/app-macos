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
        var result: (AXUIElement, AXUIElement)?
        func walk(_ el: AXUIElement) {
            if budget <= 0 || result != nil { return }
            budget -= 1
            if role(of: el) == "AXWebArea",
               let u = url(of: el),
               isUnlockURL(u, origin: origin, urlFragment: urlFragment) {
                let fields = secureFields(in: el, limit: 2)
                if fields.count == 1 { result = (fields[0], el) }
                return   // 命中/否决这个 WebArea 后不再下钻它
            }
            for c in children(of: el) { walk(c) }
        }
        walk(root)
        return result
    }

    private func secureFields(in web: AXUIElement, limit: Int) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var budget = 8000
        func rec(_ el: AXUIElement) {
            if budget <= 0 || out.count >= limit { return }
            budget -= 1
            if subrole(of: el) == (kAXSecureTextFieldSubrole as String) || role(of: el) == "AXSecureTextField" {
                out.append(el)
                return
            }
            for c in children(of: el) { rec(c) }
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

    private func role(of el: AXUIElement) -> String? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v)
        return v as? String
    }

    private func subrole(of el: AXUIElement) -> String? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &v)
        return v as? String
    }

    private func children(of el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success,
              let kids = v as? [AXUIElement] else { return [] }
        return kids
    }
}
