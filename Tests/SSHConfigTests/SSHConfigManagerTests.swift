import XCTest
@testable import immurokApp

/// `~/.ssh/config` 受管块的读写与「是否已生效」判定。
///
/// 背景（2026-11-26 真机）：`launchctl setenv SSH_AUTH_SOCK` 到不了从 Dock 启动的
/// 终端——Dock 登录时先于登录项启动，带的是系统 ssh-agent 的 socket，并把自己的
/// 环境转发给它启动的 App。`IdentityAgent` 不依赖环境变量，所以改为写 ssh config。
/// 这个文件是用户的，受管块以外一个字节都不能动。
final class SSHConfigManagerTests: XCTestCase {

    private var home: URL!
    private let sock = "/Users/tester/.immurok/agent.sock"
    private let userConfig = "Host myserver\n  HostName 1.2.3.4\n  User me\n"

    private var sshDir: URL { home.appendingPathComponent(".ssh") }
    private var configURL: URL { sshDir.appendingPathComponent("config") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("immurok-sshconfig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    private func writeConfig(_ content: String, mode: Int = 0o600) throws {
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: configURL)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: configURL.path)
    }

    private func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // MARK: - 受管块文本

    func testManagedBlockMatchesLinuxByteForByte() {
        XCTAssertEqual(
            SSHConfigManager.managedBlock(agentSock: sock),
            """
            # >>> immurok managed — do not edit (toggle in immurok app) >>>
            Host *
                IdentityAgent /Users/tester/.immurok/agent.sock
            # <<< immurok managed <<<

            """)
    }

    func testPathWithSpaceIsQuoted() {
        let block = SSHConfigManager.managedBlock(agentSock: "/Users/John Doe/.immurok/agent.sock")
        XCTAssertTrue(block.contains("    IdentityAgent \"/Users/John Doe/.immurok/agent.sock\"\n"), block)
    }

    // MARK: - 插入

    func testInsertIntoEmptyProducesOnlyBlock() {
        XCTAssertEqual(SSHConfigManager.insertingManagedBlock(into: "", agentSock: sock),
                       SSHConfigManager.managedBlock(agentSock: sock))
    }

    /// 受管块放在末尾：ssh config 先取到的值生效，放末尾就压不掉用户任何显式配置
    /// （包括写在具体 Host 段下的 IdentityAgent）。
    func testInsertAppendsAfterUserContentWithOneBlankLine() {
        XCTAssertEqual(SSHConfigManager.insertingManagedBlock(into: userConfig, agentSock: sock),
                       userConfig + "\n" + SSHConfigManager.managedBlock(agentSock: sock))
    }

    /// 用户文件不以换行结尾时只补一个换行，受管块紧贴其后（不空行）。
    /// 与上一种形态不同，删除时才能分辨并把结尾还原得一字节不差。
    func testInsertAfterContentWithoutTrailingNewlineAttachesBlockDirectly() {
        let original = "Host myserver\n  User me"
        XCTAssertEqual(SSHConfigManager.insertingManagedBlock(into: original, agentSock: sock),
                       original + "\n" + SSHConfigManager.managedBlock(agentSock: sock))
    }

    /// 旧版本（及 Linux 端）把受管块放在顶部、其后空一行。再次写入时挪到末尾。
    func testInsertMovesLegacyTopBlockToEnd() {
        let legacy = SSHConfigManager.managedBlock(agentSock: "/old/agent.sock") + "\n" + userConfig
        XCTAssertEqual(SSHConfigManager.strippingManagedBlock(legacy), userConfig)
        XCTAssertEqual(SSHConfigManager.insertingManagedBlock(into: legacy, agentSock: sock),
                       userConfig + "\n" + SSHConfigManager.managedBlock(agentSock: sock))
    }

    func testInsertIsIdempotent() {
        let once = SSHConfigManager.insertingManagedBlock(into: userConfig, agentSock: sock)
        let twice = SSHConfigManager.insertingManagedBlock(into: once, agentSock: sock)
        XCTAssertEqual(twice, once)
    }

    func testInsertReplacesBlockWithOldPath() {
        let old = SSHConfigManager.insertingManagedBlock(into: userConfig, agentSock: "/old/agent.sock")
        let result = SSHConfigManager.insertingManagedBlock(into: old, agentSock: sock)
        XCTAssertFalse(result.contains("/old/agent.sock"))
        XCTAssertEqual(result.components(separatedBy: "IdentityAgent").count - 1, 1)
        XCTAssertEqual(result.components(separatedBy: SSHConfigManager.beginMarker).count - 1, 1)
        XCTAssertTrue(result.hasPrefix(userConfig))
    }

    // MARK: - 删除

    func testUnterminatedBlockIsLeftAlone() {
        let broken = "\(SSHConfigManager.beginMarker)\nHost *\n    IdentityAgent /x\n\nHost myserver\n  User me\n"
        XCTAssertEqual(SSHConfigManager.strippingManagedBlock(broken), broken)
    }

    /// 残缺的 BEGIN 后面跟着用户内容，再后面才是完整的受管块：END 只能与它前面
    /// 最近的 BEGIN 配对，否则会把两者之间的用户内容一起删掉。
    func testStripRemovesOnlyTheCompleteBlockWhenABrokenBeginPrecedesIt() {
        let orphan = "\(SSHConfigManager.beginMarker)\nHost keep\n  User me\n"
        let complete = SSHConfigManager.managedBlock(agentSock: sock)
        let tail = "Host tail\n  User you\n"
        XCTAssertEqual(SSHConfigManager.strippingManagedBlock(orphan + complete + tail),
                       orphan + tail)
    }

    func testStripWithoutBlockReturnsInputUnchanged() {
        XCTAssertEqual(SSHConfigManager.strippingManagedBlock(userConfig), userConfig)
    }

    func testRemoveRestoresOriginalBytes() {
        let inputs = [
            "lf": userConfig,
            "crlf": "Host myserver\r\n  HostName 1.2.3.4\r\n",
            "no trailing newline": "Host myserver\n  HostName 1.2.3.4",
            "leading blank line": "\nHost myserver\n",
            "trailing blank line": "Host myserver\n\n",
            "crlf without trailing newline": "Host myserver\r\n  HostName 1.2.3.4",
            "whitespace-only last line without newline": "Host myserver\n  ",
            "only a newline": "\n",
            "empty": "",
        ]
        for (name, original) in inputs {
            let inserted = SSHConfigManager.insertingManagedBlock(into: original, agentSock: sock)
            XCTAssertTrue(inserted.hasSuffix(SSHConfigManager.managedBlock(agentSock: sock)), name)
            XCTAssertEqual(SSHConfigManager.strippingManagedBlock(inserted), original, name)
        }
    }

    func testStripRecognisesBlockAfterEditorConvertedFileToCRLF() {
        for original in [userConfig, "Host myserver\n  User me"] {
            let inserted = SSHConfigManager.insertingManagedBlock(into: original, agentSock: sock)
            let crlf = inserted.replacingOccurrences(of: "\n", with: "\r\n")
            XCTAssertEqual(SSHConfigManager.strippingManagedBlock(crlf),
                           original.replacingOccurrences(of: "\n", with: "\r\n"))
        }
    }

    /// 用户在受管块后面又追加了自己的内容：删除后前后两段之间仍只隔一个空行。
    func testStripKeepsOneSeparatorWhenUserAppendedAfterBlock() {
        let tail = "Host tail\n  User you\n"
        let inserted = SSHConfigManager.insertingManagedBlock(into: userConfig, agentSock: sock)
        XCTAssertEqual(SSHConfigManager.strippingManagedBlock(inserted + "\n" + tail),
                       userConfig + "\n" + tail)
    }

    // MARK: - ssh -G 输出解析与比对

    func testParseSSHGOutput() {
        let output = "host immurok-probe.invalid\nuser me\nidentityagent /Users/John Doe/.immurok/agent.sock\nport 22\n"
        XCTAssertEqual(SSHConfigManager.identityAgent(fromSSHGOutput: output),
                       "/Users/John Doe/.immurok/agent.sock")
        XCTAssertNil(SSHConfigManager.identityAgent(fromSSHGOutput: "host x\nport 22\n"))
    }

    func testPointsToAgent() {
        let agent = home.appendingPathComponent(".immurok/agent.sock").path
        XCTAssertTrue(SSHConfigManager.pointsToAgent(agent, agentSock: agent, home: home))
        XCTAssertTrue(SSHConfigManager.pointsToAgent("~/.immurok/agent.sock", agentSock: agent, home: home))
        XCTAssertTrue(SSHConfigManager.pointsToAgent("\"\(agent)\"", agentSock: agent, home: home))
        XCTAssertFalse(SSHConfigManager.pointsToAgent("SSH_AUTH_SOCK", agentSock: agent, home: home))
        XCTAssertFalse(SSHConfigManager.pointsToAgent("none", agentSock: agent, home: home))
        XCTAssertFalse(SSHConfigManager.pointsToAgent(nil, agentSock: agent, home: home))
        XCTAssertFalse(SSHConfigManager.pointsToAgent("/some/other/agent.sock", agentSock: agent, home: home))
    }

    // MARK: - 写盘

    func testInstallCreatesDirAndFileWithPermissions() throws {
        try SSHConfigManager.install(agentSock: sock, home: home)
        XCTAssertEqual(try mode(sshDir), 0o700)
        XCTAssertEqual(try mode(configURL), 0o600)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8),
                       SSHConfigManager.managedBlock(agentSock: sock))
    }

    func testInstallKeepsExistingFileModeAndContent() throws {
        try writeConfig(userConfig, mode: 0o644)
        try SSHConfigManager.install(agentSock: sock, home: home)
        XCTAssertEqual(try mode(configURL), 0o644)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8),
                       userConfig + "\n" + SSHConfigManager.managedBlock(agentSock: sock))
    }

    func testInstallThroughSymlinkKeepsLink() throws {
        let dotfiles = home.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let real = dotfiles.appendingPathComponent("ssh_config")
        try Data(userConfig.utf8).write(to: real)
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: configURL.path, withDestinationPath: "../dotfiles/ssh_config")

        try SSHConfigManager.install(agentSock: sock, home: home)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: configURL.path),
                       "../dotfiles/ssh_config", "the link itself must survive")
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8),
                       userConfig + "\n" + SSHConfigManager.managedBlock(agentSock: sock))
    }

    func testInstallThroughDanglingSymlinkCreatesTarget() throws {
        let dotfiles = home.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let real = dotfiles.appendingPathComponent("ssh_config")
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: configURL.path, withDestinationPath: real.path)

        try SSHConfigManager.install(agentSock: sock, home: home)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: configURL.path), real.path)
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8),
                       SSHConfigManager.managedBlock(agentSock: sock))
    }

    func testInstallOnNonUTF8FileThrowsAndLeavesFileUntouched() throws {
        let bytes = Data([0x48, 0x6F, 0x73, 0x74, 0x20, 0xFF, 0xFE, 0x0A])
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        try bytes.write(to: configURL)

        XCTAssertThrowsError(try SSHConfigManager.install(agentSock: sock, home: home))
        XCTAssertEqual(try Data(contentsOf: configURL), bytes)
    }

    /// 读不了 ≠ 文件为空。把读失败当空文件处理，随后的写入就会抹掉用户的配置。
    func testInstallOnUnreadableFileThrowsAndLeavesFileUntouched() throws {
        try writeConfig(userConfig, mode: 0o000)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path) }

        XCTAssertThrowsError(try SSHConfigManager.install(agentSock: sock, home: home))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), userConfig)
    }

    func testRemoveLeavesExactlyTheUserContent() throws {
        try writeConfig(userConfig)
        try SSHConfigManager.install(agentSock: sock, home: home)
        XCTAssertTrue(SSHConfigManager.hasManagedBlock(home: home))

        try SSHConfigManager.remove(home: home)

        XCTAssertFalse(SSHConfigManager.hasManagedBlock(home: home))
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), userConfig)
    }

    func testRemoveIsNoOpWithoutBlockOrFile() throws {
        XCTAssertNoThrow(try SSHConfigManager.remove(home: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path),
                       "remove must not create the file")

        try writeConfig(userConfig, mode: 0o644)
        try SSHConfigManager.remove(home: home)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), userConfig)
        XCTAssertEqual(try mode(configURL), 0o644)
    }

    // MARK: - ssh 把签名交给谁

    private var agent: String { home.appendingPathComponent(".immurok/agent.sock").path }

    func testRoutingIsImmurokWhenSSHResolvesToAgentEvenWithoutManagedBlock() {
        // 用户自己手写了指向我们的 IdentityAgent：不该再提示
        let agent = self.agent
        XCTAssertEqual(SSHConfigManager.routing(agentSock: agent, home: home,
                                                sshGOutput: { "identityagent \(agent)\n" }),
                       .immurok)
    }

    func testRoutingIsUnsetWhenSSHHasNoIdentityAgent() throws {
        try SSHConfigManager.install(agentSock: agent, home: home)
        // ssh 的实际解析结果说了算，哪怕受管块在
        XCTAssertEqual(SSHConfigManager.routing(agentSock: agent, home: home,
                                                sshGOutput: { "host x\nport 22\n" }),
                       .unset)
    }

    /// 用户明确把 ssh 交给了别的 agent（如 1Password）、明确不用 agent、或明确写了
    /// `SSH_AUTH_SOCK`：这是他们的选择，不能当成「还没配好」去提示。受管块在末尾，
    /// 压不过这些显式配置——给按钮也写不生效，提示会一直挂着。
    func testRoutingIsOtherAgentWhenUserExplicitlyChoseOne() {
        let onePassword = "identityagent /Users/tester/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock\n"
        XCTAssertEqual(SSHConfigManager.routing(agentSock: agent, home: home, sshGOutput: { onePassword }),
                       .otherAgent)
        XCTAssertEqual(SSHConfigManager.routing(agentSock: agent, home: home,
                                                sshGOutput: { "identityagent none\n" }),
                       .otherAgent)
        XCTAssertEqual(SSHConfigManager.routing(agentSock: agent, home: home,
                                                sshGOutput: { "identityagent SSH_AUTH_SOCK\n" }),
                       .otherAgent)
    }

    func testRoutingFallsBackToManagedBlockWhenSSHCannotBeAsked() throws {
        XCTAssertEqual(SSHConfigManager.routing(agentSock: agent, home: home, sshGOutput: { nil }), .unset)
        try SSHConfigManager.install(agentSock: agent, home: home)
        XCTAssertEqual(SSHConfigManager.routing(agentSock: agent, home: home, sshGOutput: { nil }), .immurok)
    }

    /// 用真实的 /usr/bin/ssh 验证我们写出的块（含带空格的路径）确实被解析成该 agent，
    /// 以及 `ssh -G` 的输出格式与解析假设一致。
    func testRealSSHResolvesTheBlockWeWrite() throws {
        let agent = home.appendingPathComponent("John Doe/.immurok/agent.sock").path
        try writeConfig(userConfig)
        try SSHConfigManager.install(agentSock: agent, home: home)

        let output = try XCTUnwrap(SSHConfigManager.runSSHG(configFile: configURL))
        let resolved = SSHConfigManager.identityAgent(fromSSHGOutput: output)
        XCTAssertTrue(SSHConfigManager.pointsToAgent(resolved, agentSock: agent, home: home),
                      "ssh -G resolved identityagent to \(resolved ?? "nil")")
    }

    /// 用真实的 ssh 验证：用户写在具体 Host 段下的 IdentityAgent 不会被受管块压掉，
    /// 而没写的主机照常走我们的 agent。
    func testRealSSHKeepsUsersPerHostIdentityAgent() throws {
        let perHost = "Host immurok-probe.invalid\n  IdentityAgent /other/agent.sock\n"
        try writeConfig(perHost)
        try SSHConfigManager.install(agentSock: agent, home: home)

        let output = try XCTUnwrap(SSHConfigManager.runSSHG(configFile: configURL))
        XCTAssertEqual(SSHConfigManager.identityAgent(fromSSHGOutput: output), "/other/agent.sock")

        try writeConfig("Host somewhere-else\n  IdentityAgent /other/agent.sock\n")
        try SSHConfigManager.install(agentSock: agent, home: home)
        let other = try XCTUnwrap(SSHConfigManager.runSSHG(configFile: configURL))
        XCTAssertTrue(SSHConfigManager.pointsToAgent(SSHConfigManager.identityAgent(fromSSHGOutput: other),
                                                     agentSock: agent, home: home))
    }
}
