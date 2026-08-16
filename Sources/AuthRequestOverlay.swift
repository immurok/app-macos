import AppKit
import SwiftUI
import Combine

/// Self-drawn HUD overlay shown when an out-of-app process (sudo, screen unlock,
/// future MCP/agent integrations) requests fingerprint authorization. macOS
/// system notifications need explicit user permission and get suppressed by
/// Do-Not-Disturb / focus modes — neither acceptable for "you must touch the
/// device right now" prompts. So we paint our own.
///
/// The panel floats above all spaces and full-screen apps without stealing
/// focus, so a user typing in a terminal sees the prompt without losing their
/// caret.
@MainActor
final class AuthRequestOverlay {
    static let shared = AuthRequestOverlay()

    private var panel: NSPanel?
    private let state = AuthRequestState()
    private var dismissTimer: Timer?
    /// The app that was frontmost when the overlay appeared (typically the
    /// user's terminal). We re-activate it on dismiss so keystrokes flow back
    /// to it without the user having to click around.
    private weak var prevFrontApp: NSRunningApplication?

    /// Set per `show()` call. Reject = the caller wants the underlying
    /// command (e.g. sudo) to die outright. There is no separate "cancel"
    /// path — timeout is folded into reject so behavior is uniformly
    /// "the user said no".
    var onReject: (() -> Void)?

    /// UserDefaults key + default for the prompt sound. Empty string = silent.
    /// Written by the picker in Settings → 权限 → imk CLI, mirroring
    /// `immurok.unlockSound` / `immurok.lockSound`.
    /// `nonisolated` so the settings UI can name them in a property
    /// initializer without hopping to the main actor.
    nonisolated static let soundDefaultsKey = "immurok.agentAuthSound"
    nonisolated static let defaultSoundName = "Ping"

    private init() {}

    func show(
        user: String,
        service: String,
        command: String? = nil,
        kind: AuthRequestKind = .commandRun,
        timeout: TimeInterval = 30.0,
        onReject: (() -> Void)? = nil
    ) {
        // 连发场景（imk run --agent 每条命令一次请求）：上一条的成功/失败
        // 终态还在 0.6s/1.2s 延迟隐藏中，新请求的 show() 已把面板拉回。
        // 不取消旧定时器的话，它到点会把新请求的等待面板悄悄 hide 掉。
        dismissTimer?.invalidate()
        dismissTimer = nil
        state.user = user
        state.service = service
        state.command = command
        state.kind = kind
        state.timeout = timeout
        state.startedAt = Date()
        state.status = .waiting
        self.onReject = onReject

        prevFrontApp = NSWorkspace.shared.frontmostApplication
        ensurePanel()
        resizePanelForCurrentState()
        positionPanelAtTopCenter()
        panel?.orderFrontRegardless()
        playPromptSound()
    }

    /// Audible cue for the approval prompt. The panel deliberately never
    /// steals focus, so a user looking at another window (or another Space)
    /// can miss it entirely and the request just times out. A short beep is
    /// what makes an agent request noticeable while the terminal is in the
    /// background.
    private func playPromptSound() {
        let name = UserDefaults.standard.string(forKey: Self.soundDefaultsKey)
            ?? Self.defaultSoundName
        guard !name.isEmpty else { return }
        NSSound(named: name)?.play()
    }

    func reportRetry(remaining: Int) {
        state.status = .retrying(remaining: remaining)
    }

    /// True while the overlay panel is on screen (including the brief
    /// success/failure terminal-state delay between `dismiss()` and `hide()`).
    /// Used by AppDelegate.handleLockRequest to suppress long-press lock when
    /// the user is actively authenticating an agent request — the immurok
    /// overlay isn't an OS AXSecureTextField/SecurityAgent, so the AX-based
    /// auth-context probe in handleLockRequest can't see it.
    var isShowing: Bool {
        panel?.isVisible ?? false
    }

