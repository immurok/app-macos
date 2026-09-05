/*
 * PamKeyCommand.swift - `imk pam-key install|remove|status`
 *
 * 把 App 钥匙串里的 pam_key 复制到 root 目录 /etc/immurok/pam/，供 pam_immurok
 * 校验 App 回复的 HMAC。spec: docs/superpowers/specs/2026-09-03-pam-channel-mac-design.md
 */

import Foundation
import CommonCrypto

enum PamKeyPaths {
    static let dir = "/etc/immurok/pam"
    static func key(uid: uid_t) -> String { "\(dir)/\(uid).key" }
    static func keyId(uid: uid_t) -> String { "\(dir)/\(uid).keyid" }
}

func cmdPamKey(_ args: [String]) -> Int32 {
    guard let sub = args.first else {
        stderr("Usage: imk pam-key <install|remove|status> [--user UID]")
        return 1
    }
    let rest = Array(args.dropFirst())
    let uid = resolveTargetUid(args: rest)
    switch sub {
    case "install": return pamKeyInstall(uid: uid, allowUnsigned: rest.contains("--allow-unsigned-app"))
    case "remove":  return pamKeyRemove(uid: uid)
    case "status":  return pamKeyStatus(uid: uid)
    case "verify-peer": return pamKeyVerifyPeer(args: rest, uid: uid)
    default:
        stderr("Unknown pam-key subcommand: \(sub)")
        return 1
    }
}

/// 目标用户：--user UID > $SUDO_UID > 当前 uid。
private func resolveTargetUid(args: [String]) -> uid_t {
    if let i = args.firstIndex(of: "--user"), i + 1 < args.count, let u = UInt32(args[i + 1]) {
        return uid_t(u)
    }
    if let s = ProcessInfo.processInfo.environment["SUDO_UID"], let u = UInt32(s) {
        return uid_t(u)
    }
    return getuid()
}

private func socketPath(forUid uid: uid_t) -> String? {
    guard let pw = getpwuid(uid), let dir = pw.pointee.pw_dir else { return nil }
    return String(cString: dir) + "/.immurok/cli.sock"
}

private func hexToData(_ s: String) -> Data? {
    guard s.count % 2 == 0 else { return nil }
    var d = Data(); var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
        d.append(b); i = j
    }
    return d
}

private func keyId(of key: Data) -> String {
    // 与 App 的 ImmurokSecurity.pamKeyId 相同：SHA256(key)[0:8]
    var ctx = [UInt8](repeating: 0, count: 32)
    key.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(key.count), &ctx) }
    return ctx.prefix(8).map { String(format: "%02x", $0) }.joined()
}

private func pamKeyInstall(uid: uid_t, allowUnsigned: Bool) -> Int32 {
    guard geteuid() == 0 else {
        stderr("imk pam-key install must run as root (sudo imk pam-key install)")
        return 1
    }
    // 兜底：即使后面写文件的路径都显式给了 mode，也别让继承来的宽松 umask
    // 影响任何一个中间产物（.keyid 走 String.write，那条路径由 umask 决定初值）。
    umask(0o077)
    guard let sock = socketPath(forUid: uid) else {
        stderr("Cannot resolve home directory for uid \(uid)")
        return 1
    }
    let resp: String
    do {
        if allowUnsigned {
            // 开发逃生口：本机跑未签名的 swift build 产物时用。生产路径（设置页的
            // osascript 命令）不传这个开关。
            stderr("WARNING: --allow-unsigned-app given — skipping immurok.app code signature check on \(sock)")
            resp = try CLIClient.send("PAM_KEY", socketPath: sock)
        } else {
            resp = try CLIClient.sendVerified("PAM_KEY", socketPath: sock,
                                              requirement: immurokAppRequirement)
        }
    } catch {
        stderr("Error: \(error)")
        if case CLIError.connectionFailed(let msg) = error, msg.hasPrefix("peer is not immurok.app") {
            stderr("\(sock) 的对端不是已签名的 immurok.app，socket 可能被别的进程占用。")
            stderr("请退出并重新打开 immurok.app 后重试；确认要对未签名的开发版安装，加 --allow-unsigned-app。")
        }
        return 1
    }
    if let e = CLIClient.checkError(resp) { stderr("Error: \(e)"); return 1 }
    guard resp.hasPrefix("OK:"), let key = hexToData(String(resp.dropFirst(3))), key.count == 32 else {
        stderr("Unexpected response from immurok.app")
        return 1
    }

    let fm = FileManager.default
    do {
        try fm.createDirectory(atPath: PamKeyPaths.dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o755, .ownerAccountID: 0])
        // 临时文件必须用 POSIX open(O_CREAT|O_EXCL, 0600) 建：
        // FileManager.createFile(atPath:contents:attributes:) 实际是「按 umask 建文件
        // → 写内容 → 再 setAttributes 收紧」，中间存在一个真实可采样到的 -rw-r--r--
        // 窗口。目录是 0755、文件名可预测，同用户进程紧循环 open 就能在这一瞬读走
        // 32 字节密钥。open 带 mode 0600 让文件从诞生起就只有 root 可读。
        let tmpKey = PamKeyPaths.key(uid: uid) + ".tmp"
        unlink(tmpKey)   // 清掉上次失败留下的残留，让 O_EXCL 不至于误报
        let fd = tmpKey.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else {
            stderr("Failed to create \(tmpKey): \(String(cString: strerror(errno)))")
            return 1
        }
        let written = key.withUnsafeBytes { buf -> Int in
            write(fd, buf.baseAddress, buf.count)
        }
        guard written == key.count else {
            close(fd)
            unlink(tmpKey)
            stderr("Failed to write \(tmpKey): short write (\(written)/\(key.count))")
            return 1
        }
        guard fchown(fd, 0, 0) == 0 else {
            close(fd)
            unlink(tmpKey)
            stderr("Failed to chown \(tmpKey): \(String(cString: strerror(errno)))")
            return 1
        }
        close(fd)
        guard rename(tmpKey, PamKeyPaths.key(uid: uid)) == 0 else {
            let e = String(cString: strerror(errno))
            unlink(tmpKey)
            stderr("Failed to install \(PamKeyPaths.key(uid: uid)): \(e)")
            return 1
        }

        let idPath = PamKeyPaths.keyId(uid: uid)
        try (keyId(of: key) + "\n").write(toFile: idPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: idPath)
    } catch {
        stderr("Failed to write \(PamKeyPaths.dir): \(error)")
        return 1
    }
    print("pam_key installed for uid \(uid): \(PamKeyPaths.key(uid: uid))")
    return 0
}

