/*
 * SSHConfigManager.swift - ~/.ssh/config 里的 immurok 受管块
 *
 * 为什么需要：`launchctl setenv SSH_AUTH_SOCK` 到不了所有终端。Dock 在登录时先于
 * 登录项启动，自身环境里是系统 ssh-agent 的 socket，并把整套环境转发给它启动的
 * App；`open` 也会转发调用方 shell 的环境。`IdentityAgent` 不依赖环境变量，任何
 * 方式启动的终端都生效。
 *
 * 受管块的文本与 Linux 端（app-linux-rs/crates/immurok-common/src/ssh_config.rs）
 * 逐字节一致，但位置不同：这里放在文件末尾。ssh config 对每个选项取先读到的值，
 * 放末尾就压不掉用户任何显式配置（包括只写在某个 Host 段下的 IdentityAgent），
 * 只给「没人管」的主机兜底。Linux 端和本 App 的早期构建放在顶部，删除时两种都认。
 *
 * 这个文件是用户的：受管块以外一个字节都不改；只在用户点击后写入。
 */

import Foundation

enum SSHConfigManager {

    static let beginMarker = "# >>> immurok managed — do not edit (toggle in immurok app) >>>"
    static let endMarker = "# <<< immurok managed <<<"

    static var defaultHome: URL { FileManager.default.homeDirectoryForCurrentUser }

    // MARK: - 纯字符串变换

    /// 受管块全文，以换行结尾。路径含空白时加双引号（ssh_config 的参数引用规则）。
    static func managedBlock(agentSock: String) -> String {
        let needsQuotes = agentSock.contains { $0 == " " || $0 == "\t" }
        let path = needsQuotes ? "\"\(agentSock)\"" : agentSock
        return "\(beginMarker)\nHost *\n    IdentityAgent \(path)\n\(endMarker)\n"
    }