    func dismiss(status: AuthRequestState.Status) {
        state.status = status
        // Brief delay so the user sees the success/failure terminal state
        // before the panel slides out.
        dismissTimer?.invalidate()
        let delay: TimeInterval = (status == .approved) ? 0.6 : 1.2
        dismissTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    /// Decide whether a wrapped command looks like a secret read.
    /// Conservative — only matches direct top-level `imk get` / `imk-cli`
    /// invocations. A command like `bash -c 'imk get ...'` or `python
    /// uses-imk-internally.py` falls through to .commandRun; we'd need
    /// inner-call notifications (separate feature) to flag those.
    /// `nonisolated` because callers (PAM socket thread) aren't on the
    /// main actor — pure string parsing, no UI state touched.
    nonisolated static func classify(command: String) -> AuthRequestKind {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        let first = trimmed.split(separator: " ").first.map(String.init) ?? ""
        // Strip any path prefix: /usr/local/bin/imk, ./imk, etc.
        let bin = (first as NSString).lastPathComponent
        guard bin == "imk" else { return .commandRun }
        // The next token determines whether this is a read.
        let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return .commandRun }
        let sub = String(parts[1])
        return (sub == "get") ? .secretAccess : .commandRun
    }

    private func hide() {
        panel?.orderOut(nil)
        // Re-activate whoever was frontmost before we showed the panel — the
        // user's terminal in the AI-agent case. Explicit activate is more
        // reliable than NSApp.deactivate(), which leaves AppKit to pick a
        // successor and sometimes drops a frame's worth of keystrokes.
        if let prev = prevFrontApp, prev.processIdentifier != getpid() {
            prev.activate()
        }
        prevFrontApp = nil
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let initialFrame = NSRect(
            x: 0, y: 0,
            width: AuthRequestPanelMetrics.width,
            height: AuthRequestPanelMetrics.heightCompact
        )
        let hosting = NSHostingView(rootView: AuthRequestView(
            state: state,
            onReject: { [weak self] in self?.onReject?() }
        ))
        hosting.frame = initialFrame
        hosting.autoresizingMask = [.width, .height]

        let p = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.contentView = hosting
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        // Don't steal keyboard focus from the user's terminal. A button click
        // would otherwise route through the panel as key window, leaving the
        // terminal unable to receive keystrokes (visible after Cancel: sudo
        // prompts for password but typing goes nowhere).
        p.becomesKeyOnlyIfNeeded = true
        panel = p
    }

    private func positionPanelAtTopCenter() {
        guard let panel = panel else { return }
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        // 24pt below the menu bar
        let y = visible.maxY - size.height - 24
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Match the panel height to the content. Without a command line we can
    /// stay at the compact height; with a command we grow to fit two lines of
    /// monospace + the detail row.
    private func resizePanelForCurrentState() {
        guard let panel = panel else { return }
        let hasCmd = state.command?.isEmpty == false
        let h: CGFloat = hasCmd ? AuthRequestPanelMetrics.heightWithCommand
                                : AuthRequestPanelMetrics.heightCompact
        var f = panel.frame
        f.size = NSSize(width: AuthRequestPanelMetrics.width, height: h)
        panel.setFrame(f, display: true)
    }
}

enum AuthRequestPanelMetrics {
    static let width: CGFloat = 440
    static let heightCompact: CGFloat = 110
    static let heightWithCommand: CGFloat = 156
}

@MainActor
final class AuthRequestState: ObservableObject {
    enum Status: Equatable {
        case waiting
        case retrying(remaining: Int)
        case approved
        case denied
        case timedOut
    }

    @Published var user: String = ""
    @Published var service: String = ""
    @Published var command: String? = nil
    @Published var kind: AuthRequestKind = .commandRun
    @Published var timeout: TimeInterval = 30
    @Published var startedAt: Date = Date()
    @Published var status: Status = .waiting
}

/// What category of approval the overlay represents. Drives the visual
/// treatment so the user can tell at-a-glance "agent wants to run a
/// command" vs "agent wants to read a secret".
enum AuthRequestKind {
    case commandRun     // generic agent command (sudo, git, npm, ...)
    case secretAccess   // imk get / read of API key / OTP / SSH key
}

private struct AuthRequestView: View {
    @ObservedObject var state: AuthRequestState
    let onReject: () -> Void
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    private var canReject: Bool {
        switch state.status {
        case .waiting, .retrying: return true
        default:                  return false
        }
    }

