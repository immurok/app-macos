/// Safari's password AutoFill Touch ID sheet ("Touch ID to AutoFill your login information.").
///
/// AX structure (Safari, captured on device):
///   AXWindow → AXSheet id='AutoFillAuthenticationSheet' → AXGroup sub=AXHostingView →
///     AXImage id='touchid' / AXStaticText ×2 / AXButton desc='Enter Password…' / AXButton desc='Cancel'
///
/// On a fingerprint match we press "Enter Password…"; Safari then swaps in a sheet with a
/// password field, which the existing Passwords injection path (AuthContextDetector Path 1) fills.
public enum AutoFillTouchIDSheet {
    /// The AXIdentifier Safari gives this sheet (locale-independent).
    public static let sheetIdentifier = "AutoFillAuthenticationSheet"

    /// Picks the "enter password" button among the sheet's buttons; returns nil when it can't be
    /// determined unambiguously (better to press nothing than the wrong button).
    /// Rules: exclude Cancel (by subrole or title); if one candidate remains, pick it. If several
    /// remain, accept only a single one ending in "…"/"..." (macOS convention for buttons that open
    /// further UI, consistent across locales).
    public static func pickPasswordButton(from buttons: [ButtonInfo]) -> Int? {
        let candidates = buttons.indices.filter { i in
            buttons[i].subrole != "AXCancelButton" && !MainButtonSelector.isCancel(buttons[i].title)
        }
        if candidates.count == 1 { return candidates[0] }
        let ellipsis = candidates.filter { i in
            let t = buttons[i].title?.trimmingCharacters(in: .whitespaces) ?? ""
            return t.hasSuffix("…") || t.hasSuffix("...")
        }
        return ellipsis.count == 1 ? ellipsis[0] : nil
    }
}
