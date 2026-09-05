/*
 * PeerCodeSignature.swift - 校验 Unix socket 对端的代码签名
 *
 * ~/.immurok/cli.sock 归用户所有，同用户的进程可以把真 socket 改名、自己 bind
 * 一个同名文件，把 LIST/GET 转发给真 App，唯独 PAM_KEY 回自己的密钥。用户点
 * 「启用 sudo 强认证」时 root 就会把攻击者的密钥写进 /etc/immurok/pam/，此后
 * 攻击者伪造的 pam.sock 回复能通过 MAC 校验——整条强认证链被掉包。
 *
 * 所以 `imk pam-key install` 在发 PAM_KEY 之前，必须先确认对端进程是真正的、
 * Developer ID 签名的 immurok.app。
 * spec: docs/superpowers/specs/2026-09-03-pam-channel-mac-design.md
 */

import Darwin
import Foundation
import Security

/// 已部署 immurok.app 的 designated requirement（`codesign -d -r- /Applications/immurok.app`）。
let immurokAppRequirement =
    "identifier \"com.immurok.app\" and anchor apple generic and "
    + "certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and "
    + "certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and "
    + "certificate leaf[subject.OU] = UH43X23J62"

/// 校验已连接 socket 的对端是否满足 requirement。不满足即 throw，调用方不要再发命令。
///
/// 用 LOCAL_PEERTOKEN 取对端的 audit_token_t 而不是 LOCAL_PEERPID：audit token 里
/// 带 pidversion，内核会在 exec 时递增，SecCodeCopyGuestWithAttributes 因此能识破
/// 「拿到 pid 后对端 exec 成别的程序」这类 pid 复用/替换攻击；只有 pid 的话校验的
/// 是「现在这个 pid 上的进程」，和当初连过来的那个未必是同一个。
func verifyPeer(fd: Int32, requirement: String) throws {
    var token = audit_token_t()
    var len = socklen_t(MemoryLayout<audit_token_t>.size)
    let rc = withUnsafeMutablePointer(to: &token) { ptr in
        getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, ptr, &len)
    }
    guard rc == 0, len == socklen_t(MemoryLayout<audit_token_t>.size) else {
        throw peerError("getsockopt(LOCAL_PEERTOKEN) failed: \(String(cString: strerror(errno)))")
    }

    let tokenData = withUnsafeBytes(of: &token) { Data($0) }
    var code: SecCode?
    var status = SecCodeCopyGuestWithAttributes(
        nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code)
    guard status == errSecSuccess, let peerCode = code else {
        throw peerError("SecCodeCopyGuestWithAttributes failed (OSStatus \(status))")
    }

    var req: SecRequirement?
    status = SecRequirementCreateWithString(requirement as CFString, [], &req)
    guard status == errSecSuccess, let requirementRef = req else {
        throw peerError("SecRequirementCreateWithString failed (OSStatus \(status))")
    }

    status = SecCodeCheckValidity(peerCode, [], requirementRef)
    guard status == errSecSuccess else {
        throw peerError("SecCodeCheckValidity failed (OSStatus \(status))")
    }
}

private func peerError(_ detail: String) -> CLIError {
    .connectionFailed("peer is not immurok.app (code signature check failed): \(detail)")
}
