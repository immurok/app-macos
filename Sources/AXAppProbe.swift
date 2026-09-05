import ApplicationServices
import Foundation

/// 目标进程 AX 响应性探测。
///
/// 被模态对话框同步阻塞的进程对任何 AX 查询都不回话，每次调用要等到系统超时才失败
///（实测 1.5 s/次）。典型例子：Chrome 弹出「填充密码」授权框时 UI 线程卡在
/// AuthorizationCopyRights 里，直到用户关掉对话框。在这种进程的 AX 树上遍历，
/// 每个条目至少撞两次超时，主动指纹路径会被拖住数秒、回车迟迟发不出去。
///
/// 因此所有「创建目标进程 AX 元素然后遍历」的入口都先经这里：用短超时查一次 AXRole，
/// 不响应就返回 nil，调用方跳过该进程（本次触摸退回常规流程，不做注入）。
enum AXAppProbe {
    /// 正常进程回 AXRole 只要 0-5 ms（刚唤醒时几十 ms），0.2 s 余量充足。
    static let probeTimeout: Float = 0.2

    /// 返回可正常响应的应用 AX 元素；不响应返回 nil 并记日志。
    static func responsiveApplication(pid: pid_t, tag: String) -> AXUIElement? {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, probeTimeout)
        var v: CFTypeRef?
        let t0 = CFAbsoluteTimeGetCurrent()
        let err = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v)
        // 探测只对这一个元素用短超时；后续遍历恢复全局默认，避免慢但正常的进程误判。
        AXUIElementSetMessagingTimeout(el, 0)
        guard err == .success else {
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            let msg = "[ax] \(tag) pid=\(pid) unresponsive err=\(err.rawValue) \(ms)ms → skip"
            Task { @MainActor in LogManager.shared.log(msg) }
            return nil
        }
        return el
    }
}
