import CoreGraphics

/// 一个候选按钮的最小可判定信息（AX subrole + 标题 + 屏幕 frame）。
public struct ButtonInfo {
    public let subrole: String?
    public let title: String?
    public let frame: CGRect
    public init(subrole: String?, title: String? = nil, frame: CGRect) {
        self.subrole = subrole
        self.title = title
        self.frame = frame
    }
}

/// 语言无关地在一组按钮里选"主操作按钮"（Install / Sign In / Unlock）。
///
/// 排除规则（任一命中即淘汰）：
/// - 结构化 subrole：AXCancelButton + 窗口标题栏控制件（红绿灯 / 工具栏）。
///   排除红绿灯至关重要——Passwords 解锁窗口没有提交按钮，若不排除会误选最右的
///   绿色缩放键（AXZoomButton/AXFullScreenButton）把窗口切成全屏。
/// - 标题为"取消"类。**App Store 是 Catalyst 应用，按钮全都 subrole=nil、窗口也不暴露
///   AXCancelButton/AXDefaultButton**，唯一可用信号就是标题；且 Cancel 的 maxX 可能比
///   Sign In 更大（实测 Cancel=800 > Sign In=788），纯几何"取最右"会误按 Cancel 关掉 sheet。
///
/// 选择规则：优先取标题为"确认/登录/购买"类的按钮（多个时取最右）；没有标题命中时，
/// 在剩余候选里取 frame.maxX 最大者（HIG 主按钮惯例在右下）。
public enum MainButtonSelector {
    private static let excludedSubroles: Set<String> = [
        "AXCancelButton",
        "AXCloseButton",
        "AXMinimizeButton",
        "AXZoomButton",
        "AXFullScreenButton",
        "AXToolbarButton",
    ]

    /// "取消"类整标题（trim + 小写后精确匹配）。覆盖 App 支持语言 + 常见系统语言。
    private static let cancelTitles: Set<String> = [
        "cancel", "取消", "キャンセル", "취소",
        "abbrechen", "annuler", "cancelar", "annulla", "отмена",
    ]

    /// "确认/提交"类标题关键字（小写后子串匹配）。用于在多个非取消按钮中优选主操作，
    /// 把 Sign In 从 Forgot Password 之类的次要按钮里挑出来。
    private static let confirmKeywords: [String] = [
        "sign in", "log in", "use password", "buy", "purchase", "subscribe",
        "install", "update", "unlock", "continue", "confirm", "get",
        "登录", "登入", "购买", "購買", "订阅", "訂閱", "安装", "安裝",
        "更新", "解锁", "解鎖", "继续", "繼續", "确认", "確認", "确定", "確定",
    ]

    private static func normalized(_ title: String?) -> String? {
        title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isCancel(_ title: String?) -> Bool {
        guard let t = normalized(title) else { return false }
        return cancelTitles.contains(t)
    }

    private static func isConfirm(_ title: String?) -> Bool {
        guard let t = normalized(title) else { return false }
        return confirmKeywords.contains { t.contains($0) }
    }

    public static func pick(from buttons: [ButtonInfo]) -> Int? {
        let candidates = buttons.enumerated().filter { el in
            if let subrole = el.element.subrole, excludedSubroles.contains(subrole) { return false }
            if isCancel(el.element.title) { return false }
            return true
        }
        guard !candidates.isEmpty else { return nil }
        // 优先"确认"类标题；都不命中时用全体候选做几何兜底。
        let confirms = candidates.filter { isConfirm($0.element.title) }
        let pool = confirms.isEmpty ? candidates : confirms
        return pool.max { a, b in a.element.frame.maxX < b.element.frame.maxX }?.offset
    }
}