    /// 去掉受管块，连同 `insertingManagedBlock` 加的那一个分隔换行；其余内容按原字节
    /// 保留。没有成对的 BEGIN…END 时原样返回——残缺块不做破坏性修复。
    ///
    /// 分隔换行在哪，取决于块的位置：
    /// - 块在文件末尾（我们写的）：分隔在块前。前一行是空行 → 删掉这个空行；
    ///   前一行有内容 → 说明原文件不以换行结尾，删掉我们补的那个行尾。
    /// - 块后面还有内容（Linux / 早期构建的顶部块，或用户在后面追加了东西）：
    ///   分隔在块后，删掉紧随其后的一个空行。
    ///
    /// 按字节处理：Swift 的 Character 把 "\r\n" 视为一个字素，按字符切行会切错。
    static func strippingManagedBlock(_ content: String) -> String {
        let bytes = Array(content.utf8)
        var lines: [Range<Int>] = []          // 每行含自己的行尾 \n
        var start = 0
        for (i, byte) in bytes.enumerated() where byte == 0x0A {
            lines.append(start..<(i + 1))
            start = i + 1
        }
        if start < bytes.count { lines.append(start..<bytes.count) }

        func trimmed(_ range: Range<Int>) -> String {
            String(decoding: bytes[range], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // END 与它前面最近的 BEGIN 配对。若取「第一个 BEGIN + 其后第一个 END」，
        // 一个残缺的 BEGIN 排在完整块之前时，两者之间的用户内容会被一并删掉。
        var begin: Int?
        var end: Int?
        for (index, range) in lines.enumerated() {
            let text = trimmed(range)
            if text == beginMarker {
                begin = index
            } else if text == endMarker, begin != nil {
                end = index
                break
            }
        }
        guard let begin, let end else { return content }

        var cutStart = lines[begin].lowerBound
        var cutEnd = lines[end].upperBound
        if end + 1 < lines.count {
            if trimmed(lines[end + 1]).isEmpty { cutEnd = lines[end + 1].upperBound }
        } else if begin > 0 {
            let previous = lines[begin - 1]
            let previousBytes = Array(bytes[previous])
            if previousBytes == [0x0A] || previousBytes == [0x0D, 0x0A] {
                cutStart = previous.lowerBound
            } else if previousBytes.suffix(2) == [0x0D, 0x0A] {
                cutStart -= 2
            } else {
                cutStart -= 1
            }
        }
        let kept = bytes[..<cutStart] + bytes[cutEnd...]
        return String(decoding: kept, as: UTF8.self)
    }

    /// 把受管块放到末尾；已有受管块（哪怕路径不同、哪怕在顶部）先去掉再放，所以幂等。
    ///
    /// 只加一个换行：原内容以换行结尾时它成为分隔空行，否则它补上最后一行的行尾、
    /// 块紧贴其后。两种形态不同，`strippingManagedBlock` 才能把结尾还原得一字节不差。
    static func insertingManagedBlock(into content: String, agentSock: String) -> String {
        let body = strippingManagedBlock(content)
        let block = managedBlock(agentSock: agentSock)
        return body.isEmpty ? block : body + "\n" + block
    }

    // MARK: - ssh 的实际解析结果

    /// 从 `ssh -G <host>` 的输出里取 identityagent 的值；没有该行返回 nil。
    static func identityAgent(fromSSHGOutput output: String) -> String? {
        let key = "identityagent "
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.lowercased().hasPrefix(key) {
                return String(text.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// `value`（ssh 解析出的 identityagent）是否就是我们的 agent socket。
    /// `SSH_AUTH_SOCK`、`none`、环境变量引用等非路径取值一律不算。
    static func pointsToAgent(_ value: String?, agentSock: String, home: URL) -> Bool {
        guard var path = value?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return false }
        if path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") {
            path = String(path.dropFirst().dropLast())
        }
        if path == "~" {
            path = home.path
        } else if path.hasPrefix("~/") {
            path = home.path + String(path.dropFirst(1))
        }
        guard path.hasPrefix("/") else { return false }

        func canonical(_ p: String) -> String {
            URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path
        }
        return canonical(path) == canonical(agentSock)
    }

    /// 跑 `/usr/bin/ssh -G immurok-probe.invalid`，返回其输出；失败或超时返回 nil。
    /// 用 ssh 自己来解析，`Include` / `Match` / 用户手写的 `IdentityAgent` 才都算数。
    /// `configFile` 仅供测试指定配置文件。
    static func runSSHG(configFile: URL? = nil, timeout: TimeInterval = 2) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var arguments = ["-G"]
        if let configFile { arguments += ["-F", configFile.path] }
        arguments.append("immurok-probe.invalid")
        process.arguments = arguments

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        // `ssh -G` 的输出只有几 KB，小于管道缓冲区，退出后再读不会卡住。
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    /// ssh 现在把签名请求交给谁。
    enum Routing: Equatable {
        /// 我们的 agent——已生效，无需提示。
        case immurok
        /// 没配 IdentityAgent：跟着环境变量走，于是取决于终端是谁启动的。
        /// 这是唯一该提示「写入 ssh 配置」的状态。
        case unset
        /// 用户明确写了别的取值：别的 agent（如 1Password）、`none`、或显式的
        /// `SSH_AUTH_SOCK`。这是他们的选择，不提示；受管块在末尾，本来也压不过它。
        case otherAgent
    }

    /// 问不了 ssh（失败/超时）时退回到「受管块是否存在」。
    static func routing(agentSock: String,
                        home: URL = defaultHome,
                        sshGOutput: () -> String? = { runSSHG() }) -> Routing {
        guard let output = sshGOutput() else {
            return hasManagedBlock(home: home) ? .immurok : .unset
        }
        // 没配时 `ssh -G` 不输出 identityagent 行；显式写 `SSH_AUTH_SOCK` 则会原样输出。
        guard let value = identityAgent(fromSSHGOutput: output) else { return .unset }
        return pointsToAgent(value, agentSock: agentSock, home: home) ? .immurok : .otherAgent
    }

    // MARK: - 写盘

    /// 把受管块写到 `~/.ssh/config` 末尾。只应在用户明确点击后调用。
    static func install(agentSock: String, home: URL = defaultHome) throws {
        let fm = FileManager.default
        let sshDir = home.appendingPathComponent(".ssh")
        if !fm.fileExists(atPath: sshDir.path) {
            try fm.createDirectory(at: sshDir, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDir.path)
        }

        let target = try resolvingSymlinks(configURL(home: home))
        let existing = try read(target)
        let updated = insertingManagedBlock(into: existing ?? "", agentSock: agentSock)
        guard updated != existing else { return }
        try write(updated, to: target, mode: existingMode(target) ?? 0o600)
    }

    /// 删除受管块。文件或受管块不存在时什么都不做。
    static func remove(home: URL = defaultHome) throws {
        let target = try resolvingSymlinks(configURL(home: home))
        guard let existing = try read(target) else { return }
        let stripped = strippingManagedBlock(existing)
        guard stripped != existing else { return }
        try write(stripped, to: target, mode: existingMode(target) ?? 0o600)
    }

    static func hasManagedBlock(home: URL = defaultHome) -> Bool {
        guard let target = try? resolvingSymlinks(configURL(home: home)),
              let existing = (try? read(target)) ?? nil
        else { return false }
        return strippingManagedBlock(existing) != existing
    }

    // MARK: - Private

    private static func configURL(home: URL) -> URL {
        home.appendingPathComponent(".ssh").appendingPathComponent("config")
    }

    /// 沿软链接走到真实文件（目标可以还不存在）。dotfile 管理工具常把
    /// `~/.ssh/config` 做成软链接；原子替换必须落在目标上，否则会把链接换成普通文件。
    private static func resolvingSymlinks(_ url: URL) throws -> URL {
        var current = url
        for _ in 0..<32 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else {
                return current
            }
            current = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : current.deletingLastPathComponent().appendingPathComponent(destination)
        }
        throw POSIXError(.ELOOP)
    }

    /// 读取文件。不存在返回 nil；读不了或不是 UTF-8 则抛错——
    /// 绝不能把读失败当成空文件，否则随后的写入会抹掉用户的配置。
    private static func read(_ target: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        return try String(contentsOf: target, encoding: .utf8)
    }

    private static func existingMode(_ target: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }

    /// 同目录临时文件 + rename，保证要么是旧内容要么是新内容。
    private static func write(_ content: String, to target: URL, mode: Int) throws {
        let fm = FileManager.default
        let temp = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).immurok-tmp")
        try? fm.removeItem(at: temp)
        do {
            try Data(content.utf8).write(to: temp)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: temp.path)
            guard rename(temp.path, target.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}