    private var remainingSeconds: Int {
        max(0, Int(ceil(state.timeout - now.timeIntervalSince(state.startedAt))))
    }

    private var progressFraction: Double {
        let elapsed = now.timeIntervalSince(state.startedAt)
        return max(0, min(1, 1 - elapsed / state.timeout))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Main content. The text column expands vertically so meta-row
            // can stick to the bottom regardless of whether a command pill
            // is shown above it.
            HStack(alignment: .top, spacing: 14) {
                AuthIconView(status: state.status, color: iconColor, symbol: iconSymbol)
                VStack(alignment: .leading, spacing: 0) {
                    headlineBlock
                    if let cmd = state.command, !cmd.isEmpty {
                        CommandPill(text: cmd)
                            .padding(.top, 6)
                    }
                    Spacer(minLength: 6)
                    metaRow
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Top-right close button (= reject)
            if canReject {
                CloseButton(action: onReject)
                    .padding(.top, 8)
                    .padding(.trailing, 8)
            }
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                // Subtle accent tint that hints at status
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(iconColor.opacity(0.05))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(iconColor.opacity(0.32), lineWidth: 0.8)
        )
        .overlay(alignment: .top) {
            // Inner highlight at the top — gives the material a glassy lip
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                .padding(0.5)
                .mask(
                    LinearGradient(
                        colors: [.white, .clear],
                        startPoint: .top, endPoint: .center
                    )
                )
        }
        .onReceive(timer) { now = $0 }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var headlineBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(headlineText)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
            if let sub = subheadlineText {
                Text(sub)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            Text(serviceDisplayName(state.service))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.secondary)
            Circle()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 2.5, height: 2.5)
            Text(state.user)
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if canReject {
                CountdownBar(
                    fraction: progressFraction,
                    remaining: remainingSeconds,
                    accent: progressColor
                )
                .frame(width: 90)
            }
        }
        .padding(.top, 1)
    }

    // MARK: - Status-derived bits

    private var iconSymbol: String {
        switch state.status {
        case .approved:  return "checkmark.circle.fill"
        case .denied:    return "xmark.octagon.fill"
        case .timedOut:  return "clock.badge.xmark.fill"
        default:
            // Distinct icon for secret-read so users don't muscle-memory
            // approve a key access thinking it's a benign command run.
            return state.kind == .secretAccess ? "key.fill" : "touchid"
        }
    }

    private var iconColor: Color {
        switch state.status {
        case .approved:  return .green
        case .denied:    return .red
        case .timedOut:  return .orange
        default:
            // Orange/amber for secret access is a lightweight "watch out"
            // signal. Blue stays for ordinary commands so the eye still
            // notices the swap.
            return state.kind == .secretAccess ? .orange : .blue
        }
    }

    /// Progress bar shifts blue → orange → red as the 30s window drains.
    private var progressColor: Color {
        let f = progressFraction
        if f > 0.5  { return .blue }
        if f > 0.2  { return .orange }
        return .red
    }

    private var headlineText: String {
        switch state.status {
        case .waiting:
            return state.kind == .secretAccess
                ? "auth.overlay.waiting.secret".localized
                : "auth.overlay.waiting".localized
        case .retrying(let r):       return String(format: "auth.overlay.retrying".localized, r)
        case .approved:              return "auth.overlay.approved".localized
        case .denied:                return "auth.overlay.denied".localized
        case .timedOut:              return "auth.overlay.timedout".localized
        }
    }