private func pamKeyRemove(uid: uid_t) -> Int32 {
    guard geteuid() == 0 else {
        stderr("imk pam-key remove must run as root (sudo imk pam-key remove)")
        return 1
    }
    let fm = FileManager.default
    for p in [PamKeyPaths.key(uid: uid), PamKeyPaths.keyId(uid: uid)] where fm.fileExists(atPath: p) {
        do { try fm.removeItem(atPath: p) } catch {
            stderr("Failed to remove \(p): \(error)")
            return 1
        }
    }
    print("pam_key removed for uid \(uid) (PAM back to compat mode)")
    return 0
}

/// 0=已启用且一致，2=未安装，3=失配（root 那份和钥匙串里的不是同一把，或钥匙串
/// 里根本没有），4=App 连不上/回复异常，没法比较。
private func pamKeyStatus(uid: uid_t) -> Int32 {
    let idPath = PamKeyPaths.keyId(uid: uid)
    guard let installed = try? String(contentsOfFile: idPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !installed.isEmpty else {
        print("not installed")
        return 2
    }
    guard let sock = socketPath(forUid: uid) else {
        print("installed (\(installed)); app not reachable, cannot compare")
        return 4
    }
    guard let resp = try? CLIClient.send("PAM_KEY_ID", socketPath: sock) else {
        print("installed (\(installed)); app not reachable, cannot compare")
        return 4
    }
    if resp.hasPrefix("ERROR:NO_KEY") {
        // App 的钥匙串里根本没有 pam_key（比如从没触发过 loadOrCreatePamKey）。
        // 跟"版本不一致"是同一类问题——root 那份认证材料对不上 App 现在的
        // 状态——所以也算 MISMATCH，退出码 3，而不是"连不上"的 4。
        print("MISMATCH: installed=\(installed) app=<none> — run: sudo imk pam-key install")
        return 3
    }
    guard resp.hasPrefix("OK:") else {
        print("installed (\(installed)); app not reachable, cannot compare")
        return 4
    }
    let current = String(resp.dropFirst(3))
    if current == installed {
        print("installed and matches app key (\(installed))")
        return 0
    }
    print("MISMATCH: installed=\(installed) app=\(current) — run: sudo imk pam-key install")
    return 3
}

/// 隐藏子命令：`imk pam-key verify-peer [--socket PATH]`。只做对端签名校验并打印结果，
/// 不发任何命令、不写任何文件——F2 的可验证入口（对假服务端应失败，对真 App 应通过）。
private func pamKeyVerifyPeer(args: [String], uid: uid_t) -> Int32 {
    var path: String? = nil
    if let i = args.firstIndex(of: "--socket"), i + 1 < args.count {
        path = args[i + 1]
    }
    guard let sock = path ?? socketPath(forUid: uid) else {
        stderr("Cannot resolve socket path for uid \(uid)")
        return 1
    }
    let fd: Int32
    do { fd = try CLIClient.connectSocket(sock) } catch {
        stderr("Error: \(error)")
        return 1
    }
    defer { close(fd) }
    do {
        try verifyPeer(fd: fd, requirement: immurokAppRequirement)
    } catch {
        print("verify-peer: FAIL \(sock)")
        print("  \(error)")
        return 1
    }
    print("verify-peer: OK \(sock) — peer satisfies immurok.app designated requirement")
    return 0
}
