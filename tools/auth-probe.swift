// auth-probe.swift — 认证窗口探测诊断工具(一次性,不入产品)
//
// 目的:当 App Store 购买框 / Passwords 解锁窗弹出时,把
//   1) CGWindowList 里所有在屏窗口的 owner/pid/layer/bounds
//   2) 相关进程的完整 AX 树(role/subrole/title/value/desc)
//   3) (可选 --ocr)对该窗口截图做 Vision OCR
// 全部 dump 出来,用来判定这两个场景该走 AX 路线还是 OCR 路线。
//
// 运行:
//   swift app-macos/tools/auth-probe.swift          # 只用 AX,只需辅助功能权限
//   swift app-macos/tools/auth-probe.swift --ocr     # 额外做 OCR,需屏幕录制权限
//   swift app-macos/tools/auth-probe.swift --all      # 立刻快照当前全部窗口后退出
//
// 玩法:启动后切到 App Store 点“购买”/打开 Passwords 触发解锁,新窗口会自动 dump;
//       也可随时按 RETURN 立刻快照当前所有窗口。Ctrl-C 退出。

import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import Vision
import ScreenCaptureKit

let ocrEnabled = CommandLine.arguments.contains("--ocr")
let dumpAllOnce = CommandLine.arguments.contains("--all")

let printLock = NSLock()
func out(_ s: String) { printLock.lock(); print(s); fflush(stdout); printLock.unlock() }

func ts() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date())
}
func trunc(_ s: String, _ n: Int = 120) -> String {
    s.count <= n ? s : String(s.prefix(n)) + "…"
}

// ───────────────────────── 权限检查 ─────────────────────────
// 关键:CLI 从终端启动时,TCC 把辅助功能/屏幕录制权限归到“终端 App”身上,
// 不是这个脚本。所以只需给终端授权一次,之后改代码重跑都不必再授权。
if !AXIsProcessTrusted() {
    out("⚠️  没有辅助功能(Accessibility)权限,无法读取其它 App 的 AX 树。")
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
    out("""
        请到 系统设置 ▸ 隐私与安全性 ▸ 辅助功能,勾选你运行本程序的那个终端
        (Terminal / iTerm / Warp / VS Code …),然后重新运行本程序。
        权限挂在“终端”上而非脚本,所以只授权一次即可,重编重跑无需再授权。
        """)
    exit(1)
}

// ───────────────────────── AX 读取工具 ─────────────────────────
func axStr(_ el: AXUIElement, _ attr: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    if let b = v as? Bool { return b ? "true" : "false" }
    return nil
}
func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success,
          let arr = v as? [AXUIElement] else { return [] }
    return arr
}

var nodeBudget = 0
func dumpAX(_ el: AXUIElement, depth: Int, maxDepth: Int) {
    if depth > maxDepth || nodeBudget > 600 { return }
    nodeBudget += 1
    let role = axStr(el, kAXRoleAttribute as String) ?? "?"
    var parts = ["role=\(role)"]
    if let s = axStr(el, kAXSubroleAttribute as String) { parts.append("subrole=\(s)") }
    if let t = axStr(el, kAXTitleAttribute as String), !t.isEmpty { parts.append("title=\"\(trunc(t))\"") }
    if let v = axStr(el, kAXValueAttribute as String), !v.isEmpty { parts.append("value=\"\(trunc(v))\"") }
    if let d = axStr(el, kAXDescriptionAttribute as String), !d.isEmpty { parts.append("desc=\"\(trunc(d))\"") }
    if let rd = axStr(el, kAXRoleDescriptionAttribute as String), !rd.isEmpty { parts.append("roleDesc=\"\(trunc(rd))\"") }
    out(String(repeating: "  ", count: depth) + parts.joined(separator: " "))
    for c in axChildren(el) { dumpAX(c, depth: depth + 1, maxDepth: maxDepth) }
}

func dumpAppTree(pid: pid_t, owner: String) {
    nodeBudget = 0
    let app = AXUIElementCreateApplication(pid)
    let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?"
    out("──── AX 树: \(owner)  pid=\(pid)  bundle=\(bid) ────")
    var v: CFTypeRef?
    let st = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v)
    if st != .success {
        out("  ⚠️ 读 kAXWindows 失败 (AXError=\(st.rawValue)) — 该进程 AX 不可见或受限")
        return
    }
    let wins = (v as? [AXUIElement]) ?? []
    if wins.isEmpty {
        out("  (无 AX 窗口 — 很可能是安全强化 UI,AX 树对第三方为空 → 需走 OCR)")
        return
    }
    for (i, w) in wins.enumerated() {
        out("  ┌ window[\(i)]")
        dumpAX(w, depth: 2, maxDepth: 14)
    }
}

func dumpFocused() {
    let sys = AXUIElementCreateSystemWide()
    var f: CFTypeRef?
    guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &f) == .success,
          let el = f, CFGetTypeID(el) == AXUIElementGetTypeID() else {
        out("focused element: (读取失败或无)"); return
    }
    let e = el as! AXUIElement
    let role = axStr(e, kAXRoleAttribute as String) ?? "?"
    let sub = axStr(e, kAXSubroleAttribute as String) ?? "-"
    let hint = (sub == "AXSecureTextField") ? "  ← 焦点在安全密码框,可直接 HID 输入" : ""
    out("focused element: role=\(role) subrole=\(sub)\(hint)")
}