    private var subheadlineText: String? {
        switch state.status {
        case .waiting, .retrying:
            return state.kind == .secretAccess
                ? "auth.overlay.subtitle.touch.secret".localized
                : "auth.overlay.subtitle.touch".localized
        default: return nil
        }
    }

    private func serviceDisplayName(_ raw: String) -> String {
        switch raw {
        case "sudo":              return "sudo"
        case "screen-unlock":     return "auth.overlay.svc.unlock".localized
        case "auth-gui":          return "auth.overlay.svc.authgui".localized
        case "ssh-agent":         return "SSH Agent"
        case "imk-cli":           return "imk CLI"
        default:                  return raw
        }
    }
}

// MARK: - Subviews

private struct AuthIconView: View {
    let status: AuthRequestState.Status
    let color: Color
    let symbol: String
    @State private var pulse = false

    private var isActive: Bool {
        switch status {
        case .waiting, .retrying: return true
        default:                  return false
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(color)
            .symbolRenderingMode(.hierarchical)
            .frame(width: 38, height: 38)
            .background(
                Circle().fill(
                    LinearGradient(
                        colors: [color.opacity(0.22), color.opacity(0.10)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            )
            .scaleEffect(pulse ? 1.08 : 1.0)
            .animation(
                isActive
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            .onAppear { pulse = true }
    }
}

private struct CommandPill: View {
    let text: String

    /// Hard cap on what we render in the pill. SwiftUI's truncationMode is
    /// unreliable for very long unbroken tokens, so we cap at the source.
    /// The full string is preserved in the .help() tooltip.
    private static let maxDisplayChars = 80

    private var displayText: String {
        guard text.count > Self.maxDisplayChars else { return text }
        let keep = Self.maxDisplayChars - 3   // 3 chars for "..."
        let endIdx = text.index(text.startIndex, offsetBy: keep)
        return String(text[..<endIdx]) + "..."
    }

    /// Highlight `imk://category/name` URIs inline so the user spots a
    /// secret access at a glance — even when nested in a wrapper command
    /// like `bash -c '... imk get imk://api/foo'`.
    private var attributedDisplayText: AttributedString {
        let s = displayText
        var result = AttributedString()
        guard let regex = try? NSRegularExpression(pattern: #"imk://[^\s]+"#) else {
            return AttributedString(s)
        }
        let nsRange = NSRange(s.startIndex..., in: s)
        var lastEnd = s.startIndex
        regex.enumerateMatches(in: s, range: nsRange) { match, _, _ in
            guard let match = match,
                  let range = Range(match.range, in: s) else { return }
            if lastEnd < range.lowerBound {
                result += AttributedString(s[lastEnd..<range.lowerBound])
            }
            var hit = AttributedString(s[range])
            hit.font = .system(size: 11.5, weight: .bold, design: .monospaced)
            hit.foregroundColor = .orange
            result += hit
            lastEnd = range.upperBound
        }
        if lastEnd < s.endIndex {
            result += AttributedString(s[lastEnd..<s.endIndex])
        }
        return result
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("$")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
                .padding(.top, 0.5)
            Text(attributedDisplayText)
                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                .foregroundColor(.primary.opacity(0.92))
                .lineLimit(2)
                .truncationMode(.middle)
                .help(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        )
    }
}

private struct CountdownBar: View {
    let fraction: Double
    let remaining: Int
    let accent: Color

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(accent)
                        .frame(width: max(2, geo.size.width * CGFloat(fraction)))
                        .animation(.linear(duration: 0.25), value: fraction)
                }
            }
            .frame(height: 3)
            Text("\(remaining)s")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .monospacedDigit()
                .frame(width: 24, alignment: .trailing)
        }
    }
}

private struct CloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(hovering
                          ? Color.red.opacity(0.85)
                          : Color.primary.opacity(0.10))
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundColor(hovering ? .white : .secondary)
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("auth.overlay.reject.tooltip".localized)
    }
}

private extension AuthRequestState.Status {
    var isRetrying: Bool {
        if case .retrying = self { return true }
        return false
    }
}