// ───────────────────────── 窗口枚举 ─────────────────────────
func windows() -> [[String: Any]] {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    return (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? []
}
func winNum(_ w: [String: Any]) -> Int { (w[kCGWindowNumber as String] as? NSNumber)?.intValue ?? -1 }
func winPid(_ w: [String: Any]) -> pid_t { (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1 }
func winOwner(_ w: [String: Any]) -> String { w[kCGWindowOwnerName as String] as? String ?? "?" }
func winRect(_ w: [String: Any]) -> CGRect {
    guard let d = w[kCGWindowBounds as String] else { return .zero }
    return CGRect(dictionaryRepresentation: d as! CFDictionary) ?? .zero
}
func describe(_ w: [String: Any]) -> String {
    let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
    let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
    let name = w[kCGWindowName as String] as? String ?? ""
    let r = winRect(w)
    return "owner=\"\(winOwner(w))\" pid=\(winPid(w)) win#\(winNum(w)) layer=\(layer) alpha=\(alpha) "
         + "name=\"\(name)\" rect=(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
}

// 过滤明显无关的窗口(壁纸/阴影/极小提示等),减少噪声
func interesting(_ w: [String: Any]) -> Bool {
    let owner = winOwner(w)
    if ["Window Server", "Dock", "Wallpaper", "Spotlight"].contains(owner) { return false }
    if let a = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, a <= 0.01 { return false }
    let r = winRect(w)
    if r.width * r.height < 3000 { return false }
    return true
}

// ───────────────────────── OCR ─────────────────────────
// ScreenCaptureKit 单窗口截图(CGWindowListCreateImage 已在 macOS 15 移除)。
// SCShareableContent.current 在无屏幕录制权限时返回空/受限 → 正好印证权限缺失。
@available(macOS 14.0, *)
func captureWindowImage(windowID: CGWindowID) -> CGImage? {
    let sem = DispatchSemaphore(value: 0)
    var result: CGImage?
    Task {
        defer { sem.signal() }
        do {
            let content = try await SCShareableContent.current
            guard let scWin = content.windows.first(where: { $0.windowID == windowID }) else {
                out("  OCR: 在可共享内容里找不到该窗口(可能缺屏幕录制权限或窗口已关)")
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: scWin)
            let cfg = SCStreamConfiguration()
            cfg.width = Int(scWin.frame.width * 2)
            cfg.height = Int(scWin.frame.height * 2)
            cfg.showsCursor = false
            result = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        } catch {
            out("  OCR: 截图失败: \(error)")
        }
    }
    sem.wait()
    return result
}

func ocr(_ w: [String: Any]) {
    guard #available(macOS 14.0, *) else { out("  OCR: 需要 macOS 14+"); return }
    guard let img = captureWindowImage(windowID: CGWindowID(winNum(w))) else {
        return
    }
    let handler = VNImageRequestHandler(cgImage: img, options: [:])
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.recognitionLanguages = ["en-US", "zh-Hans"]
    req.usesLanguageCorrection = true
    do {
        try handler.perform([req])
        let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        out("  OCR (\(lines.count) 行):")
        for l in lines { out("    · \(l)") }
        if lines.isEmpty {
            out("    (识别为空 — 若窗口肉眼可见却识别不到,通常是屏幕录制权限缺失导致截图全黑)")
        }
    } catch {
        out("  OCR 失败: \(error)")
    }
}

// ───────────────────────── 汇报一个窗口 ─────────────────────────
func report(_ w: [String: Any], reason: String) {
    out("\n================ \(reason) @ \(ts()) ================")
    out("WINDOW  " + describe(w))
    dumpFocused()
    let pid = winPid(w)
    if pid > 0 { dumpAppTree(pid: pid, owner: winOwner(w)) }
    if ocrEnabled { ocr(w) }
    out("================ end ================\n")
}

// ───────────────────────── 主流程 ─────────────────────────
out("auth-probe 启动。OCR=\(ocrEnabled)。辅助功能=OK。")

if dumpAllOnce {
    out("一次性快照当前全部窗口:")
    for w in windows() where interesting(w) { report(w, reason: "SNAPSHOT-ALL") }
    exit(0)
}

out("玩法:切到 App Store 点“购买”/打开 Passwords 触发解锁 → 新窗口自动 dump。")
out("     或随时按 RETURN 立刻快照当前所有窗口。Ctrl-C 退出。\n")

// 后台线程:按 RETURN 立刻全量快照(应对“窗口已经在屏上”的情况)
Thread.detachNewThread {
    while readLine() != nil {
        let ws = windows()
        out("\n>>> 手动快照:当前 \(ws.count) 个在屏窗口 —")
        for w in ws { out("    " + describe(w)) }
        out(">>> 逐个 dump 有意义的窗口:")
        for w in ws where interesting(w) { report(w, reason: "MANUAL") }
    }
}

// 主线程:轮询检测“新出现的窗口”
var baseline = Set(windows().map(winNum))
while true {
    let cur = windows()
    for w in cur where !baseline.contains(winNum(w)) && interesting(w) {
        report(w, reason: "NEW WINDOW")
    }
    baseline = Set(cur.map(winNum))
    Thread.sleep(forTimeInterval: 0.6)
}
